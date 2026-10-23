import CloudKit
import Foundation

// Standalone turns: the Watch answers through hearth-api itself (Wi-Fi or cellular, no iPhone),
// with the same pipeline as the iPhone (Ember Assistant Architecture):
//
//   1. Understand: Claude fills in the typed request (/v1/ember/understand) from the
//      de-identified question; copied words are checked against the question here.
//   2. Money (spending, purchases, budgets, bills), calls and adding groceries are then resolved,
//      queried and answered in plain code: the same EmberMoneyPipeline and HearthMoney as the
//      iPhone and Suffice, the same call finder, so the Watch says exactly what the iPhone says.
//   3. Anything else (chores, the calendar, the grocery list, the day's facts) is still a Claude
//      turn, offered only the tools for the request's intent.
//
// Same privacy rules as the iPhone: the redactor runs here before anything is sent, hearth-api
// checks again, and the device does the sensitive work.
//
// The Watch reads the family's data on its own, from the same iCloud zones the iPhone reads
// (Suffice's budget, Caloma's family, BigTable's kitchen), with the same answers (EmberSkills),
// so spending, chores, the calendar and the grocery list work away from the iPhone. Meals and
// the day's other facts come from what the iPhone last shared.

@MainActor
final class WatchBrain {
    static let shared = WatchBrain()

    private var redactor: EmberRedactor?
    private var history: [EmberCloudMessage] = []
    /// The last question and its request, for follow-ups ("what about last week?").
    private var last: (question: String, request: EmberRequest, at: Date)?
    private let budget = EmberZone(zoneName: SufficeLedger.zoneName)
    private let family = EmberZone(zoneName: CalomaFamily.zoneName)
    private let kitchen = EmberZone(zoneName: BigTableGroceries.zoneName)

    /// Whether the Watch can answer by itself: Cloud Help with Claude is on and it's signed in.
    func canAnswer(context: EmberWatchContext?) async -> Bool {
        guard let context, context.allowsClaude else { return false }
        return await WatchAccount.shared.isSignedIn
    }

    /// Answers on the Watch, calling `onSentence` with each sentence as it's written (for the
    /// voice). `answered` is false when it couldn't (offline, signed out, Cloud Help off), so the
    /// iPhone can be asked instead.
    func ask(_ question: String, context: EmberWatchContext?, onSentence: @escaping (String) -> Void = { _ in }) async -> (reply: EmberWatchReply, answered: Bool) {
        let id = UUID()
        guard let context, context.allowsClaude else {
            return (EmberWatchReply(id: id, text: "Ember needs your iPhone nearby for that. To ask from your Watch alone, turn on Cloud Help with Claude on your iPhone.", actions: [], tier: .none), false)
        }
        guard await WatchAccount.shared.isSignedIn else {
            return (EmberWatchReply(id: id, text: "Sign in on your Watch once to ask without your iPhone. Open Ember on your Watch and tap Sign In.", actions: [], tier: .none), false)
        }
        for zone in [budget, family, kitchen] { zone.setHouseholdOwner(context.householdOwner) }

        var redactor = self.redactor ?? EmberRedactor(household: context.people.map { EmberPerson(name: $0.name, role: $0.role, age: $0.age) })
        defer { self.redactor = redactor }
        // 1. Understand.
        let request = await understand(question, redactor: &redactor)
        if let request { last = (question, request, .now) } else { last = nil }

        // 2. Money, calls and adding groceries: answered in plain code.
        if let request, let reply = await solve(request, question: question, context: context) {
            var sentences = EmberSentenceSplitter()
            for sentence in sentences.feed(reply.text) { onSentence(sentence) }
            if let rest = sentences.flush() { onSentence(rest) }
            history = []
            return (EmberWatchReply(id: id, text: reply.text, actions: reply.actions, tier: .claude), true)
        }

        // 3. The rest: a Claude turn with the tools for the request's intent.
        var messages = Array(history.suffix(8))
        messages.append(EmberCloudMessage(role: "user", content: [.text(redactor.redact(question))]))
        var answer = ""
        var splitter = EmberSentenceSplitter()
        var actions: [EmberWatchAction] = []
        let tools = request.map { Self.tools(for: $0.intent) } ?? Self.tools

        do {
            for _ in 0..<4 {
                let request = EmberCloudRequest(
                    profile: "quick",
                    client: "watch",
                    locale: Locale.current.identifier,
                    timeZone: TimeZone.current.identifier,
                    now: Date.now.formatted(date: .complete, time: .shortened),
                    roster: redactor.roster,
                    messages: messages,
                    tools: tools.map(\.name),
                    toolDefs: tools.map(\.definition),
                    allowWebSearch: false
                )
                let outgoing = messages.flatMap(\.content).compactMap { $0.text ?? $0.content }.joined(separator: "\n")
                guard EmberRedactor.leaks(in: outgoing).isEmpty else { throw EmberCloudError.refused }

                let token = try await WatchAccount.shared.accessToken()
                var text = ""
                var toolUses: [(String, String, [String: EmberJSON])] = []
                for try await event in EmberCloudClient(baseURL: EmberEndpoints.apiBaseURL).turn(request, accessToken: token) {
                    switch event {
                    case .text(let delta):
                        text += delta
                        for sentence in splitter.feed(delta) { onSentence(redactor.restore(sentence).replacingOccurrences(of: "**", with: "")) }
                    case .toolUse(let useID, let name, let input): toolUses.append((useID, name, input))
                    case .done: break
                    }
                }
                answer += text
                guard !toolUses.isEmpty else { break }
                var blocks: [EmberCloudBlock] = text.isEmpty ? [] : [.text(text)]
                var results: [EmberCloudBlock] = []
                for (useID, name, input) in toolUses {
                    blocks.append(.toolUse(id: useID, name: name, input: input))
                    let args = input.mapValues { value -> String in redactor.restore(value.string ?? "") }
                    let output = await run(name, args: args, context: context, actions: &actions)
                    results.append(.toolResult(id: useID, content: redactor.redact(output)))
                }
                messages.append(EmberCloudMessage(role: "assistant", content: blocks))
                messages.append(EmberCloudMessage(role: "user", content: results))
            }
            if let rest = splitter.flush() { onSentence(redactor.restore(rest).replacingOccurrences(of: "**", with: "")) }
            let restored = redactor.restore(answer).trimmingCharacters(in: .whitespacesAndNewlines)
            history.append(EmberCloudMessage(role: "user", content: [.text(redactor.redact(question))]))
            history.append(EmberCloudMessage(role: "assistant", content: [.text(answer)]))
            return (EmberWatchReply(id: id, text: restored.isEmpty ? "Done." : restored, actions: Array(actions.prefix(2)), tier: .claude), true)
        } catch WatchAccount.AccountError.signedOut {
            return (EmberWatchReply(id: id, text: "Your Watch’s sign-in expired. Open Ember on your Watch and sign in again.", actions: [], tier: .none), false)
        } catch {
            let message = (error as? EmberCloudError)?.errorDescription ?? EmberCloudError.offline.errorDescription!
            return (EmberWatchReply(id: id, text: message, actions: [], tier: .none), false)
        }
    }

