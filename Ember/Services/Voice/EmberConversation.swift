import AVFoundation
import CoreMedia
import Foundation
import Observation
import OSLog
import Speech
import UIKit

// One spoken exchange at a time, driven by the orb (the "Ember · Hearth AI" canvas):
//
//   idle ──tap──▶ listening ──pause or tap──▶ thinking ──▶ answering ──done──▶ idle
//                     ▲                                        │
//                     └────────── tap, or start talking ───────┘   (barge-in)
//
// Speech is recognized on the iPhone with SpeechAnalyzer (nothing leaves the device). The
// microphone and Ember's voice share one engine with echo cancellation, so talking over Ember
// interrupts it. Adapted from BigTable's AskConversation.

@Observable
final class EmberConversation {
    static let shared = EmberConversation()

    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case answering
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What you're saying now (live).
    private(set) var transcript = ""
    /// Microphone loudness, 0...1, for the orb.
    private(set) var level: Double = 0
    /// The question being answered.
    private(set) var question = ""
    /// The answer being written, as it streams.
    private(set) var liveAnswer = ""

    /// How long a silence ends your turn.
    static let pause: TimeInterval = 0.9

    @ObservationIgnored private let brain = EmberBrain.shared
    @ObservationIgnored private let audio = EmberAudio.shared
    @ObservationIgnored private let speaker = EmberSpeaker.shared
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: EmberMicrophoneFeed?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var answering: Task<Void, Never>?
    @ObservationIgnored private var exchange = 0
    /// A handoff to open once the answer has been spoken (a call).
    @ObservationIgnored private var openWhenSpoken: URL?
    @ObservationIgnored private var settled = ""
    @ObservationIgnored private var volatile = ""
    @ObservationIgnored private var consumedUntil = CMTime.zero
    @ObservationIgnored private var latestEnd = CMTime.zero
    @ObservationIgnored private var lastHeard = Date.now
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.ember", category: "conversation")

    // MARK: The orb

    /// Tap: listen when idle, send when listening, stop Ember and listen when it's thinking or
    /// talking.
    func tapOrb() {
        switch phase {
        case .idle, .failed:
            Task { await listen() }
        case .listening:
            if transcript.isEmpty { cancel() } else { endTurn() }
        case .thinking, .answering:
            interrupt()
        }
    }

    /// Ask without speaking (a suggestion chip, typing, Siri). Ember still answers out loud.
    func ask(_ text: String) {
        Task {
            if !audio.isRunning { try? await startAudio() }
            send(text)
        }
    }

    /// The X while listening: back to idle, nothing sent.
    func cancel() {
        exchange += 1
        answering?.cancel()
        clearTurn()
        stopAudio()
        phase = .idle
    }

    // MARK: Listening

    private func listen() async {
        guard await Self.permissionsGranted() else {
            phase = .failed("Ember needs the microphone and speech recognition to listen. Turn them on in Settings › Ember.")
            return
        }
        do {
            if !audio.isRunning { try await startAudio() }
        } catch {
            log.error("Couldn't start listening: \(String(describing: error), privacy: .public)")
            stopAudio()
            phase = .failed("Ember couldn’t start listening. Check that the microphone isn’t in use, then try again.")
            return
        }
        speaker.stop()
        clearTurn()
        lastHeard = .now
        feed?.setMuted(false)
        phase = .listening
        watch()
    }

