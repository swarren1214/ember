import Foundation
import FoundationModels
import Observation
import OSLog

// One turn of conversation, routed to the best resource available (implementation plan ›
// Routing rule), with the privacy rules applied on the way out:
//
//   1. Apple's on-device model, with Ember's tools. Nothing leaves the device.
//   2. Apple's Private Cloud Compute — not wired yet (needs the iOS 27 entitlement; see README).
//   3. Claude through hearth-api, when the person allowed it (Cloud Help) and the turn needs it:
//      planning across apps or days, no on-device model, or the on-device model couldn't answer.
//      Everything sent is de-identified by EmberRedactor; tools still run here.
//
// Kids' turns never leave the device. The tier is chosen here, in code, never by a model.

/// One question and its answer, with what it drew on.
struct EmberTurn: Identifiable {
    let id = UUID()
    var question: String
    var answer: String
    var cards: [EmberCard] = []
    var sources: [HearthApp] = []
    var tier: EmberTier = .none
    /// Exactly what went to the cloud for this turn (privacy rule 6), when anything did.
    var sentToCloud: String?
    var isNotice = false
}

enum EmberClient: String {
    case iphone, watch
}

@Observable
final class EmberBrain {
    static let shared = EmberBrain()

    private(set) var turns: [EmberTurn] = []
    private(set) var isThinking = false

    @ObservationIgnored private let toolbox = EmberToolbox.shared
    @ObservationIgnored private var session: LanguageModelSession?
    /// One redactor per conversation, so a person keeps the same token across follow-ups.
    @ObservationIgnored private var redactor: EmberRedactor?
    /// The conversation as the cloud has seen it (already de-identified).
    @ObservationIgnored private var cloudHistory: [EmberCloudMessage] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.ember", category: "brain")

    static var onDeviceAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var latest: EmberTurn? { turns.last }

    /// Loads the on-device model ahead of the first question.
    func prewarm() {
        guard Self.onDeviceAvailable, session == nil else { return }
        let session = makeSession()
        session.prewarm()
        self.session = session
    }

    /// Clear: a new conversation (new tokens, empty history).
    func reset() {
        turns = []
        session = nil
        redactor = nil
        cloudHistory = []
    }

    // MARK: Asking

    /// Answers `question`, calling `onSentence` with each sentence as it's ready (for the voice),
    /// and returns the finished turn.
    @discardableResult
    func ask(_ question: String, client: EmberClient, onSentence: @escaping (String) -> Void) async -> EmberTurn {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        isThinking = true
        defer { isThinking = false }
        toolbox.beginTurn()

        let route = Route.choose(for: text, client: client)
        var turn = EmberTurn(question: text, answer: "")

        switch route {
        case .onDevice(let fallbackToCloud):
            do {
                let answer = try await respondOnDevice(text)
                turn.answer = answer
                turn.tier = .onDevice
                Self.sentences(in: answer).forEach(onSentence)
            } catch {
                log.notice("On-device turn failed: \(String(describing: error), privacy: .public)")
                if fallbackToCloud {
                    turn = await respondInCloud(text, client: client, onSentence: onSentence)
                } else {
                    turn.answer = Self.message(for: error)
                    turn.isNotice = true
                    onSentence(turn.answer)
                }
            }
        case .cloud:
            turn = await respondInCloud(text, client: client, onSentence: onSentence)
        case .unavailable(let reason):
            turn.answer = reason
            turn.isNotice = true
            onSentence(reason)
        }

        if turn.cards.isEmpty { turn.cards = toolbox.takeCards() }
        if turn.sources.isEmpty { turn.sources = toolbox.usedApps }
        turns.append(turn)
        return turn
    }

    // MARK: Routing

    enum Route: Equatable {
        /// `fallbackToCloud`: escalate if the on-device model can't answer.
        case onDevice(fallbackToCloud: Bool)
        case cloud
        case unavailable(String)

        @MainActor
        static func choose(for question: String, client: EmberClient) -> Route {
            let settings = EmberSettings.shared
            let kid = EmberContext.shared.isKid
            let claude = !kid && settings.cloudHelp?.allowsClaude == true
            let onDevice = EmberBrain.onDeviceAvailable
            if kid && !settings.kidsCanTalk {
                return .unavailable("Ask a parent to turn on Kids Can Talk to Ember.")
            }
            if onDevice {
                // Planning across apps or days is where the bigger model earns its keep.
                if claude && EmberBrain.isPlanning(question) { return .cloud }
                return .onDevice(fallbackToCloud: claude)
            }
            if claude { return .cloud }
            return .unavailable("Ember needs Apple Intelligence on this \(DeviceName.current), or Cloud Help turned on in What Ember Knows.")
        }
    }