    // MARK: The pipeline

    /// The request, from Claude (de-identified), checked against the question and merged onto
    /// the last one for a follow-up. Nil when the cloud can't be reached.
    private func understand(_ question: String, redactor: inout EmberRedactor) async -> EmberRequest? {
        guard let token = try? await WatchAccount.shared.accessToken() else { return nil }
        let recent = last.flatMap { Date.now.timeIntervalSince($0.at) < 150 ? $0 : nil }
        let redacted = redactor.redact(question)
        let earlier = recent.map { (question: redactor.redact($0.question), intent: $0.request.intent) }
        guard let raw = try? await EmberCloudClient(baseURL: EmberEndpoints.apiBaseURL)
            .understand(redacted, previous: earlier, accessToken: token, timeout: 4) else { return nil }
        var request = raw.restored(with: redactor).checked(against: question)
        if request.isFollowUp, let recent { request = request.merged(onto: recent.request) }
        return request
    }

    private struct PipelineReply {
        var text: String
        var actions: [EmberWatchAction] = []
    }

    /// The answer worked out in code, or nil for intents that still need a Claude turn.
    private func solve(_ request: EmberRequest, question: String, context: EmberWatchContext) async -> PipelineReply? {
        if !request.clarify.isEmpty, request.intent == .unsupported { return PipelineReply(text: request.clarify) }
        if EmberMoneyPipeline.handles(request.intent) {
            await budget.refresh()
            let ledger = await budget.snapshot(SufficeLedger.init(records:))
            guard !ledger.isEmpty else {
                return PipelineReply(text: budget.lastError?.errorDescription ?? "Suffice’s budget isn’t in iCloud yet. Open Suffice on your iPhone once.")
            }
            return PipelineReply(text: EmberMoneyPipeline.answer(request, question: question, ledger: ledger).text)
        }
        switch request.intent {
        case .call:
            let who = request.who.isEmpty ? request.placeWords : request.who
            guard !who.isEmpty else { return PipelineReply(text: "Who should I call?") }
            return await callReply(who: who, near: request.townWords)
        case .addGroceries where !request.items.isEmpty:
            await kitchen.refresh()
            let list = BigTableGroceries(records: Array(kitchen.records.values))
            let items = request.items.map { (name: $0.trimmingCharacters(in: .whitespaces), quantity: "") }.filter { !$0.name.isEmpty }
            guard !items.isEmpty, let record = BigTableGroceries.adding(items, in: kitchen, activeRecordName: list.activeRecordName) else {
                return PipelineReply(text: "There’s no grocery list to add to yet. Make one in BigTable.")
            }
            do {
                try await kitchen.save([record])
                return PipelineReply(text: "Added \(items.map(\.name).formatted(.list(type: .and))) to the grocery list.")
            } catch {
                return PipelineReply(text: "I couldn’t add them just now. Try again in a moment.")
            }
        default:
            return nil
        }
    }

