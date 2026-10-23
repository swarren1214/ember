import AVFoundation
import Foundation
import Observation
import OSLog
import UIKit

// Ember's voice. Sentences are queued as they arrive (the brain streams them), so Ember starts
// talking on the first sentence while the rest of the answer is still being written.
//
// - Text is made ready to be heard first (EmberSpeech: money, times, dates, numbers; and the
//   pronunciations in Settings).
// - The first sentence is spoken alone, so speech starts fast; after that, the sentences waiting
//   are spoken together, so the intonation carries across them instead of restarting.
// - Kokoro (the voice and speed chosen in Settings) when the shared model is on this iPhone;
//   Apple's best installed voice until then and in the Simulator.
// - Each piece is trimmed of its own silence, faded in and out, and brought to one loudness;
//   pieces are joined by even pauses, so there are no clicks or uneven gaps.
// - In a spoken conversation everything plays through `EmberAudio`'s engine, so echo cancellation
//   knows what Ember is saying and you can talk over it. Answers to typed questions play through
//   the speaker's own engine, with a playback session (the microphone stays off).

@Observable
final class EmberSpeaker {
    static let shared = EmberSpeaker()

    private(set) var isSpeaking = false
    /// What's being said, to tell Ember's own voice apart from the person's: as written (what the
    /// recognizer tends to write back, "$86") and as spoken ("eighty-six dollars").
    private(set) var spokenText = ""
    @ObservationIgnored private(set) var writtenText = ""
    /// When the last piece finished playing, for the echo that trails it.
    @ObservationIgnored private(set) var lastPlayedAt = Date.distantPast

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
    /// Pieces produced for this answer (the first is spoken alone).
    @ObservationIgnored private var produced = 0
    @ObservationIgnored private var onFinished: (() -> Void)?
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.ember", category: "voice")
    /// For typed questions: Ember's voice without the microphone.
    @ObservationIgnored private let ownEngine = AVAudioEngine()
    @ObservationIgnored private let ownPlayer = AVAudioPlayerNode()
    @ObservationIgnored private var usingOwnEngine = false

    init() {
        ownEngine.attach(ownPlayer)
        ownEngine.connect(ownPlayer, to: ownEngine.mainMixerNode, format: EmberAudio.playbackFormat)
    }

    /// The conversation's player while it runs, else the speaker's own.
    private var output: AVAudioPlayerNode { EmberAudio.shared.isRunning ? EmberAudio.shared.player : ownPlayer }