    /// A cheap, on-device read of whether a question plans across apps or days.
    static func isPlanning(_ question: String) -> Bool {
        let text = question.lowercased()
        let planWords = ["plan ", "plan.", "this week", "next week", "weekend", "afford", "budget for", "schedule", "organize", "figure out", "should we"]
        let domains = [["dinner", "meal", "cook", "recipe", "groceries", "grocery"],
                       ["budget", "spend", "money", "afford", "cost"],
                       ["chore", "calendar", "practice", "game", "birthday", "reading"]]
        let domainCount = domains.filter { words in words.contains { text.contains($0) } }.count
        return planWords.contains { text.contains($0) } || domainCount >= 2
    }

    /// General knowledge with nothing about the household: the only turns Claude may search the
    /// web for.
    static func isGeneralKnowledge(_ question: String) -> Bool {
        let text = question.lowercased()
        let household = ["we ", "our ", "my ", " me ", "us ", "tonight", "today", "tomorrow", "kids", "budget", "plan"]
        let general = ["how long", "how do i", "how do you", "what is", "what's the difference", "substitute", "temperature", "how much"]
        return general.contains { text.hasPrefix($0) || text.contains(" " + $0) } && !household.contains { text.contains($0) }
    }

    // MARK: On device

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(tools: EmberTools.onDevice(toolbox), instructions: EmberPrompt.instructions(names: true))
    }

    private func respondOnDevice(_ question: String) async throws -> String {
        let session = self.session ?? makeSession()
        self.session = session
        do {
            let reply = try await session.respond(to: question, options: GenerationOptions(temperature: 0.3)).content
            return EmberPrompt.clean(reply)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                // A long conversation filled the model's context: start fresh and ask again.
                self.session = makeSession()
                return EmberPrompt.clean(try await self.session!.respond(to: question).content)
            }
            throw error
        }
    }

    // MARK: Claude via hearth-api

    private func respondInCloud(_ question: String, client: EmberClient, retried: Bool = false, onSentence: @escaping (String) -> Void) async -> EmberTurn {
        var turn = EmberTurn(question: question, answer: "", tier: .claude)
        var redactor = self.redactor ?? EmberRedactor(household: EmberContext.shared.redactionPeople)
        defer { self.redactor = redactor }

        var messages = Array(cloudHistory.suffix(12))
        messages.append(EmberCloudMessage(role: "user", content: [.text(redactor.redact(question))]))
        var sentLog: [String] = []
        var splitter = EmberSentenceSplitter()
        var answer = ""
        let tools = toolbox.toolNames

        do {
            for _ in 0..<6 {
                let request = EmberCloudRequest(
                    profile: Self.isPlanning(question) ? "plan" : "quick",
                    client: client.rawValue,
                    locale: Locale.current.identifier,
                    timeZone: TimeZone.current.identifier,
                    now: Date.now.formatted(date: .complete, time: .shortened),
                    roster: redactor.roster,
                    messages: messages,
                    tools: tools,
                    allowWebSearch: Self.isGeneralKnowledge(question)
                )
                // Belt and braces: nothing that still looks like an identifier is sent.
                let outgoing = Self.text(of: messages)
                guard EmberRedactor.leaks(in: outgoing).isEmpty else { throw EmberCloudError.refused }
                if let json = EmberWire.encode(request), let pretty = String(data: json, encoding: .utf8) { sentLog.append(pretty) }

                var assistantBlocks: [EmberCloudBlock] = []
                var toolUses: [(id: String, name: String, input: [String: EmberJSON])] = []
                var replyText = ""
                let events = try await stream(request)
                for try await event in events {
                    switch event {
                    case .text(let delta):
                        replyText += delta
                        for sentence in splitter.feed(delta) {
                            let restored = EmberPrompt.clean(redactor.restore(sentence))
                            answer = answer.isEmpty ? restored : answer + " " + restored
                            onSentence(restored)
                        }
                    case .toolUse(let id, let name, let input):
                        toolUses.append((id, name, input))
                    case .done:
                        break
                    }
                }
                if !replyText.isEmpty { assistantBlocks.append(.text(replyText)) }
                guard !toolUses.isEmpty else {
                    messages.append(EmberCloudMessage(role: "assistant", content: assistantBlocks))
                    break
                }
                // Claude asked for tools: run them here, de-identify the results, continue.
                var results: [EmberCloudBlock] = []
                for use in toolUses {
                    assistantBlocks.append(.toolUse(id: use.id, name: use.name, input: use.input))
                    let output = toolbox.run(use.name, input: Self.restored(use.input, with: redactor))
                    results.append(.toolResult(id: use.id, content: redactor.redact(output)))
                }
                messages.append(EmberCloudMessage(role: "assistant", content: assistantBlocks))
                messages.append(EmberCloudMessage(role: "user", content: results))
            }
            if let rest = splitter.flush() {
                let restored = EmberPrompt.clean(redactor.restore(rest))
                answer = answer.isEmpty ? restored : answer + " " + restored
                onSentence(restored)
            }
            turn.answer = answer.isEmpty ? "Done." : answer
            // Keep only the text of each exchange for follow-ups; tool results don't carry over.
            cloudHistory.append(EmberCloudMessage(role: "user", content: [.text(redactor.redact(question))]))
            cloudHistory.append(EmberCloudMessage(role: "assistant", content: [.text(redactor.redact(turn.answer))]))
        } catch let error as URLError where error.code == .userAuthenticationRequired && !retried && answer.isEmpty {
            // The token expired between checking and sending: renew it and ask once more.
            _ = try? await EmberAPI.shared.accessToken(renew: true)
            return await respondInCloud(question, client: client, retried: true, onSentence: onSentence)
        } catch {
            log.error("Cloud turn failed: \(String(describing: error), privacy: .public)")
            turn.answer = (error as? EmberCloudError)?.errorDescription ?? EmberCloudError.failed.errorDescription!
            turn.isNotice = true
            turn.tier = .none
            onSentence(turn.answer)
        }
        turn.sentToCloud = sentLog.isEmpty ? nil : sentLog.joined(separator: "\n\n")
        return turn
    }

    /// The route's stream. The token is refreshed a minute before it expires; a 401 anyway is
    /// retried once from the top (`respondInCloud(retried:)`).
    private func stream(_ request: EmberCloudRequest) async throws -> AsyncThrowingStream<EmberCloudEvent, Error> {
        let client = EmberCloudClient(baseURL: AppConfig.apiBaseURL)
        return client.turn(request, accessToken: try await EmberAPI.shared.accessToken())
    }

    /// Tool input names people by token ("[P2]"); tools need the real name back.
    private static func restored(_ input: [String: EmberJSON], with redactor: EmberRedactor) -> [String: EmberJSON] {
        input.mapValues { value in
            if case .string(let text) = value { return .string(redactor.restore(text)) }
            return value
        }
    }

    private static func text(of messages: [EmberCloudMessage]) -> String {
        messages.flatMap(\.content).compactMap { $0.text ?? $0.content }.joined(separator: "\n")
    }

    static func sentences(in text: String) -> [String] {
        var splitter = EmberSentenceSplitter()
        var result = splitter.feed(text)
        if let rest = splitter.flush() { result.append(rest) }
        return result
    }

    static func message(for error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                return "I can’t help with that one."
            case .unsupportedLanguageOrLocale:
                return "I can only answer in a language your \(DeviceName.current)’s built-in AI supports."
            case .assetsUnavailable:
                return "Your \(DeviceName.current)’s built-in AI is getting ready. Try again in a little while."
            default:
                break
            }
        }
        return "I couldn’t answer that just now. Try asking another way."
    }
}

