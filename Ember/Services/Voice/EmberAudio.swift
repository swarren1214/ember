import AVFoundation
import Foundation
import os
import OSLog

// The microphone and Ember's voice on one audio engine, with Apple's voice processing on, the
// same as Ask Suffice and Sated's Coach (Suffice/Services/Voice/Conversation.swift). Because the
// voice plays through the engine that records, voice processing removes it from what the
// microphone hears: you can talk over Ember and be heard, and its own voice never reaches the
// recognizer. It also suppresses background noise and honors the system Voice Isolation mode
// (Control Center › Mic Mode).
//
// Typed questions don't open the microphone: their answers play through the speaker's own engine
// (EmberSpeaker) with a playback session.

// MARK: - Audio session

/// Every change to the shared audio session goes through one serial queue, off the main thread
/// (activating blocks), so a late "deactivate" can never land after the next "activate".
nonisolated enum EmberAudioSession {
    private static let queue = DispatchQueue(label: "com.stephenwarren.ember.audiosession")

    /// For answers to typed questions: playback only.
    static func activateForPlayback() async throws {
        try await run {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try session.setActive(true)
        }
    }

    /// For talking with Ember: the microphone and the voice at once, through voice processing.
    /// Speaker by default, so the conversation isn't stuck in the earpiece; headsets work too.
    static func activateForConversation() async throws {
        try await run {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    /// Hands audio back to other apps (and brings their music back up).
    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private static func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

nonisolated enum EmberVoiceError: Error {
    case noMicrophone
    case unsupportedLanguage
}

// MARK: - The conversation engine

final class EmberAudio {
    static let shared = EmberAudio()

    /// The format Ember's voice plays in: Kokoro's 24 kHz mono. The system voice is converted to it.
    nonisolated static let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    let player = AVAudioPlayerNode()
    private(set) var isRunning = false
    /// Whether echo cancellation is on (it isn't in the Simulator).
    private(set) var hasVoiceProcessing = false

    private let engine = AVAudioEngine()
    private var attached = false
    private var isStarting = false
    /// Microphone audio goes here, on the audio thread.
    private let sink = OSAllocatedUnfairLock<(@Sendable (AVAudioPCMBuffer) -> Void)?>(initialState: nil)
    /// When the microphone last delivered real sound (not digital silence), from the audio thread.
    private let lastSignal = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private let log = Logger(subsystem: "com.stephenwarren.ember", category: "audio")

    private init() {
        // Switching the session to two-way voice (and turning on echo cancellation) reconfigures
        // the hardware a moment after the engine starts, which stops the engine. The first
        // conversation after launch always hits this; restart instead of going deaf.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(reason: "the audio configuration changed", full: false, attempt: 1) }
        }
    }

    /// Opens the microphone and Ember's voice. `input` receives microphone audio on a
    /// background thread.
    func start(input: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        sink.withLock { $0 = input }
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        try await EmberAudioSession.activateForConversation()
        do {
            try startEngine()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            EmberAudioSession.deactivate()
            throw error
        }
        isRunning = true
        watchMicrophone()
    }

    /// Plays the voice player (only while the engine runs; playing a node otherwise crashes).
    func playVoice() -> Bool {
        guard isRunning, engine.isRunning else { return false }
        player.play()
        return true
    }

    private func startEngine() throws {
        let microphone = engine.inputNode
        #if !targetEnvironment(simulator)
        do {
            try microphone.setVoiceProcessingEnabled(true)
            // Ember shouldn't hush other audio more than it has to.
            microphone.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
            hasVoiceProcessing = true
        } catch {
            log.error("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat)
            attached = true
        }
        try tapMicrophone()
        engine.prepare()
        try engine.start()
    }

    /// (Re)installs the tap in the microphone's current format, which can change when the
    /// hardware is reconfigured.
    private func tapMicrophone() throws {
        let microphone = engine.inputNode
        microphone.removeTap(onBus: 0)
        let format = microphone.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EmberVoiceError.noMicrophone }
        Self.installTap(on: microphone, format: format, sink: sink, lastSignal: lastSignal)
    }

    /// Restarts after the engine stopped on its own, or went silent. `full` also resets echo
    /// cancellation, which on some first starts delivers nothing but zeros.
    private func restart(reason: String, full: Bool, attempt: Int) {
        guard isRunning, !isStarting else { return }
        log.notice("Restarting the microphone: \(reason, privacy: .public)")
        if full || !engine.isRunning { engine.stop() }
        if full, hasVoiceProcessing {
            engine.inputNode.removeTap(onBus: 0)
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            hasVoiceProcessing = false
        }
        do {
            if full {
                try startEngine()
            } else {
                try tapMicrophone()
                if !engine.isRunning {
                    engine.prepare()
                    try engine.start()
                }
            }
        } catch {
            log.error("Couldn't restart the microphone: \(error.localizedDescription, privacy: .public)")
        }
        watchMicrophone(attempt: attempt)
    }

    /// If no real sound comes in soon after starting, starts over: first just the engine, then
    /// with a full reset. After that it stops trying (the microphone may be in use elsewhere).
    private func watchMicrophone(attempt: Int = 1) {
        watchdog?.cancel()
        guard attempt <= 2 else { return }
        let started = Date.now
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            if self.lastSignal.withLock({ $0 }) > started { return }
            self.log.notice("No microphone audio after starting (attempt \(attempt))")
            self.restart(reason: "no sound from the microphone", full: attempt == 2, attempt: attempt + 1)
        }
    }

    func stop() {
        sink.withLock { $0 = nil }
        watchdog?.cancel()
        watchdog = nil
        guard isRunning else { return }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if !targetEnvironment(simulator)
        if hasVoiceProcessing {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            hasVoiceProcessing = false
        }
        #endif
        isRunning = false
        EmberAudioSession.deactivate()
    }

    /// The tap runs on the audio thread, so it's built outside the main actor.
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               sink: OSAllocatedUnfairLock<(@Sendable (AVAudioPCMBuffer) -> Void)?>,
                                               lastSignal: OSAllocatedUnfairLock<Date>) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if hasSound(buffer) { lastSignal.withLock { $0 = .now } }
            sink.withLock { $0 }?(buffer)
        }
    }

    /// Real microphones always pick up a little noise; exact zeros mean no audio is flowing.
    private nonisolated static func hasSound(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let samples = buffer.floatChannelData?[0] else { return true }
        let count = Int(buffer.frameLength)
        var index = 0
        while index < count {
            if samples[index] != 0 { return true }
            index += 8
        }
        return false
    }

    /// Shows the system Mic Mode menu (Standard, Voice Isolation, Wide Spectrum).
    static func showMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    /// The microphone mode the person picked in Control Center.
    static var microphoneModeName: String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: "Voice Isolation"
        case .wideSpectrum: "Wide Spectrum"
        default: "Standard"
        }
    }
}

/// The microphone's loudness, 0...1, written on the audio thread about 30 times a second. The
/// animations read it each frame; nothing hops to the main thread for it.
nonisolated enum EmberMicLevel {
    private static let last = OSAllocatedUnfairLock(initialState: Date.distantPast)

    static func report(_ buffer: AVAudioPCMBuffer) {
        let now = Date.now
        let due = last.withLock { last -> Bool in
            guard now.timeIntervalSince(last) > 0.033 else { return false }
            last = now
            return true
        }
        guard due, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        EmberLevelMeter.shared.value = min(Double((sum / Float(count)).squareRoot()) * 12, 1)
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
