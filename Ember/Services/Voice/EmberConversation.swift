import AVFoundation
import Foundation
import Observation
import os
import OSLog
import Speech
import UIKit

// Talking with Ember, built the way Ask Suffice and Sated's Coach are (they work well; this
// follows Suffice/Services/Voice/Conversation.swift closely):
//
// - The voice screen is its own place. Opening it turns the microphone on; it stays on until
//   the screen closes or nothing is said for 45 seconds.
// - Pause for a moment (or tap Send) and what you said goes to Ember, which answers out loud,
//   then listens again. Start talking while it thinks or talks and it stops to listen (two clear
//   words that aren't its own; voice processing keeps its voice out of the microphone).
// - Speech is recognized on the iPhone (SFSpeechRecognizer, on-device only).
// - Typed questions and suggestion taps use the same brain and are answered out loud too, with
//   the microphone off.

@Observable
final class EmberConversation {
    static let shared = EmberConversation()

    enum Phase: Equatable {
        /// The voice screen is closed (typed questions show their own thinking state).
        case idle
        case starting
        case listening
        case thinking
        case speaking
        /// Nothing said for a while: the microphone is off until Resume.
        case paused
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The voice screen is up.
    var isVoicePresented = false
    /// What you're saying now.
    private(set) var transcript = ""
    /// The question being answered (or last answered).
    private(set) var question = ""
    /// The answer as it's being spoken.
    private(set) var liveAnswer = ""
    /// The finished turn for the question on screen.
    private(set) var replyID: UUID?
    /// What a "yes", "undo" or a tapped Confirm did, shown under the answer it belongs to.
    private(set) var localReply: String?
    /// A typed question is being answered (the thread shows the thinking row).
    private(set) var isAnsweringTyped = false

    @ObservationIgnored private let brain = EmberBrain.shared
    @ObservationIgnored private let audio = EmberAudio.shared
    @ObservationIgnored private let speaker = EmberSpeaker.shared
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// The request the microphone feeds, read on the audio thread.
    @ObservationIgnored private let request = OSAllocatedUnfairLock<SFSpeechAudioBufferRecognitionRequest?>(uncheckedState: nil)
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Bumped for every recognition request, so results from an old one are ignored.
    @ObservationIgnored private var turn = 0
    /// Bumped for every question (and on barge-in), so a stale answer isn't spoken.
    @ObservationIgnored private var exchange = 0
    @ObservationIgnored private var answering: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = Date.now
    @ObservationIgnored private var turnStarted = Date.now
    /// A handoff to open once the answer has been spoken (a call, directions).
    @ObservationIgnored private var openWhenSpoken: URL?
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.ember", category: "conversation")

    /// How long a silence ends your turn.
    var pause: Double { EmberSettings.shared.listeningPause }
    /// After this long with nothing said, the microphone turns off.
    private let idleLimit: TimeInterval = 45

    var isListening: Bool { phase == .listening }

    // MARK: The voice screen

    /// Opens the voice screen (the mic button, Siri, the Action button).
    func presentVoice() {
        isVoicePresented = true
    }

    /// Called by the voice screen when it appears.
    func startVoice() async {
        phase = .starting
        speaker.stop()
        guard await Self.permissionsGranted() else {
            phase = .failed("Ember needs the microphone and speech recognition to listen. Turn them on in Settings › Ember.")
            return
        }
        guard let recognizer, recognizer.isAvailable, Self.canRecognize(with: recognizer) else {
            phase = .failed("Speech recognition isn’t available on this iPhone right now. You can type instead.")
            return
        }
        let request = self.request
        do {
            try await audio.start { buffer in
                request.withLockUnchecked { $0 }?.append(buffer)
                EmberMicLevel.report(buffer)
            }
        } catch {
            log.error("Couldn't start listening: \(error.localizedDescription, privacy: .public)")
            phase = .failed("Ember couldn’t start the microphone. Check that it isn’t in use, then try again.")
            return
        }
        EmberData.shared.prefetch()
        transcript = ""
        lastHeard = .now
        phase = .listening
        beginTurn()
        watch()
    }