    /// A call, as the iPhone words it: "Calling Mom." with a Call button, or which one.
    private func callReply(who: String, near: String) async -> PipelineReply {
        switch await EmberCallFinder.find(who, near: near) {
        case .success(.one(let target)):
            let name = EmberContactSearch.isRelation(who) ? who.trimmingCharacters(in: .whitespaces).capitalizedFirst : target.name
            let actions = target.url.map { [EmberWatchAction(title: "Call \(target.name)", url: $0.absoluteString)] } ?? []
            return PipelineReply(text: "Calling \(name). Tap Call.", actions: actions)
        case .success(.several(let targets)):
            let two = Array(targets.prefix(2))
            let actions = two.compactMap { target in
                target.url.map { EmberWatchAction(title: "Call \(target.street ?? target.place ?? target.name)", url: $0.absoluteString) }
            }
            let names = two.map { $0.street ?? $0.place ?? $0.name }
            return PipelineReply(text: "There’s more than one \(who). The one on \(names.joined(separator: ", or the one on "))?", actions: actions)
        case .failure(.needsLocation):
            return PipelineReply(text: "I need Location on your Watch to find \(who) nearby, or say the town.")
        case .failure(.needsContacts):
            return PipelineReply(text: "I need Contacts access on your Watch to call \(who).")
        case .failure(.notInContacts):
            return PipelineReply(text: "I couldn’t find \(who) in your contacts.")
        case .failure(.nothingFound):
            return PipelineReply(text: "I couldn’t find a number for \(who).")
        }
    }

    // MARK: Tools

    /// The Claude turn's tools for an intent the code doesn't answer yet.
    static func tools(for intent: EmberIntent) -> [WatchTool] {
        let names: Set<String> = switch intent {
        case .calendar, .addEvent: ["family_calendar", "household_facts"]
        case .chores: ["chores", "household_facts"]
        case .groceries, .addGroceries, .mealPlan: ["grocery_list", "add_groceries", "household_facts"]
        case .call: ["place_call"]
        case .spending, .transactions, .budgetStatus, .bills, .logPurchase: ["spending", "budgets", "bills"]
        default: ["household_facts"]
        }
        return tools.filter { names.contains($0.name) }
    }

    struct WatchTool {
        var name: String
        var definition: EmberJSON
    }

