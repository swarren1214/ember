import Foundation

// Standalone turns: the Watch asks Claude through hearth-api itself (Wi-Fi or cellular, no
// iPhone). Same privacy rules as the iPhone: the redactor runs here before anything is sent,
// hearth-api checks again, and the only Hearth data available is the day's facts the iPhone
// last shared, offered as one tool so Claude asks for them only when it needs them.

@MainActor
final class WatchBrain {
    static let shared = WatchBrain()

    private var redactor: EmberRedactor?
    private var history: [EmberCloudMessage] = []

    func ask(_ question: String, context: EmberWatchContext?) async -> EmberWatchReply {
        let id = UUID()
        guard let context, context.allowsClaude else {
            return EmberWatchReply(id: id, text: "Ember needs your iPhone nearby for that. To ask from your Watch alone, turn on Cloud Help with Claude on your iPhone.", actions: [], tier: .none)
        }
        guard await WatchAccount.shared.isSignedIn else {
            return EmberWatchReply(id: id, text: "Sign in on your Watch once to ask without your iPhone. Open Ember on your Watch and tap Sign In.", actions: [], tier: .none)
        }

        var redactor = self.redactor ?? EmberRedactor(household: context.people.map { EmberPerson(name: $0.name, role: $0.role, age: $0.age) })
        defer { self.redactor = redactor }
        var messages = Array(history.suffix(8))
        messages.append(EmberCloudMessage(role: "user", content: [.text(redactor.redact(question))]))
        var answer = ""
        var actions: [EmberWatchAction] = []

        do {
            for _ in 0..<3 {
                let request = EmberCloudRequest(
                    profile: "quick",
                    client: "watch",
                    locale: Locale.current.identifier,
                    timeZone: TimeZone.current.identifier,
                    now: Date.now.formatted(date: .complete, time: .shortened),
                    roster: redactor.roster,
                    messages: messages,
                    tools: ["household_facts", "place_call"],
                    allowWebSearch: false
                )
                let outgoing = messages.flatMap(\.content).compactMap { $0.text ?? $0.content }.joined(separator: "\n")
                guard EmberRedactor.leaks(in: outgoing).isEmpty else { throw EmberCloudError.refused }

                let token = try await WatchAccount.shared.accessToken()
                var text = ""
                var toolUses: [(String, String, [String: EmberJSON])] = []
                for try await event in EmberCloudClient(baseURL: EmberEndpoints.apiBaseURL).turn(request, accessToken: token) {
                    switch event {
                    case .text(let delta): text += delta
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
                    let output: String
                    switch name {
                    case "household_facts":
                        output = context.facts.isEmpty ? "No facts shared yet." : "As of \(context.updatedAt.formatted(date: .abbreviated, time: .shortened)):\n" + context.facts.joined(separator: "\n")
                    case "place_call":
                        let who = redactor.restore(input["who"]?.string ?? "")
                        let near = redactor.restore(input["near"]?.string ?? "")
                        output = await call(who: who, near: near, actions: &actions)
                    default:
                        output = "That tool isn't available on the Watch."
                    }
                    results.append(.toolResult(id: useID, content: redactor.redact(output)))
                }
                messages.append(EmberCloudMessage(role: "assistant", content: blocks))
                messages.append(EmberCloudMessage(role: "user", content: results))
            }
            let restored = redactor.restore(answer).trimmingCharacters(in: .whitespacesAndNewlines)
            history.append(EmberCloudMessage(role: "user", content: [.text(redactor.redact(question))]))
            history.append(EmberCloudMessage(role: "assistant", content: [.text(answer)]))
            return EmberWatchReply(id: id, text: restored.isEmpty ? "Done." : restored, actions: Array(actions.prefix(2)), tier: .claude)
        } catch WatchAccount.AccountError.signedOut {
            return EmberWatchReply(id: id, text: "Your Watch’s sign-in expired. Open Ember on your Watch and sign in again.", actions: [], tier: .none)
        } catch {
            let message = (error as? EmberCloudError)?.errorDescription ?? EmberCloudError.offline.errorDescription!
            return EmberWatchReply(id: id, text: message, actions: [], tier: .none)
        }
    }

    /// Finds the number on the Watch; the reply gets a Call button that opens the Watch's phone.
    private func call(who: String, near: String, actions: inout [EmberWatchAction]) async -> String {
        switch await EmberCallFinder.find(who, near: near) {
        case .success(let target):
            if let url = target.url { actions.append(EmberWatchAction(title: "Call", url: url.absoluteString)) }
            return "Found \(target.name). A Call button is on the Watch; they tap it to dial. Say it's ready in a few words. Don't say a number."
        case .failure(.needsLocation):
            return "Ember needs Location on the Watch to find \(who) nearby. Ask them to say the town."
        case .failure(.nothingFound):
            return "No phone number for \(who) in Contacts or Apple Maps."
        }
    }
}