    /// Microphone off, Ember quiet (the voice screen closed, or nothing was said for a while).
    func stopVoice(pausing: Bool = false) {
        exchange += 1
        turn += 1
        answering?.cancel()
        watcher?.cancel()
        watcher = nil
        endRecognition()
        speaker.stop()
        audio.stop()
        EmberLevelMeter.shared.value = 0
        transcript = ""
        phase = pausing ? .paused : .idle
    }

    func resume() async {
        await startVoice()
    }

    /// Ends your turn now instead of waiting for the pause.
    func finishSpeaking() {
        guard phase == .listening, !transcript.isEmpty else { return }
        endTurn()
    }

    /// Stops Ember mid-sentence and listens.
    func interrupt() {
        guard phase == .speaking || phase == .thinking else { return }
        bargeIn()
    }

    // MARK: Typed questions, suggestions, Siri

    /// Ask without speaking. Ember answers out loud as well; with the voice screen up the
    /// question joins that conversation.
    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if isVoicePresented, phase != .idle, phase != .paused {
            transcript = ""
            send(question, voice: true)
        } else {
            send(question, voice: false)
        }
    }

    /// Says what a tapped Confirm or Undo did.
    func speakResult(_ text: String) {
        localReply = text
        speaker.begin { }
        speaker.say(text)
        speaker.finish()
    }

    /// Starts a new conversation: the thread clears and Ember forgets the follow-ups.
    func newConversation() {
        exchange += 1
        answering?.cancel()
        speaker.stop()
        brain.reset()
        question = ""
        liveAnswer = ""
        replyID = nil
        localReply = nil
        isAnsweringTyped = false
    }

    // MARK: Recognition

    /// A fresh recognition request. One is always running while the voice screen is up, so you
    /// can be heard while Ember thinks or talks.
    private func beginTurn() {
        endRecognition()
        guard let recognizer else { return }
        turn += 1
        let current = turn
        turnStarted = .now
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Self.contextualStrings
        self.request.withLockUnchecked { $0 = request }
        task = Self.recognize(with: recognizer, request: request) { [weak self] text, isFinal, failed in
            let conversation = self
            Task { @MainActor in conversation?.heard(text, isFinal: isFinal || failed, turn: current) }
        }
    }

    private func endRecognition() {
        request.withLockUnchecked { request in
            request?.endAudio()
            request = nil
        }
        task?.cancel()
        task = nil
    }

    private func heard(_ text: String?, isFinal: Bool, turn current: Int) {
        guard current == turn else { return }
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != transcript {
            switch phase {
            case .speaking, .thinking:
                // Ember's own voice can leak through; only real words from you interrupt.
                if Self.words(text).count >= 2, !isEcho(text) {
                    bargeIn()
                    transcript = text
                    lastHeard = .now
                }
            case .listening:
                transcript = text
                lastHeard = .now
            default:
                break
            }
        }
        if isFinal {
            // The recognizer ended the request itself (a long silence, or its time limit).
            if phase == .listening, !transcript.isEmpty {
                endTurn()
            } else if phase == .listening || phase == .thinking || phase == .speaking {
                beginTurn()
            }
        }
    }

