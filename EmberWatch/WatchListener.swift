import AVFoundation
import Foundation
import OSLog

// Listening on Apple Watch, the way listen mode works on the iPhone: tap the orb, talk, and Ember
// takes it from there when you pause. No dictation sheet, no Done button.
//
// watchOS gives apps no speech recognition (no Speech framework, no SpeechAnalyzer), so the Watch
// records the question itself: 16 kHz mono, its loudness fed to the orb as you talk. When you've
// spoken and then gone quiet for a moment, it stops and hands back the audio, which hearth-api
// turns into text (/v1/ember/transcribe). Tapping the orb stops it straight away.

@MainActor
final class WatchListener {
    enum Outcome {
        /// 16-bit mono PCM at `sampleRate`.
        case heard(Data)
        /// Nothing was said before giving up.
        case silence
        case cancelled
        case failed(String)
    }

    static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let capture = PCMCapture()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var watcher: Task<Void, Never>?
    private let log = Logger(subsystem: "com.stephenwarren.ember.watch", category: "listen")

    /// Speech is louder than this (0…1, the same scale as the iPhone's meter).
    private let speechLevel = 0.08
    /// Quiet this long after speech ends the question.
    private let pause: TimeInterval = 1.2
    /// Nothing said in this long: give up.
    private let patience: TimeInterval = 6
    /// The longest question.
    private let longest: TimeInterval = 20

    /// Records until the person pauses, stops, or cancels.
    func listen() async -> Outcome {
        guard await AVAudioApplication.requestRecordPermission() else {
            return .failed("Ember needs the microphone. Allow it in the Watch’s Settings › Privacy › Microphone.")
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            log.error("Couldn't start the microphone: \(error.localizedDescription, privacy: .public)")
            return .failed("The microphone isn’t available right now.")
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, capture.reset(from: format, sampleRate: Self.sampleRate) else {
            return .failed("The microphone isn’t available right now.")
        }
        Self.installTap(on: input, format: format, capture: capture)
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return .failed("The microphone isn’t available right now.")
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            watcher = Task { [weak self] in await self?.watch() }
        }
    }

    /// The tap runs on the audio thread, so it's made outside the main actor.
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, capture: PCMCapture) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            capture.append(buffer)
        }
    }

    /// Done talking: use what was said so far.
    func finish() { end(capture.heardSpeech ? .heard(capture.pcm) : .silence) }

    func cancel() { end(.cancelled) }

    /// Ten times a second: the orb follows the voice, and the end of speech ends the question.
    private func watch() async {
        let started = Date.now
        var lastLoud: Date?
        while !Task.isCancelled, continuation != nil {
            try? await Task.sleep(for: .milliseconds(100))
            let level = capture.level
            EmberLevelMeter.shared.value = level
            let now = Date.now
            if level > speechLevel {
                lastLoud = now
                capture.heardSpeech = true
            }
            if let lastLoud, now.timeIntervalSince(lastLoud) > pause {
                end(.heard(capture.pcm))
                return
            }
            if lastLoud == nil, now.timeIntervalSince(started) > patience {
                end(.silence)
                return
            }
            if now.timeIntervalSince(started) > longest {
                end(capture.heardSpeech ? .heard(capture.pcm) : .silence)
                return
            }
        }
    }

    private func end(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        watcher?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        EmberLevelMeter.shared.value = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        continuation.resume(returning: outcome)
    }
}

/// The recording so far, written on the audio thread and read on the main one.
private nonisolated final class PCMCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var data = Data()
    private var latest = 0.0
    private var spoke = false

    var pcm: Data { lock.withLock { data } }
    var level: Double { lock.withLock { latest } }
    var heardSpeech: Bool {
        get { lock.withLock { spoke } }
        set { lock.withLock { spoke = newValue } }
    }

    /// Starts a new recording from the microphone's format; false if it can't be converted.
    func reset(from format: AVAudioFormat, sampleRate: Double) -> Bool {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else { return false }
        lock.withLock {
            self.converter = converter
            self.target = target
            data = Data()
            latest = 0
            spoke = false
        }
        return true
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let pair = lock.withLock({ () -> (AVAudioConverter, AVAudioFormat)? in
            guard let converter = self.converter, let target = self.target else { return nil }
            return (converter, target)
        }) else { return }
        let (converter, target) = pair
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = output.int16ChannelData?[0], output.frameLength > 0 else { return }
        let count = Int(output.frameLength)
        var sum = 0.0
        for index in 0..<count {
            let sample = Double(samples[index]) / 32768
            sum += sample * sample
        }
        let level = min((sum / Double(count)).squareRoot() * 12, 1)
        let bytes = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        lock.withLock {
            data.append(bytes)
            latest = level
        }
    }
}
