import AVFoundation
import CoreMedia
import Foundation
import Observation
import OSLog
import Speech
import UIKit

// One spoken exchange at a time, driven by the orb (the "Ember · Hearth AI" canvas):
//
//   idle ──tap──▶ listening ──end of turn──▶ thinking ──▶ answering ──done──▶ idle
//              ▲  (or hold the orb, release to send)              │
//              └──── tap, or talk over it (clearly, up close) ─────┘   (barge-in)
//
// Speech is recognized on the iPhone with SpeechAnalyzer (nothing leaves the device). Rooms are
// noisy and full of other voices, so three things decide what counts as the person talking to
// Ember:
//
// 1. Up close. Each recognized phrase is measured against the room's background
//    (EmberMicrophoneFeed.loudness): the person holding the phone is far louder than the TV or
//    someone across the room. Phrases from across the room are dropped, and a room that keeps
//    producing them is flagged as noisy (hold to talk is suggested, and turns wait a moment
//    before sending so a wrong one can be stopped).
// 2. Not Ember. While Ember talks, what it hears is compared with what it's saying (as written
//    and as spoken), and the echo that trails each piece is ignored.
// 3. Clearly meant. Talking over Ember first lowers its voice; only several close, non-echo
//    words stop it. While it's thinking (nothing playing), voices never interrupt; a tap does.
//
// The microphone and recognizer stay open for a short while between turns (muted, nothing is
// transcribed), so the next tap listens at once instead of rebuilding the audio engine.

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
    /// What a "yes", "undo" or a tapped Confirm did, shown under the answer it belongs to.
    private(set) var localReply: String?
    /// Other voices keep reaching the microphone: hold to talk works better here.
    private(set) var isNoisyRoom = false
    /// Holding the orb: listening until it's let go.
    private(set) var isHolding = false
    /// A turn about to be sent in a noisy room; a tap stops it.
    private(set) var pendingSend: String?

    /// Silence that ends a turn, and a shorter one when what was said sounds finished.
    static let pause: TimeInterval = 0.9
    static let shortPause: TimeInterval = 0.6
    /// The longest one turn may run once it has started.
    static let longestTurn: TimeInterval = 12
    /// How far above the room's background speech must be to count as the person holding the
    /// phone, in dB.
    static let closeEnough: Double = 12
    /// How long the microphone stays open (muted) after an answer.
    static let keepOpen: TimeInterval = 20

    @ObservationIgnored private let brain = EmberBrain.shared
    @ObservationIgnored private let audio = EmberAudio.shared
    @ObservationIgnored private let speaker = EmberSpeaker.shared
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: EmberMicrophoneFeed?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var answering: Task<Void, Never>?
    @ObservationIgnored private var teardown: Task<Void, Never>?
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var exchange = 0
    /// A handoff to open once the answer has been spoken (a call).
    @ObservationIgnored private var openWhenSpoken: URL?
    /// Ember just asked something (which one, or whether to go ahead).
    @ObservationIgnored private var awaitsChoice = false
    @ObservationIgnored private var settled = ""
    @ObservationIgnored private var volatile = ""
    @ObservationIgnored private var consumedUntil = CMTime.zero
    @ObservationIgnored private var latestEnd = CMTime.zero
    /// When the person last said something that counted.
    @ObservationIgnored private var lastHeard = Date.now
    @ObservationIgnored private var listeningSince = Date.now
    @ObservationIgnored private var firstWordAt: Date?
    /// How loud this person is up close (the peak of their accepted speech), once known.
    @ObservationIgnored private var ownPeak: Double?
    /// Phrases dropped as coming from across the room, this conversation.
    @ObservationIgnored private var farPhrases = 0
    @ObservationIgnored private var duckedAt: Date?
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.ember", category: "conversation")

    // MARK: The orb

    /// Tap: listen when idle, send when listening, stop Ember and listen when it's thinking or
    /// talking, stop a turn about to be sent.
    func tapOrb() {
        if pendingSend != nil {
            cancelPendingSend()
            return
        }
        switch phase {
        case .idle, .failed:
            Task { await listen() }
        case .listening:
            if transcript.isEmpty { cancel() } else { endTurn(immediately: true) }
        case .thinking, .answering:
            interrupt()
        }
    }

    /// Holding the orb: listen until it's let go, then send. Nothing ends the turn early, so
    /// other voices can't cut in.
    func beginHold() {
        isHolding = true
        cancelPendingSend()
        if phase == .thinking || phase == .answering {
            interrupt()
        } else if phase != .listening {
            Task { await listen() }
        }
    }

    func endHold() {
        guard isHolding else { return }
        isHolding = false
        guard phase == .listening else { return }
        // A beat for the last word to be recognized.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard phase == .listening else { return }
            if transcript.isEmpty { cancel() } else { endTurn(immediately: true) }
        }
    }

    /// Ask without speaking (a suggestion chip, typing, Siri). Ember still answers out loud.
    func ask(_ text: String) {
        Task {
            if !audio.isRunning { try? await startAudio() }
            send(text)
        }
    }

    /// Says what a tapped Confirm or Undo did, in the answer's place.
    func speakResult(_ text: String) {
        exchange += 1
        let current = exchange
        localReply = text
        phase = .answering
        Task {
            if !audio.isRunning { try? await startAudio() }
            guard current == exchange else { return }
            speaker.begin { [weak self] in
                guard let self, current == self.exchange else { return }
                self.phase = .idle
                self.park()
            }
            speaker.say(text)
            speaker.finish()
        }
    }

    /// The X while listening: back to idle, nothing sent.
    func cancel() {
        exchange += 1
        answering?.cancel()
        cancelPendingSend()
        clearTurn()
        isHolding = false
        phase = .idle
        park()
    }

    // MARK: Listening

    /// `keepingAnswer`: a follow-up Ember asked for; the question and choices stay on screen.
    private func listen(keepingAnswer: Bool = false) async {
        guard await Self.permissionsGranted() else {
            phase = .failed("Ember needs the microphone and speech recognition to listen. Turn them on in Settings › Ember.")
            return
        }
        teardown?.cancel()
        do {
            if !audio.isRunning { try await startAudio() }
        } catch {
            log.error("Couldn't start listening: \(String(describing: error), privacy: .public)")
            stopAudio()
            phase = .failed("Ember couldn’t start listening. Check that the microphone isn’t in use, then try again.")
            return
        }
        speaker.stop()
        if !keepingAnswer { clearTurn() }
        EmberData.shared.prefetch()
        lastHeard = .now
        listeningSince = .now
        firstWordAt = nil
        // Everything heard while muted is behind us.
        consumedUntil = latestEnd
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

    /// Between turns: the microphone stays open but muted (nothing is transcribed), so the next
    /// tap listens at once. It closes after `keepOpen` seconds.
    private func park() {
        watcher?.cancel()
        watcher = nil
        feed?.setMuted(true)
        level = 0
        teardown?.cancel()
        guard audio.isRunning else { return }
        teardown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.keepOpen))
            guard let self, !Task.isCancelled, self.phase == .idle || self.isFailed else { return }
            self.stopAudio()
        }
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private func stopAudio() {
        teardown?.cancel()
        teardown = nil
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
        ownPeak = nil
        farPhrases = 0
        isNoisyRoom = false
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

    // MARK: What was heard

    private func heard(_ text: String, isFinal: Bool, range: CMTimeRange) {
        guard CMTimeCompare(range.start, consumedUntil) >= 0 else { return }
        let end = CMTimeRangeGetEnd(range)
        if CMTimeCompare(end, latestEnd) > 0 { latestEnd = end }

        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }

        // 1. Up close, or from across the room?
        let close = isClose(range)

        switch phase {
        case .listening:
            guard close else {
                // Someone else in the room: not part of this turn.
                if isFinal { noteFarPhrase() }
                return
            }
            if isFinal {
                settled = Self.join(settled, words)
                volatile = ""
            } else {
                volatile = words
            }
            let combined = Self.join(settled, volatile)
            if combined != transcript {
                transcript = combined
                lastHeard = .now
                if firstWordAt == nil { firstWordAt = .now }
            }

        case .answering:
            // 2. Ember's own voice coming back, or its trailing echo?
            if isEcho(words) || Date.now.timeIntervalSince(speaker.lastPlayedAt) < 0.3 && !speaker.isSpeaking { return }
            guard close else {
                if isFinal { noteFarPhrase() }
                return
            }
            // 3. Talking over Ember: lower its voice first; stop it only for several clear words.
            speaker.duck(true)
            duckedAt = .now
            let fresh = Self.words(words).filter { !echoWords.contains($0) }
            if fresh.count >= 3 {
                interrupt()
                // Keep the rest of this phrase: it's the start of their question.
                consumedUntil = range.start
                settled = isFinal ? words : ""
                volatile = isFinal ? "" : words
                transcript = words
                lastHeard = .now
                firstWordAt = .now
            }

        case .thinking:
            // Nothing is playing; voices never interrupt a question being answered (a tap does).
            return

        case .idle, .failed:
            return
        }
    }

    /// Whether a phrase came from the person holding the phone: well above the room's
    /// background, and not far below how loud they've been so far.
    private func isClose(_ range: CMTimeRange) -> Bool {
        guard let feed else { return true }
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        guard start.isFinite, end.isFinite, let loudness = feed.loudness(from: start, to: max(end, start + 0.05)) else { return true }
        var close = loudness.aboveFloor >= Self.closeEnough
        if let ownPeak, loudness.peak < ownPeak - 14 { close = false }
        if close {
            // Learn how loud this person is, slowly.
            ownPeak = ownPeak.map { $0 * 0.8 + loudness.peak * 0.2 } ?? loudness.peak
        }
        return close
    }

    private func noteFarPhrase() {
        farPhrases += 1
        if farPhrases >= 2, !isNoisyRoom {
            isNoisyRoom = true
            log.notice("Noisy room: suggesting hold to talk")
        }
    }

    private var echoWords: Set<String> {
        Set(Self.words(speaker.spokenText) + Self.words(speaker.writtenText) + Self.words(liveAnswer))
    }

    /// Everything heard is something Ember is saying (as written or as spoken).
    private func isEcho(_ text: String) -> Bool {
        let said = echoWords
        guard !said.isEmpty else { return false }
        let heard = Self.words(text)
        let matched = heard.filter { said.contains($0) }.count
        // Most of it matches: recognition of an echo is rarely word-perfect.
        return !heard.isEmpty && Double(matched) / Double(heard.count) >= 0.7
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
        // Ember's voice comes back up when nobody kept talking over it.
        if let duckedAt, Date.now.timeIntervalSince(duckedAt) > 1.2 {
            speaker.duck(false)
            self.duckedAt = nil
        }
        guard phase == .listening, !isHolding, pendingSend == nil else { return }
        let quiet = Date.now.timeIntervalSince(lastHeard)
        if transcript.isEmpty {
            // Nothing said up close: stop listening (sooner after a question Ember asked).
            if quiet >= (awaitsChoice ? 6 : 12) { cancel() }
            return
        }
        // The turn ends on silence from the person (not the room), sooner when it sounds done,
        // and never runs on forever in a room that's never quiet.
        let pause = Self.soundsFinished(transcript) ? Self.shortPause : Self.pause
        let tooLong = firstWordAt.map { Date.now.timeIntervalSince($0) > Self.longestTurn } ?? false
        if quiet >= pause || tooLong { endTurn(immediately: false) }
    }

    /// A rough read of whether a request sounds complete ("…this week?" yes; "…and the" no).
    static func soundsFinished(_ text: String) -> Bool {
        let words = Self.words(text)
        guard words.count >= 3, let last = words.last else { return false }
        if text.hasSuffix("?") || text.hasSuffix(".") { return true }
        let dangling: Set<String> = ["and", "or", "but", "the", "a", "an", "to", "for", "of", "with", "at", "in", "on", "my", "our",
                                     "is", "was", "um", "uh", "like", "so", "if", "then", "that", "about", "from"]
        return !dangling.contains(last)
    }

    // MARK: Turns

    /// `immediately`: the person ended it (a tap, letting go of the orb). Otherwise, in a noisy
    /// room, the turn waits a moment on screen so a wrong one can be stopped.
    private func endTurn(immediately: Bool) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .idle
            park()
            return
        }
        if !immediately, isNoisyRoom {
            pendingSend = text
            sending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, !Task.isCancelled, self.pendingSend == text else { return }
                self.pendingSend = nil
                self.clearTurn()
                self.send(text)
            }
            return
        }
        clearTurn()
        send(text)
    }

    private func cancelPendingSend() {
        guard pendingSend != nil else { return }
        sending?.cancel()
        sending = nil
        pendingSend = nil
        clearTurn()
        lastHeard = .now
        firstWordAt = nil
    }

    private func send(_ text: String) {
        exchange += 1
        let current = exchange
        // Muted while Ember thinks: nothing heard now belongs to anything. It listens again
        // (for barge-in) once it starts talking.
        feed?.setMuted(true)
        watcher?.cancel()
        phase = .thinking
        question = text
        liveAnswer = ""
        openWhenSpoken = nil
        awaitsChoice = false
        speaker.begin { [weak self] in
            guard let self, current == self.exchange else { return }
            // Done talking.
            self.phase = .idle
            // A call, Maps or a message sheet needs the audio: close the microphone now.
            if let url = self.openWhenSpoken {
                self.openWhenSpoken = nil
                self.stopAudio()
                UIApplication.shared.open(url)
            } else if EmberCompose.shared.hasQueued {
                self.stopAudio()
                EmberCompose.shared.presentQueued()
            } else if self.awaitsChoice {
                // Ember asked a question ("which one?", "should I?"): listen for the answer
                // without another tap, briefly.
                Task { await self.listen(keepingAnswer: true) }
            } else {
                self.park()
            }
        }

        // "Yes", "no" and "undo that" answer a waiting action here, without a model, so what
        // happens is exactly what the card said.
        if let reply = EmberActions.shared.reply(in: text) {
            answering = Task { [weak self] in
                guard let self else { return }
                let spoken: String = switch reply {
                case .yes: await EmberActions.shared.confirm()
                case .no: EmberActions.shared.cancel()
                case .undo: await EmberActions.shared.undo()
                }
                guard current == self.exchange else { return }
                self.startAnswering()
                self.localReply = spoken
                self.speaker.say(spoken)
                self.speaker.finish()
            }
            return
        }

        localReply = nil
        answering = Task { [weak self] in
            guard let self else { return }
            let turn = await self.brain.ask(text, client: .iphone) { sentence in
                guard current == self.exchange else { return }
                if self.phase == .thinking { self.startAnswering() }
                self.liveAnswer = Self.join(self.liveAnswer, sentence)
                self.speaker.say(sentence)
            }
            guard current == self.exchange else { return }
            self.openWhenSpoken = turn.cards.first { $0.opensWhenSpoken }?.link
            self.awaitsChoice = turn.asksBack
            if self.phase == .thinking { self.startAnswering() }
            self.speaker.finish()
        }
    }

    /// Ember starts talking: listen again, but only for someone talking over it.
    private func startAnswering() {
        phase = .answering
        consumedUntil = latestEnd
        feed?.setMuted(false)
        watch()
    }

    /// Tapped, or clearly talked over, while Ember was thinking or answering.
    private func interrupt() {
        exchange += 1
        answering?.cancel()
        cancelPendingSend()
        speaker.stop()
        clearTurn()
        lastHeard = .now
        listeningSince = .now
        firstWordAt = nil
        feed?.setMuted(false)
        phase = .listening
        watch()
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