    /// Checks for the end of your turn, and keeps recognition requests short.
    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard phase == .listening else { return }
        let quiet = Date.now.timeIntervalSince(lastHeard)
        // Still making sound mid-word: not a pause yet.
        if EmberLevelMeter.shared.value > 0.35 {
            lastHeard = .now
            return
        }
        if !transcript.isEmpty, quiet >= pause {
            endTurn()
        } else if transcript.isEmpty {
            if quiet >= idleLimit {
                stopVoice(pausing: true)
            } else if Date.now.timeIntervalSince(turnStarted) > 50 {
                // Recognition requests are limited to about a minute.
                beginTurn()
            }
        }
    }

    // MARK: Turns

    private func endTurn() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        transcript = ""
        send(text, voice: true)
    }

    private func send(_ text: String, voice: Bool) {
        exchange += 1
        let current = exchange
        answering?.cancel()
        speaker.stop()
        question = text
        liveAnswer = ""
        localReply = nil
        replyID = nil
        openWhenSpoken = nil
        if voice {
            phase = .thinking
            // Keep listening while Ember thinks, so you can add to or change your question.
            beginTurn()
        } else {
            isAnsweringTyped = true
        }
        speaker.begin { [weak self] in
            guard let self, current == self.exchange else { return }
            self.spoken(voice: voice)
        }

        // "Yes", "no" and "undo" answer a waiting action here, without a model, so what
        // happens is exactly what the card said.
        if let reply = EmberActions.shared.reply(in: text) {
            answering = Task { [weak self] in
                guard let self else { return }
                let said: String = switch reply {
                case .yes: await EmberActions.shared.confirm()
                case .no: EmberActions.shared.cancel()
                case .undo: await EmberActions.shared.undo()
                }
                guard current == self.exchange else { return }
                self.localReply = said
                self.isAnsweringTyped = false
                if voice { self.phase = .speaking }
                self.speaker.say(said)
                self.speaker.finish()
            }
            return
        }

        answering = Task { [weak self] in
            guard let self else { return }
            let turn = await self.brain.ask(text, client: .iphone) { [weak self] sentence in
                guard let self, current == self.exchange else { return }
                if voice, self.phase == .thinking { self.phase = .speaking }
                self.liveAnswer = self.liveAnswer.isEmpty ? sentence : self.liveAnswer + " " + sentence
                self.speaker.say(sentence)
            }
            guard current == self.exchange else { return }
            self.replyID = turn.id
            self.isAnsweringTyped = false
            self.openWhenSpoken = turn.cards.first { $0.opensWhenSpoken }?.link
            if voice, self.phase == .thinking { self.phase = .speaking }
            self.speaker.finish()
        }
    }

    /// The answer has been spoken: open what it handed off (a call, directions, a message), or
    /// listen again.
    private func spoken(voice: Bool) {
        if let url = openWhenSpoken {
            openWhenSpoken = nil
            if voice {
                stopVoice()
                isVoicePresented = false
            }
            UIApplication.shared.open(url)
        } else if EmberCompose.shared.hasQueued {
            if voice {
                stopVoice()
                isVoicePresented = false
            }
            EmberCompose.shared.presentQueued()
        } else if voice, phase == .speaking || phase == .thinking {
            phase = .listening
            lastHeard = .now
        }
    }

    /// You started talking while Ember was thinking or speaking.
    private func bargeIn() {
        exchange += 1
        answering?.cancel()
        speaker.stop()
        phase = .listening
        lastHeard = .now
    }

    /// Words heard while Ember talks that are all in what it's saying (as written and as
    /// spoken): its own voice leaking past echo cancellation, not you.
    private func isEcho(_ text: String) -> Bool {
        guard phase == .speaking else { return false }
        let said = Set(Self.words(speaker.spokenText) + Self.words(speaker.writtenText) + Self.words(liveAnswer))
        guard !said.isEmpty else { return false }
        let heard = Self.words(text)
        let matched = heard.filter { said.contains($0) }.count
        return Double(matched) / Double(max(heard.count, 1)) >= 0.8
    }

    nonisolated static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The apps' names and the household's, so the recognizer writes them right.
    private static var contextualStrings: [String] {
        ["Ember", "Suffice", "Caloma", "BigTable", "Sated", "Hearken"] + EmberContext.shared.people.map(\.name)
    }

    // MARK: Permissions and recognition helpers

    private nonisolated static func recognize(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    /// On a real iPhone, only on-device recognition is allowed. The Simulator has none.
    private static func canRecognize(with recognizer: SFSpeechRecognizer) -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return recognizer.supportsOnDeviceRecognition
        #endif
    }

    private nonisolated static func permissionsGranted() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
