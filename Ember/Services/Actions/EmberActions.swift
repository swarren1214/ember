import Foundation
import Observation

// How Ember changes things (implementation plan › Actions). Every action is one of:
//
// - Do it, offer undo: easy to reverse and only affects you (add groceries, a reminder, a
//   timer). Done at once; the card has Undo, and "undo that" works for two minutes.
// - Confirm first: money, other people, or hard to reverse (log spending, approve chores, a
//   family event). The card shows exactly what will change; "yes" or the Confirm button does it,
//   "no" drops it. Nothing changes until then.
// - Ready for you to send: calls, texts, emails open the system screen filled in (EmberCompose).
//
// An action is only "done" once the write came back from iCloud (or EventKit, AlarmKit); a
// failure says what went wrong. Nothing here asks a model whether something happened.

@Observable
final class EmberActions {
    static let shared = EmberActions()

    enum State: Equatable {
        /// Waiting for "yes" or the Confirm button.
        case waiting
        case working
        case done(String)
        case undone
        case cancelled
        case failed(String)
    }

    struct Undo {
        var title: String
        var perform: () async throws -> Void
        var at: Date = .now
    }

    /// What an action does when it runs: the sentence to say, and how to take it back (or nil).
    typealias Work = () async throws -> (spoken: String, undo: Undo?)

    private(set) var states: [UUID: State] = [:]
    private(set) var titles: [UUID: String] = [:]
    @ObservationIgnored private var proposals: [UUID: Work] = [:]
    @ObservationIgnored private var undos: [UUID: Undo] = [:]
    /// The newest proposal still waiting, which "yes" answers.
    private(set) var waitingID: UUID?
    /// The newest action that can be undone.
    private(set) var lastUndoable: UUID?

    // MARK: Confirm first

    /// Holds an action until it's confirmed. Returns its id (for the card).
    func propose(_ title: String, work: @escaping Work) -> UUID {
        let id = UUID()
        // One question at a time: a new proposal replaces an unanswered one.
        if let waitingID, states[waitingID] == .waiting { states[waitingID] = .cancelled; proposals[waitingID] = nil }
        proposals[id] = work
        titles[id] = title
        states[id] = .waiting
        waitingID = id
        return id
    }

    /// Runs a waiting action. Returns what to say.
    @discardableResult
    func confirm(_ id: UUID? = nil) async -> String {
        guard let id = id ?? waitingID, states[id] == .waiting, let work = proposals[id] else {
            return "There's nothing waiting to confirm."
        }
        proposals[id] = nil
        if waitingID == id { waitingID = nil }
        return await run(id, work)
    }

    func cancel(_ id: UUID? = nil) -> String {
        guard let id = id ?? waitingID, states[id] == .waiting else { return "Okay." }
        proposals[id] = nil
        states[id] = .cancelled
        if waitingID == id { waitingID = nil }
        return "Okay, I won't."
    }

    var hasWaiting: Bool { waitingID.map { states[$0] == .waiting } ?? false }

    // MARK: Do it now

    /// Runs an action straight away. Returns its id and what to say.
    func perform(_ title: String, work: @escaping Work) async -> (id: UUID, spoken: String) {
        let id = UUID()
        titles[id] = title
        return (id, await run(id, work))
    }

    private func run(_ id: UUID, _ work: Work) async -> String {
        states[id] = .working
        do {
            let (spoken, undo) = try await work()
            states[id] = .done(spoken)
            if let undo {
                undos[id] = undo
                lastUndoable = id
            }
            return spoken
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            states[id] = .failed(reason)
            return "That didn't work: \(reason)"
        }
    }

    // MARK: Undo

    func canUndo(_ id: UUID) -> Bool {
        guard let undo = undos[id], case .done = states[id] else { return false }
        return Date.now.timeIntervalSince(undo.at) < 120
    }

    /// Undoes one action, or the newest one ("undo that").
    @discardableResult
    func undo(_ id: UUID? = nil) async -> String {
        guard let id = id ?? lastUndoable, canUndo(id), let undo = undos[id] else {
            return "There's nothing I can undo right now."
        }
        do {
            try await undo.perform()
            undos[id] = nil
            states[id] = .undone
            if lastUndoable == id { lastUndoable = nil }
            return "Undone: \(undo.title)."
        } catch {
            return "I couldn't undo that: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: Answers to "yes", "no" and "undo"

    enum Reply { case yes, no, undo }

    /// A short reply that answers a waiting question (or asks to undo), handled without a model.
    func reply(in text: String) -> Reply? {
        let words = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["undo", "undo that", "undo it", "take that back", "never mind, undo that"].contains(words), lastUndoable.map(canUndo) == true {
            return .undo
        }
        guard hasWaiting else { return nil }
        let yes = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "do it", "go ahead", "confirm", "please do", "yes please",
                   "that's right", "correct", "sounds good", "yes do it", "approve", "approve it", "approve them"]
        let no = ["no", "nope", "cancel", "don't", "do not", "never mind", "stop", "no thanks", "no thank you", "wait"]
        if yes.contains(words) { return .yes }
        if no.contains(words) { return .no }
        return nil
    }
}

/// An action's failure, said plainly.
nonisolated struct EmberActionError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