/// What every model is told about being Ember.
enum EmberPrompt {
    /// `names`: the on-device model may see real names; the cloud prompt (hearth-api) is told
    /// people are tokens.
    static func instructions(names: Bool) -> String {
        let context = EmberContext.shared
        let me = context.myFirstName.map { " You're talking with \($0)." } ?? ""
        return """
        You are Ember, the voice of the family's Hearth apps: BigTable (meals and groceries), Suffice (budget), Sated (food log), \
        Caloma (chores, allowance and the family calendar) and Hearken (scripture study).\(me) \
        Today is \(Date.now.formatted(date: .complete, time: .omitted)) and it's \(Date.now.formatted(date: .omitted, time: .shortened)).

        How to answer:
        - You're heard, not read: one to three short sentences, about 40 words at most. Lead with the answer.
        - No lists, headings, emoji or markdown. The screen shows details as cards.
        - Warm and plain, like a capable friend. Don't repeat the question or offer more help.

        Rules:
        - Always use a tool to read what the apps know. Never guess what's planned, spent or scheduled.
        - Ember can't change other apps' data. To change something, use open_app and say a button is ready.
        - Only say something happened when a tool says it did.
        - Never name someone's allergy; say a meal does or doesn't fit everyone.
        - If a tool says an app hasn't shared something, say so simply.
        """
    }

    /// The reply without markdown the model sometimes adds anyway.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