    private static func tool(_ name: String, _ description: String, _ params: [(String, String, Bool)] = []) -> WatchTool {
        var properties: [String: EmberJSON] = [:]
        for (key, text, _) in params {
            properties[key] = .object(["type": .string(key == "minutes" || key == "amount" ? "number" : "string"), "description": .string(text)])
        }
        return WatchTool(name: name, definition: .object([
            "name": .string(name),
            "description": .string(description),
            "input_schema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(params.filter { $0.2 }.map { .string($0.0) }),
            ]),
        ]))
    }

    static let tools: [WatchTool] = [
        tool("household_facts", "The day's meals, grocery and budget figures and reading, as the iPhone last shared them."),
        tool("spending", "How much was spent in a period, overall, in one budget, at one place or by one person, with the period before.",
             [("range", "When, like \"this week\" or \"last month\". Default this week.", false), ("budget", "A budget, or empty.", false),
              ("place", "A store, or empty.", false), ("person", "Whose, or empty.", false)]),
        tool("budgets", "How the month's budgets stand: left, spent and planned.", [("budget", "One budget, or empty for all.", false)]),
        tool("bills", "Bills coming due and late ones.", [("range", "When. Default the next 14 days.", false)]),
        tool("chores", "Who has which chores on a day and which are done.", [("day", "Which day. Default today.", false), ("person", "One person, or empty.", false)]),
        tool("family_calendar", "What's on the family calendar.", [("range", "When. Default today.", false), ("person", "One person, or empty.", false)]),
        tool("grocery_list", "What's on the grocery list, or whether one item is.", [("item", "One item, or empty.", false)]),
        tool("add_groceries", "Adds items to the grocery list right away.", [("items", "The items, comma separated.", true)]),
        tool("place_call", "Calls a person or business; the Watch shows a Call button. Several matches: ask which.",
             [("who", "Who to call.", true), ("near", "Only a town they said for a business; empty for people.", false), ("which", "Their answer to which one, or empty.", false)]),
    ]

    private func run(_ name: String, args: [String: String], context: EmberWatchContext, actions: inout [EmberWatchAction]) async -> String {
        let arg = { (key: String) in args[key] ?? "" }
        switch name {
        case "household_facts":
            return context.facts.isEmpty ? "No facts shared yet." : "As of \(context.updatedAt.formatted(date: .abbreviated, time: .shortened)):\n" + context.facts.joined(separator: "\n")
        case "spending", "budgets", "bills":
            await budget.refresh()
            let ledger = await budget.snapshot(SufficeLedger.init(records:))
            guard !ledger.isEmpty else { return budget.lastError?.errorDescription ?? "Suffice's budget isn't in iCloud yet." }
            switch name {
            case "spending": return EmberSkills.spending(ledger, range: arg("range"), budget: arg("budget"), place: arg("place"), person: arg("person")).facts
            case "budgets": return EmberSkills.budgets(ledger, budget: arg("budget"), month: "").facts
            default: return EmberSkills.bills(ledger, range: arg("range")).facts
            }
        case "chores", "family_calendar":
            await family.refresh()
            let board = await family.snapshot(CalomaFamily.init(records:))
            guard !board.isEmpty else { return family.lastError?.errorDescription ?? "Caloma's family isn't in iCloud yet." }
            return name == "chores"
                ? EmberSkills.chores(board, day: arg("day"), person: arg("person")).facts
                : EmberSkills.calendar(board, range: arg("range"), person: arg("person")).facts
        case "grocery_list":
            await kitchen.refresh()
            return EmberSkills.groceries(BigTableGroceries(records: Array(kitchen.records.values)), item: arg("item")).facts
        case "add_groceries":
            await kitchen.refresh()
            let list = BigTableGroceries(records: Array(kitchen.records.values))
            let items = arg("items").split(separator: ",").map { (name: $0.trimmingCharacters(in: .whitespaces), quantity: "") }.filter { !$0.name.isEmpty }
            guard !items.isEmpty, let record = BigTableGroceries.adding(items, in: kitchen, activeRecordName: list.activeRecordName) else {
                return "There's no grocery list to add to."
            }
            do {
                try await kitchen.save([record])
                return "Added \(items.map(\.name).formatted(.list(type: .and))) to the grocery list."
            } catch {
                return "Couldn't add them: \(error.localizedDescription)"
            }
        case "place_call":
            return await call(who: arg("who"), near: arg("near"), which: arg("which"), actions: &actions)
        default:
            return "That tool isn't available on the Watch."
        }
    }

    /// Finds the number on the Watch; the reply gets a Call button that opens the Watch's phone.
    private func call(who: String, near: String, which: String, actions: inout [EmberWatchAction]) async -> String {
        switch await EmberCallFinder.find(who, near: near, which: which) {
        case .success(.one(let target)):
            if let url = target.url { actions.append(EmberWatchAction(title: "Call \(target.name)", url: url.absoluteString)) }
            return "Found \(target.spoken). A Call button is on the Watch. Reply with exactly this and nothing else: \"Ready to call \(target.name). Tap Call.\""
        case .success(.several(let targets)):
            actions = []
            for target in targets.prefix(2) {
                if let url = target.url { actions.append(EmberWatchAction(title: "Call \(target.street ?? target.place ?? target.name)", url: url.absoluteString)) }
            }
            let list = targets.enumerated().map { "\($0.offset + 1). \($0.element.spoken)" }.joined(separator: "\n")
            return "There are \(targets.count) matches, closest first:\n\(list)\nThe two closest have Call buttons on the Watch. Ask which one in one short question, naming each by its street."
        case .failure(.needsLocation):
            return "Ember needs Location on the Watch to find \(who) nearby. Ask them to say the town."
        case .failure(.needsContacts):
            return "Ember isn't allowed to see Contacts on the Watch. Reply in one short sentence that you need Contacts access to call \(who)."
        case .failure(.notInContacts):
            return "Nobody in Contacts is \(who). Reply in one short sentence that you couldn't find \(who) in Contacts."
        case .failure(.nothingFound):
            return "No phone number for \(who) in Contacts or Apple Maps."
        }
    }
}
