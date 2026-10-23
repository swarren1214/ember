import Foundation
import FoundationModels
import Observation
import OSLog

// One turn of conversation, routed to the best resource available, with the privacy rules
// applied on the way out:
//
//   1. EmberRouter picks the areas the question is about (and whether it's complex), so only
//      their tools are offered.
//   2. Apple's on-device model, with those tools. Nothing leaves the device.
//   3. Claude through hearth-api, when the person allowed it (Cloud Help) and the turn needs it:
//      complex questions, no on-device model, or the on-device model couldn't answer.
//      Everything sent is de-identified by EmberRedactor; tools still run here.
//
// The tier is chosen here, in code, never by a model. Ember is for parents and adults.

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
    /// Ember asked "which one?" or "should I?": listen for the answer.
    var asksBack = false
    var askedAt = Date.now
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

    /// Loads the on-device model and fetches the family's data ahead of the first question.
    func prewarm() {
        EmberData.shared.prefetch()
        guard Self.onDeviceAvailable else { return }
        LanguageModelSession(instructions: EmberPrompt.instructions(recent: [])).prewarm()
    }

    /// Clear: a new conversation (new tokens, empty history).
    func reset() {
        turns = []
        redactor = nil
        cloudHistory = []
        session = nil
        lastDomains = nil
        context = []
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
        EmberTrace.shared.begin(text)

        // Earlier turns go to the model only when this one builds on them. Otherwise the small
        // on-device model latches onto the last question and answers it again.
        let followsUp = Self.isFollowUp(text, after: turns.last)
        if !followsUp { cloudHistory = []; redactor = nil }
        context = followsUp ? Array(turns.suffix(2)) : []
        EmberTrace.shared.note(followsUp ? "follow-up" : "new question")

        var decision = await EmberRouter.decide(text, onDevice: Self.onDeviceAvailable)
        // A follow-up stays on the last question's topic ("and last month?" has no topic words).
        if followsUp, let lastDomains {
            decision.domains.formUnion(lastDomains)
            decision.domains.remove(.general)
            if decision.domains.isEmpty { decision.domains = lastDomains }
        }
        lastDomains = decision.domains
        let tools = toolbox.tools(for: decision.domains, question: text)
        self.followsUp = followsUp
        let route = Route.choose(complex: decision.isComplex, client: client)
        EmberTrace.shared.note("domains \(decision.domains.map(\.rawValue).sorted().joined(separator: ",")), \(tools.count) tools, \(route)")
        var turn = EmberTurn(question: text, answer: "")

        switch route {
        case .onDevice(let fallbackToCloud):
            do {
                let answer = try await respondOnDevice(text, tools: tools)
                turn.answer = answer
                turn.tier = .onDevice
                Self.sentences(in: answer).forEach(onSentence)
            } catch {
                log.notice("On-device turn failed: \(String(describing: error), privacy: .public)")
                EmberTrace.shared.note("on-device failed: \(error)")
                if fallbackToCloud {
                    turn = await respondInCloud(text, client: client, tools: toolbox.allowedTools, onSentence: onSentence)
                } else {
                    turn.answer = Self.message(for: error)
                    turn.isNotice = true
                    onSentence(turn.answer)
                }
            }
        case .cloud:
            turn = await respondInCloud(text, client: client, tools: tools, onSentence: onSentence)
        case .unavailable(let reason):
            turn.answer = reason
            turn.isNotice = true
            onSentence(reason)
        }

        if turn.cards.isEmpty { turn.cards = toolbox.takeCards() }
        if turn.sources.isEmpty { turn.sources = toolbox.usedApps }
        turn.asksBack = toolbox.asksToChoose || EmberActions.shared.hasWaiting
        turns.append(turn)
        EmberTrace.shared.end(turn)
        return turn
    }

    // MARK: Routing

    enum Route: Equatable, CustomStringConvertible {
        /// `fallbackToCloud`: escalate if the on-device model can't answer.
        case onDevice(fallbackToCloud: Bool)
        case cloud
        case unavailable(String)

        var description: String {
            switch self {
            case .onDevice(let fallback): fallback ? "on device, cloud fallback" : "on device"
            case .cloud: "cloud"
            case .unavailable: "unavailable"
            }
        }

        static func choose(complex: Bool, client: EmberClient) -> Route {
            let claude = EmberSettings.shared.cloudHelp?.allowsClaude == true
            if onDeviceAvailable {
                // Complex questions are where the bigger model earns its keep.
                if claude && complex { return .cloud }
                return .onDevice(fallbackToCloud: claude)
            }
            if claude { return .cloud }
            return .unavailable("Ember needs Apple Intelligence on this \(DeviceName.current), or Cloud Help turned on in What Ember Knows.")
        }
    }

    /// A cheap read of whether a question plans across apps or days.
    static func isPlanning(_ question: String) -> Bool {
        let text = question.lowercased()
        let planWords = ["plan ", "plan.", "next week", "weekend", "afford", "budget for", "organize", "figure out", "should we",
                         "compare", "versus", "vs ", "on track", "trend", "why ", "how can we", "help me", "suggest"]
        return planWords.contains { text.contains($0) }
    }

    /// General knowledge with nothing about the household: the only turns Claude may search the
    /// web for.
    static func isGeneralKnowledge(_ question: String) -> Bool {
        let text = question.lowercased()
        let household = ["we ", "our ", "my ", " me ", "us ", "tonight", "today", "tomorrow", "kids", "budget", "plan"]
        let general = ["how long", "how do i", "how do you", "what is", "what's the difference", "substitute", "temperature", "how much", "who is", "when is", "when does"]
        return general.contains { text.hasPrefix($0) || text.contains(" " + $0) } && !household.contains { text.contains($0) }
    }

    // MARK: On device

    /// The exchanges this question builds on (empty for a new question).
    @ObservationIgnored private var context: [EmberTurn] = []
    @ObservationIgnored private var lastDomains: Set<EmberDomain>?
    @ObservationIgnored private var followsUp = false
    /// The on-device conversation, kept across follow-ups on the same topic so the model has
    /// the real exchange (its tool calls and answers), as Ask Suffice does. A new question starts
    /// a new one.
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var sessionTools: [String] = []

    private var recent: [(String, String)] {
        context.map { ($0.question, $0.answer) }
    }

    /// Whether a question continues the last exchange ("and last month?", "text her that",
    /// "the one on Main", "yes"), rather than starting something new. Only within a couple of
    /// minutes of the last answer; after Ember asked something back, the reply always counts.
    static func isFollowUp(_ question: String, after last: EmberTurn?, now: Date = .now) -> Bool {
        guard let last, now.timeIntervalSince(last.askedAt) < 150 else { return false }
        if last.asksBack { return true }
        let words = EmberConversation.words(question)
        guard let first = words.first else { return false }
        let openers: Set<String> = ["and", "also", "but", "or", "then", "so", "ok", "okay", "yes", "yeah", "no", "nope", "sure"]
        let leadIns = ["what about", "how about", "and ", "also ", "same for", "what else", "how much was", "which one", "the one", "that one", "do it", "go ahead", "send it", "text her", "text him", "call her", "call him", "tell her", "tell him"]
        let pointers: Set<String> = ["her", "him", "them", "that", "those", "there", "instead", "too", "else", "again", "same"]
        let lower = question.lowercased()
        if leadIns.contains(where: { lower.hasPrefix($0) }) { return true }
        // Short, and pointing back at something ("and last month?", "how about Ella").
        if words.count <= 5, openers.contains(first) || words.contains(where: pointers.contains) { return true }
        return false
    }

    private func respondOnDevice(_ question: String, tools specs: [EmberToolSpec]) async throws -> String {
        let names = specs.map(\.name)
        let session: LanguageModelSession
        if followsUp, let current = self.session, sessionTools == names, !current.isResponding {
            session = current
        } else {
            let tools: [any Tool] = specs.compactMap { spec in
                do { return try spec.deviceTool() } catch {
                    log.error("Tool \(spec.name, privacy: .public) has a bad schema: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            // A follow-up whose topic changed: the earlier exchange goes in the instructions.
            session = LanguageModelSession(tools: tools, instructions: EmberPrompt.instructions(recent: followsUp ? recent : []))
            self.session = session
            sessionTools = names
        }
        do {
            let reply = try await session.respond(to: question, options: GenerationOptions(temperature: 0.2)).content
            return EmberPrompt.clean(reply)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                // The conversation filled the model's context: start fresh and ask again.
                self.session = nil
                let tools: [any Tool] = specs.compactMap { try? $0.deviceTool() }
                let fresh = LanguageModelSession(tools: tools, instructions: EmberPrompt.instructions(recent: []))
                self.session = fresh
                return EmberPrompt.clean(try await fresh.respond(to: question).content)
            }
            throw error
        }
    }

    // MARK: Claude via hearth-api

    private func respondInCloud(_ question: String, client: EmberClient, tools specs: [EmberToolSpec], retried: Bool = false,
                                onSentence: @escaping (String) -> Void) async -> EmberTurn {
        var turn = EmberTurn(question: question, answer: "", tier: .claude)
        var redactor = self.redactor ?? EmberRedactor(household: EmberContext.shared.redactionPeople)
        defer { self.redactor = redactor }

        var messages = Array(cloudHistory.suffix(12))
        messages.append(EmberCloudMessage(role: "user", content: [.text(redactor.redact(question))]))
        var sentLog: [String] = []
        var splitter = EmberSentenceSplitter()
        var answer = ""
        let names = specs.map(\.name)
        let definitions = specs.map(\.cloudDefinition)

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
                    tools: names,
                    toolDefs: definitions,
                    allowWebSearch: Self.isGeneralKnowledge(question)
                )
                // Belt and braces: nothing that still looks like an identifier is sent.
                let outgoing = Self.text(of: messages)
                guard EmberRedactor.leaks(in: outgoing).isEmpty else { throw EmberCloudError.refused }
                if let json = EmberWire.encode(EmberCloudRequestLog(request)), let pretty = String(data: json, encoding: .utf8) { sentLog.append(pretty) }

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
                    EmberTrace.shared.note("cloud tool \(use.name)")
                    let output = await toolbox.run(use.name, input: Self.restored(use.input, with: redactor), offered: names)
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
            return await respondInCloud(question, client: client, tools: specs, retried: true, onSentence: onSentence)
        } catch {
            log.error("Cloud turn failed: \(String(describing: error), privacy: .public)")
            EmberTrace.shared.note("cloud failed: \(error)")
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

/// What "What was sent" shows: the request without the tool definitions (the same every time).
private struct EmberCloudRequestLog: Encodable {
    var profile: String
    var roster: [EmberRosterEntry]
    var messages: [EmberCloudMessage]
    var tools: [String]

    init(_ request: EmberCloudRequest) {
        profile = request.profile
        roster = request.roster
        messages = request.messages
        tools = request.tools
    }
}

/// What every model is told about being Ember.
enum EmberPrompt {
    static func instructions(recent: [(String, String)]) -> String {
        let context = EmberContext.shared
        let me = context.myFirstName.map { " You're talking with \($0)." } ?? ""
        let city = EmberPlace.city.map { " They're in or near \($0)." } ?? ""
        var text = """
        You are Ember, the family's assistant. You know their Hearth apps: BigTable (meals and groceries), Suffice (budget and \
        bills), Sated (food log), Caloma (chores, allowance and the family calendar) and Hearken (scripture study), and you can \
        call, text, email, set reminders, timers and alarms, and add calendar events for them.\(me)\(city) \
        Today is \(Date.now.formatted(date: .complete, time: .omitted)) and it's \(Date.now.formatted(date: .omitted, time: .shortened)).

        How to answer:
        - You're heard, not read: one to three short sentences, about 40 words at most. Lead with the answer, usually a number.
        - Then one useful line at most: the comparison, what's left, or what's next.
        - No lists, headings, emoji or markdown. The screen shows details as cards.
        - Say money rounded unless cents matter, days as "Thursday" or "tomorrow", and the range you used ("this week, Sunday to today").
        - Warm and plain, like a capable friend. Don't repeat the question or offer more help.

        Rules:
        - Always use a tool to read what the apps know. Never guess what's planned, spent or scheduled.
        - Use the tool that does the thing. To change something, call the tool for it; open_app only when no tool does it.
        - Some tools wait for the person to confirm. Then ask, in a few words, whether to go ahead. Never say it's done.
        - Only say something happened when a tool says it did.
        - When something is ambiguous (two people, two places), ask one short question. Otherwise pick the sensible default and say it.
        - Never name someone's allergy; say a meal does or doesn't fit everyone.
        - If a tool says an app hasn't shared something, say why simply and what fixes it.
        - Never read out phone numbers, addresses or email addresses.
        - Use only the tools that fit the request. Never bring up an app or offer to open one that the request isn't about.
        - If no tool fits, answer from what you know in a sentence or two, or say plainly that you can't do that yet. Don't offer something else instead.
        - For places, say only what the tool found. You don't know ratings or reviews.
        """
        let remembered = EmberSettings.shared.remembered
        if !remembered.isEmpty {
            text += "\n\nWhat they've asked you to remember:\n" + remembered.map { "- \($0)" }.joined(separator: "\n")
        }
        if !recent.isEmpty {
            text += "\n\nThis question follows on from what was just said. Use it only to understand words like \"her\", \"that\" or \"last month\"; answer only the new question, and call tools again for anything it asks:\n"
            text += recent.map { "They asked: \($0.0)\nYou said: \($0.1)" }.joined(separator: "\n")
        }
        return text
    }

    /// The reply without markdown the model sometimes adds anyway.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