    /// Ready to play: the conversation's engine, or the speaker's own (started on demand).
    private func outputReady() -> Bool {
        if EmberAudio.shared.isRunning { return EmberAudio.shared.playVoice() }
        if !ownEngine.isRunning {
            ownEngine.prepare()
            do { try ownEngine.start() } catch {
                log.error("Couldn't start the voice: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        usingOwnEngine = true
        ownPlayer.play()
        return true
    }

    static var voiceID: String { EmberSettings.shared.voiceID }

    /// The pause between pieces, and the longest a group of sentences gets.
    private static let pause: TimeInterval = 0.18
    private static let groupLimit = 240

    var usesNaturalVoice: Bool {
        EmberSettings.shared.naturalVoice && KokoroModel.shared.isReady
    }

    /// Starts a new answer: anything still playing stops. `onFinished` runs once every sentence
    /// queued before `finish()` has played.
    func begin(onFinished: @escaping () -> Void) {
        stop()
        self.onFinished = onFinished
        closed = false
        produced = 0
        if usesNaturalVoice { KokoroSynth.shared.prewarm() }
        if !EmberAudio.shared.isRunning {
            Task { try? await EmberAudioSession.activateForPlayback() }
        }
    }

    /// Queues one sentence.
    func say(_ sentence: String) {
        let text = EmberSpeech.prepare(Self.pronounce(sentence))
        guard !text.isEmpty else { return }
        guard outputReady() else { return }
        queue.append(text)
        spokenText += (spokenText.isEmpty ? "" : " ") + text
        writtenText += (writtenText.isEmpty ? "" : " ") + sentence
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
        EmberAudio.shared.player.volume = 1
        releaseOwnEngine()
        isSpeaking = false
        spokenText = ""
        writtenText = ""
    }

    /// Ember's voice quieter while someone may be talking over it (or back to normal).
    func duck(_ on: Bool) {
        output.volume = on ? 0.3 : 1
    }

    /// Typed answer done (or stopped): the speaker's engine off, other apps' audio back up.
    private func releaseOwnEngine() {
        guard usingOwnEngine else { return }
        usingOwnEngine = false
        ownPlayer.stop()
        if ownEngine.isRunning { ownEngine.stop() }
        if !EmberAudio.shared.isRunning { EmberAudioSession.deactivate() }
    }

    // MARK: Producing audio

    private func produceNext() {
        guard !producing, !queue.isEmpty else { return }
        producing = true
        var sentence = queue.removeFirst()
        // After the first piece, speak what's waiting together.
        if produced > 0 {
            while let next = queue.first, sentence.count + next.count < Self.groupLimit {
                sentence += " " + queue.removeFirst()
            }
        }
        produced += 1
        let current = generation
        if usesNaturalVoice {
            let tuning = VoiceTuning(pace: EmberSettings.shared.voiceSpeed, expressiveness: 1)
            let voice = Self.voiceID
            Task {
                do {
                    let gpu = EmberForeground.isActive
                    let raw = try await KokoroSynth.shared.synthesize(sentence, voice: voice, tuning: tuning, gpu: gpu)
                    let samples = await Task.detached(priority: .userInitiated) { EmberVoicePolish.polish(raw, sampleRate: EmberAudio.playbackFormat.sampleRate) }.value
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
            if let gap = Self.buffer(from: [Float](repeating: 0, count: Int(Self.pause * EmberAudio.playbackFormat.sampleRate))) {
                schedule(gap, generation: current)
            }
        }
        sentenceProduced(generation: current)
    }

    private func speakWithSystemVoice(_ sentence: String, generation current: Int) {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = Self.bestSystemVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(max(EmberSettings.shared.voiceSpeed, 0.9), 1.2))
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
        guard EmberAudio.shared.isRunning || usingOwnEngine else { return }
        pendingBuffers += 1
        Self.schedule(buffer, on: output) { [weak self] in
            let speaker = self
            Task { @MainActor in speaker?.played(generation: current) }
        }
    }

    private func played(generation current: Int) {
        guard current == generation else { return }
        pendingBuffers = max(pendingBuffers - 1, 0)
        lastPlayedAt = .now
        finishIfDone()
    }

    private func finishIfDone() {
        guard closed, !producing, queue.isEmpty, pendingBuffers == 0 else { return }
        isSpeaking = false
        spokenText = ""
        writtenText = ""
        duck(false)
        releaseOwnEngine()
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

    /// The pronunciations from Settings, applied to whole words.
    static func pronounce(_ text: String) -> String {
        var result = text
        for (word, spoken) in EmberSettings.shared.pronunciations where !word.isEmpty && !spoken.isEmpty {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
            result = result.replacingOccurrences(of: pattern, with: spoken, options: [.regularExpression, .caseInsensitive])
        }
        return result
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

/// Makes each piece of Kokoro audio sit well next to the others: its own leading and trailing
/// silence trimmed (the pauses between pieces are added evenly instead), 5 ms fades so nothing
/// clicks, and one loudness for every piece with a soft limit on peaks.
nonisolated enum EmberVoicePolish {
    static func polish(_ input: [Float], sampleRate: Double) -> [Float] {
        guard input.count > 100 else { return input }
        let threshold: Float = 0.004
        let margin = Int(0.02 * sampleRate)
        guard let first = input.firstIndex(where: { abs($0) > threshold }),
              let last = input.lastIndex(where: { abs($0) > threshold }) else { return [] }
        var samples = Array(input[max(0, first - margin)...min(input.count - 1, last + margin)])

        // Loudness: the RMS of the voiced part to about -18 dBFS, within sensible bounds.
        var sum: Float = 0
        var voiced = 0
        for sample in samples where abs(sample) > threshold {
            sum += sample * sample
            voiced += 1
        }
        if voiced > 0 {
            let rms = (sum / Float(voiced)).squareRoot()
            let gain = min(max(0.125 / max(rms, 0.0001), 0.5), 3)
            for index in samples.indices {
                let value = samples[index] * gain
                // Soft limit above 0.85.
                samples[index] = abs(value) < 0.85 ? value : (value > 0 ? 1 : -1) * (0.85 + 0.15 * tanh((abs(value) - 0.85) / 0.15))
            }
        }

        let fade = min(Int(0.005 * sampleRate), samples.count / 2)
        for index in 0..<fade {
            let gain = Float(index) / Float(fade)
            samples[index] *= gain
            samples[samples.count - 1 - index] *= gain
        }
        return samples
    }
}
