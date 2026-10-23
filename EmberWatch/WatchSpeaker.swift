import AVFoundation
import OSLog

// The Watch's voice. The Watch can't run Kokoro, so answers are spoken by the cloud voice
// (hearth-api › /v1/ember/speak, Google's Chirp 3: HD), one sentence at a time: each sentence
// is fetched as soon as it's written, while the one before is playing, so the voice starts on
// the first sentence and never waits between them.
//
// Apple's built-in voice is the backup: with no connection, no Watch sign-in, Cloud Help off,
// or a sentence the cloud voice refuses or fails on. Once an answer falls back, the rest of it
// stays on the built-in voice, so it never switches voices mid-answer.

@MainActor
final class WatchSpeaker: NSObject {
    /// The cloud voice's name ("Aoede"); nil uses the built-in voice only.
    var cloudVoice: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    /// Sentences waiting to play, each with its audio on the way (nil audio: built-in voice).
    private var pending: [(text: String, audio: Task<Data?, Never>?)] = []
    private var isPlaying = false
    private var usesSystemVoice = false
    private var generation = 0
    private let client = EmberCloudClient(baseURL: EmberEndpoints.apiBaseURL)
    private let log = Logger(subsystem: "com.stephenwarren.ember.watch", category: "voice")

    /// A new answer: whatever was playing stops.
    func begin() {
        stop()
        generation += 1
        usesSystemVoice = cloudVoice == nil
        activateSession()
    }

    /// One more sentence of the answer.
    func say(_ sentence: String) {
        let text = EmberSpeech.prepare(sentence)
        guard !text.isEmpty else { return }
        if usesSystemVoice {
            speakWithSystemVoice(text)
            return
        }
        let voice = cloudVoice ?? "Aoede"
        let client = client
        let audio = Task<Data?, Never> {
            guard let token = try? await WatchAccount.shared.accessToken() else { return nil }
            return try? await client.speak(text, voice: voice, accessToken: token)
        }
        pending.append((text, audio))
        if !isPlaying { playNext() }
    }

    /// A whole answer at once (from the iPhone).
    func speak(_ text: String) {
        begin()
        var splitter = EmberSentenceSplitter()
        for sentence in splitter.feed(text) { say(sentence) }
        if let rest = splitter.flush() { say(rest) }
    }

    func stop() {
        generation += 1
        for item in pending { item.audio?.cancel() }
        pending = []
        isPlaying = false
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    // MARK: Playing

    private func playNext() {
        guard !pending.isEmpty else {
            isPlaying = false
            return
        }
        isPlaying = true
        let next = pending.removeFirst()
        let current = generation
        Task {
            let data = await next.audio?.value
            guard current == generation else { return }
            if let data, let player = try? AVAudioPlayer(data: data) {
                self.player = player
                player.delegate = self
                player.play()
            } else {
                // The cloud voice didn't come through: the built-in voice from here on.
                log.notice("Cloud voice unavailable; using the built-in voice")
                usesSystemVoice = true
                speakWithSystemVoice(next.text)
                for item in pending {
                    item.audio?.cancel()
                    speakWithSystemVoice(item.text)
                }
                pending = []
                isPlaying = false
            }
        }
    }

    fileprivate func finishedPlaying() {
        player = nil
        playNext()
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice
        synthesizer.speak(utterance)
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
    }

    private static var bestVoice: AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
    }
}

extension WatchSpeaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishedPlaying() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finishedPlaying() }
    }
}