    private func startAudio() async throws {
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if supported == nil { supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale = supported else { throw EmberVoiceError.unsupportedLanguage }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EmberVoiceError.unsupportedLanguage
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let feed = EmberMicrophoneFeed(continuation: continuation, converter: EmberPCMConverter(target: format)) { [weak self] value in
            let conversation = self
            Task { @MainActor in conversation?.levelChanged(value) }
        }
        self.analyzer = analyzer
        self.feed = feed
        consumedUntil = .zero
        latestEnd = .zero

        try await analyzer.start(inputSequence: stream)
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.heard(String(result.text.characters), isFinal: result.isFinal, range: result.range)
                }
            } catch {
                self?.log.notice("Speech results ended: \(String(describing: error), privacy: .public)")
            }
        }
        try await audio.start { buffer in feed.handle(buffer) }
    }

    private func stopAudio() {
        watcher?.cancel()
        watcher = nil
        speaker.stop()
        audio.stop()
        feed?.finish()
        feed = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        level = 0
    }

    private func levelChanged(_ value: Double) {
        level = phase == .listening ? value : 0
    }

    private func clearTurn() {
        transcript = ""
        settled = ""
        volatile = ""
        consumedUntil = latestEnd
    }

    private func heard(_ text: String, isFinal: Bool, range: CMTimeRange) {
        guard CMTimeCompare(range.start, consumedUntil) >= 0 else { return }
        let end = CMTimeRangeGetEnd(range)
        if CMTimeCompare(end, latestEnd) > 0 { latestEnd = end }

        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            settled = Self.join(settled, words)
            volatile = ""
        } else {
            volatile = words
        }
        let combined = Self.join(settled, volatile)
        guard !combined.isEmpty else { return }

        switch phase {
        case .listening:
            transcript = combined
            lastHeard = .now
        case .thinking, .answering:
            if isEcho(combined) {
                settled = ""
                volatile = ""
            } else if Self.words(combined).count >= 2 {
                // Talking over Ember: it stops and listens.
                interrupt()
                transcript = combined
                lastHeard = .now
            }
        case .idle, .failed:
            settled = ""
            volatile = ""
        }
    }

    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard phase == .listening else { return }
        let quiet = Date.now.timeIntervalSince(lastHeard)
        if transcript.isEmpty {
            // Nothing said for 20 seconds: stop listening.
            if quiet >= 20 { cancel() }
            return
        }
        if level > 0.35 {
            lastHeard = .now
            return
        }
        if quiet >= Self.pause { endTurn() }
    }

    // MARK: Turns

    private func endTurn() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        clearTurn()
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        send(text)
    }

    private func send(_ text: String) {
        exchange += 1
        let current = exchange
        feed?.setMuted(false)
        phase = .thinking
        question = text
        liveAnswer = ""
        openWhenSpoken = nil
        speaker.begin { [weak self] in
            guard let self, current == self.exchange else { return }
            // Done talking: the microphone turns off until the next tap.
            self.phase = .idle
            self.stopAudio()
            // The microphone is off now, so the call screen gets the audio. iOS asks before dialing.
            if let url = self.openWhenSpoken {
                self.openWhenSpoken = nil
                UIApplication.shared.open(url)
            }
        }
        answering = Task { [weak self] in
            guard let self else { return }
            let turn = await self.brain.ask(text, client: .iphone) { sentence in
                guard current == self.exchange else { return }
                if self.phase == .thinking { self.phase = .answering }
                self.liveAnswer = Self.join(self.liveAnswer, sentence)
                self.speaker.say(sentence)
            }
            guard current == self.exchange else { return }
            self.openWhenSpoken = turn.cards.first { $0.opensWhenSpoken }?.link
            if self.phase == .thinking { self.phase = .answering }
            self.speaker.finish()
        }
    }

    /// Tapped, or started talking, while Ember was thinking or answering.
    private func interrupt() {
        exchange += 1
        answering?.cancel()
        speaker.stop()
        clearTurn()
        lastHeard = .now
        phase = .listening
        watch()
    }

    private func isEcho(_ text: String) -> Bool {
        guard !speaker.spokenText.isEmpty else { return false }
        let said = Set(Self.words(speaker.spokenText))
        return Self.words(text).allSatisfy { said.contains($0) }
    }

    nonisolated static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    nonisolated private static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    // MARK: Permissions

    private nonisolated static func permissionsGranted() async -> Bool {
        let speech: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        case let status:
            speech = status
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
