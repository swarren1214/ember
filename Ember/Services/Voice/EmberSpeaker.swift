import AVFoundation
import Foundation
import Observation
import OSLog
import UIKit

// Ember's voice. Sentences are queued as they arrive (the brain streams them), so Ember starts
// talking on the first sentence while the rest of the answer is still being written.
//
// - Kokoro (`af_heart`) when the shared model is on this iPhone; Apple's best installed voice
//   until then and in the Simulator.
// - Everything plays through `EmberAudio`'s engine, so echo cancellation knows what Ember is
//   saying and you can talk over it.

@Observable
final class EmberSpeaker {
    static let shared = EmberSpeaker()

    private(set) var isSpeaking = false
    /// What's being said, to tell Ember's own voice apart from the person's.
    private(set) var spokenText = ""

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let converter = EmberPCMConverter(target: EmberAudio.playbackFormat)
    /// Bumped by every stop, so callbacks from an earlier answer are ignored.
    @ObservationIgnored private var generation = 0
    /// Sentences waiting to be turned into audio, in order.
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var producing = false
    /// No more sentences are coming for this answer.
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var pendingBuffers = 0
    @ObservationIgnored private var onFinished: (() -> Void)?
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.ember", category: "voice")

    static let voiceID = KokoroVoices.defaultID

    var usesNaturalVoice: Bool {
        EmberSettings.shared.naturalVoice && KokoroModel.shared.isReady
    }

    /// Starts a new answer: anything still playing stops. `onFinished` runs once every sentence
    /// queued before `finish()` has played.
    func begin(onFinished: @escaping () -> Void) {
        stop()
        self.onFinished = onFinished
        closed = false
        if usesNaturalVoice { KokoroSynth.shared.prewarm() }
    }

    /// Queues one sentence.
    func say(_ sentence: String) {
        let text = KokoroText.prepare(sentence)
        guard !text.isEmpty else { return }
        guard EmberAudio.shared.playVoice() else { return }
        queue.append(text)
        spokenText += (spokenText.isEmpty ? "" : " ") + text
        isSpeaking = true
        produceNext()
    }

    /// No more sentences for this answer.
    func finish() {
        closed = true
        finishIfDone()
    }

    func stop() {
        generation += 1
        queue = []
        producing = false
        closed = true
        pendingBuffers = 0
        onFinished = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if EmberAudio.shared.isRunning { EmberAudio.shared.player.stop() }
        isSpeaking = false
        spokenText = ""
    }

    // MARK: Producing audio

    private func produceNext() {
        guard !producing, !queue.isEmpty else { return }
        producing = true
        let sentence = queue.removeFirst()
        let current = generation
        if usesNaturalVoice {
            Task {
                do {
                    let gpu = EmberForeground.isActive
                    let samples = try await KokoroSynth.shared.synthesize(sentence, voice: Self.voiceID, gpu: gpu)
                    self.receivedKokoro(samples, generation: current)
                } catch {
                    guard current == self.generation else { return }
                    self.log.error("Kokoro failed; using the system voice: \(error.localizedDescription, privacy: .public)")
                    self.speakWithSystemVoice(sentence, generation: current)
                }
            }
        } else {
            speakWithSystemVoice(sentence, generation: current)
        }
    }

    private func receivedKokoro(_ samples: [Float], generation current: Int) {
        guard current == generation else { return }
        if !samples.isEmpty, let buffer = Self.buffer(from: samples) {
            schedule(buffer, generation: current)
        }
        sentenceProduced(generation: current)
    }

    private func speakWithSystemVoice(_ sentence: String, generation current: Int) {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = Self.bestSystemVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        Self.write(utterance, with: synthesizer) { [weak self] buffer in
            let speaker = self
            Task { @MainActor in speaker?.receivedSystem(buffer, generation: current) }
        }
    }

    private func receivedSystem(_ buffer: AVAudioPCMBuffer?, generation current: Int) {
        guard current == generation else { return }
        guard let buffer else {
            sentenceProduced(generation: current)
            return
        }
        guard let converted = converter.convert(buffer) else { return }
        schedule(converted, generation: current)
    }

    private func sentenceProduced(generation current: Int) {
        guard current == generation else { return }
        producing = false
        if queue.isEmpty { finishIfDone() } else { produceNext() }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, generation current: Int) {
        guard EmberAudio.shared.isRunning else { return }
        pendingBuffers += 1
        Self.schedule(buffer, on: EmberAudio.shared.player) { [weak self] in
            let speaker = self
            Task { @MainActor in speaker?.played(generation: current) }
        }
    }

    private func played(generation current: Int) {
        guard current == generation else { return }
        pendingBuffers = max(pendingBuffers - 1, 0)
        finishIfDone()
    }

    private func finishIfDone() {
        guard closed, !producing, queue.isEmpty, pendingBuffers == 0 else { return }
        isSpeaking = false
        spokenText = ""
        let done = onFinished
        onFinished = nil
        done?()
    }

    // MARK: Audio helpers (outside the main actor: they call back on other threads)

    private nonisolated static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let format = EmberAudio.playbackFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    private nonisolated static func write(_ utterance: AVSpeechUtterance, with synthesizer: AVSpeechSynthesizer, deliver: @escaping @Sendable (AVAudioPCMBuffer?) -> Void) {
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            deliver(pcm.frameLength == 0 ? nil : pcm)
        }
    }

    private nonisolated static func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode, done: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
    }

    /// The best-sounding installed voice for the person's language: Premium, then Enhanced.
    static var bestSystemVoice: AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let preferred = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        let ranked = voices.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            return (lhs.language == preferred ? 1 : 0) > (rhs.language == preferred ? 1 : 0)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: preferred)
    }
}

/// Whether the app is in the foreground (Kokoro may use the GPU only then).
enum EmberForeground {
    static var isActive: Bool { UIApplication.shared.applicationState == .active }
}
