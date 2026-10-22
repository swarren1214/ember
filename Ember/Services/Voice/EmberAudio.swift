import AVFoundation
import CoreMedia
import Foundation
import Observation
import os
import OSLog
import Speech

// The microphone and Ember's voice share one audio engine, with echo cancellation so Ember's own
// voice is removed from what the microphone hears and you can talk over it (barge-in). Adapted
// from BigTable's AskSpeech.swift.
//
// Two ways to cancel the echo, picked per iPhone:
// - Echo-cancelled input (iPhones that support it): the session stays in its default mode, so
//   Ember's voice plays through the media path at full quality, and the system cleans the
//   microphone. Preferred.
// - Voice processing (all others): the call path. Barge-in works the same, but the voice sounds
//   like a phone call: narrower and quieter.

// MARK: - Audio session

/// Every change to the shared audio session goes through one serial queue, off the main thread
/// (activating blocks), so a late "deactivate" can never land after the next "activate".
nonisolated enum EmberAudioSession {
    private static let queue = DispatchQueue(label: "com.stephenwarren.ember.audio")

    /// The microphone and the spoken replies at once, through voice processing. Speaker by
    /// default, so the conversation isn't stuck in the earpiece; headsets work too.
    /// Returns whether the system cleans the microphone itself (echo-cancelled input); when it
    /// doesn't, the engine turns on voice processing.
    static func activateForConversation() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    if session.isEchoCancelledInputAvailable {
                        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
                        try session.setPrefersEchoCancelledInput(true)
                        try session.setActive(true, options: .notifyOthersOnDeactivation)
                        continuation.resume(returning: session.isEchoCancelledInputEnabled)
                    } else {
                        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
                        try session.setActive(true, options: .notifyOthersOnDeactivation)
                        continuation.resume(returning: false)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Hands audio back to other apps (and brings their music back up).
    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

nonisolated enum EmberVoiceError: Error {
    case noMicrophone
    case unsupportedLanguage
}

// MARK: - Audio thread helpers

/// Where microphone audio goes. Called on the audio thread.
nonisolated final class EmberMicrophoneTap: @unchecked Sendable {
    private let sink = OSAllocatedUnfairLock<(@Sendable (AVAudioPCMBuffer) -> Void)?>(initialState: nil)

    func setSink(_ new: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        sink.withLock { $0 = new }
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        sink.withLock { $0 }?(buffer)
    }

    /// (Re)installs the tap in the microphone's current format. False when there's no
    /// microphone input (installing a tap then would crash).
    static func install(on input: AVAudioInputNode, tap: EmberMicrophoneTap) -> Bool {
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            tap.deliver(buffer)
        }
        return true
    }
}

/// Converts audio buffers to one format (sample rate, channels, sample type). Used from one
/// thread at a time.
nonisolated final class EmberPCMConverter: @unchecked Sendable {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter, buffer.frameLength > 0 else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        // The input block is @Sendable, so "fed" lives in a lock rather than a captured var.
        let fed = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let alreadyFed = fed.withLock { value -> Bool in
                let was = value
                value = true
                return was
            }
            if alreadyFed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Feeds microphone audio to the speech analyzer (converted to its format) and reports how
/// loud it is, on the audio thread.
nonisolated final class EmberMicrophoneFeed: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: EmberPCMConverter
    private let onLevel: @Sendable (Double) -> Void
    private let muted = OSAllocatedUnfairLock(initialState: false)
    private let lastLevel = OSAllocatedUnfairLock(initialState: Date.distantPast)

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, converter: EmberPCMConverter, onLevel: @escaping @Sendable (Double) -> Void) {
        self.continuation = continuation
        self.converter = converter
        self.onLevel = onLevel
    }

    func setMuted(_ value: Bool) {
        muted.withLock { $0 = value }
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        guard !muted.withLock({ $0 }) else { return }
        reportLevel(buffer)
        if let converted = converter.convert(buffer) {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() {
        continuation.finish()
    }

    /// About 20 times a second: the buffer's loudness, 0...1.
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        let now = Date.now
        let due = lastLevel.withLock { last -> Bool in
            guard now.timeIntervalSince(last) > 0.05 else { return false }
            last = now
            return true
        }
        guard due, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        onLevel(min(Double(sqrt(sum / Float(count))) * 12, 1))
    }
}

// MARK: - Audio engine

/// The microphone and Ember's voice on one engine with voice processing (echo cancellation
/// and noise suppression), for the hands-free voice screen.
final class EmberAudio {
    static let shared = EmberAudio()

    /// The format Ember's voice plays in: Kokoro's 24 kHz mono. The system voice is converted to it.
    nonisolated static let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    let player = AVAudioPlayerNode()
    private(set) var isRunning = false
    /// The system cancels the echo (full-quality playback); otherwise voice processing does.
    private(set) var systemEchoCancellation = false

    private let engine = AVAudioEngine()
    private let tap = EmberMicrophoneTap()
    private var attached = false
    private var configurationObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.stephenwarren.ember", category: "audio")

    private init() {
        // Switching to two-way voice reconfigures the hardware a moment after the engine
        // starts, which stops the engine. Start it again instead of going deaf.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    /// Opens the microphone (its audio goes to `sink`, on the audio thread) and the speaker.
    func start(sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        tap.setSink(sink)
        guard !isRunning else { return }
        systemEchoCancellation = try await EmberAudioSession.activateForConversation()
        log.notice("Echo cancellation: \(self.systemEchoCancellation ? "system (media path)" : "voice processing", privacy: .public)")
        do {
            try startEngine()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            EmberAudioSession.deactivate()
            throw error
        }
        isRunning = true
    }

    private func startEngine() throws {
        let input = engine.inputNode
        #if !targetEnvironment(simulator)
        if !systemEchoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                log.error("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat)
            attached = true
        }
        guard EmberMicrophoneTap.install(on: input, tap: tap) else { throw EmberVoiceError.noMicrophone }
        engine.prepare()
        try engine.start()
    }

    /// After the hardware changed: the tap again (the format may have changed) and the engine.
    private func restart() {
        guard isRunning else { return }
        log.notice("Restarting the microphone after an audio configuration change")
        guard EmberMicrophoneTap.install(on: engine.inputNode, tap: tap) else { return }
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.error("Couldn't restart the microphone: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Plays the voice player (only while the engine runs; playing a node otherwise crashes).
    func playVoice() -> Bool {
        guard isRunning, engine.isRunning else { return false }
        player.play()
        return true
    }

    func stop() {
        tap.setSink(nil)
        guard isRunning else { return }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if !targetEnvironment(simulator)
        if !systemEchoCancellation { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        #endif
        isRunning = false
        EmberAudioSession.deactivate()
    }
}

