import AVFoundation

// The Watch's voice: Apple's best installed voice. Paradee (Kokoro's af_heart, distilled to
// about 9 MB) replaces it only if it passes the Watch voice bar on real hardware
// (implementation plan › Voice pipeline); that's the Phase 0 spike.

@MainActor
final class WatchSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: EmberSpeech.prepare(text))
        utterance.voice = Self.bestVoice
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private static var bestVoice: AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
    }
}
