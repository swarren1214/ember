import Foundation
import OSLog
import WatchConnectivity

// The iPhone side of Ember on Apple Watch (implementation plan › Apple Watch › Tethered).
//
// When the iPhone is reachable, the Watch sends what it heard here and the iPhone runs the turn
// exactly as if it had been asked on the iPhone: on-device model first, the same tools, the same
// privacy rules. The Watch speaks the reply. The iPhone also keeps the Watch's glances fresh.
//
// When it isn't reachable, the Watch calls hearth-api itself (EmberWatch/WatchBrain.swift).

final class EmberWatchRelay: NSObject {
    static let shared = EmberWatchRelay()

    private let log = Logger(subsystem: "com.stephenwarren.ember", category: "watch")
    private var observer: NSObjectProtocol?

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        observer = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EmberWatchRelay.shared.pushGlances() }
        }
    }

    /// What the Watch keeps for when the iPhone is out of reach, whenever it changes.
    func pushGlances() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let context = EmberContext.shared
        let watchContext = EmberWatchContext(
            glances: context.watchGlances,
            people: context.people.map { EmberWatchContext.Person(name: $0.name, role: $0.role.rawValue, age: $0.age()) },
            cloudHelp: EmberSettings.shared.cloudHelp?.rawValue,
            facts: context.watchFacts,
            updatedAt: .now,
            householdOwner: { if case .member(let owner) = HearthHouseholdStore.shared.mode { owner } else { nil } }()
        )
        guard let data = EmberWire.encode(watchContext) else { return }
        try? session.updateApplicationContext([EmberWire.context: data])
    }

    /// Runs a question from the Watch and builds the reply.
    private func answer(_ ask: EmberWatchAsk) async -> EmberWatchReply {
        // "Yes", "no" and "undo" answer a waiting action here, as on the iPhone.
        if let reply = EmberActions.shared.reply(in: ask.text) {
            let spoken: String = switch reply {
            case .yes: await EmberActions.shared.confirm()
            case .no: EmberActions.shared.cancel()
            case .undo: await EmberActions.shared.undo()
            }
            return EmberWatchReply(id: ask.id, text: spoken, actions: [], tier: .none)
        }
        // The Watch speaks the whole reply itself, so the sentences aren't streamed to it.
        let turn = await EmberBrain.shared.ask(ask.text, client: .watch) { _ in }
        if EmberActions.shared.hasWaiting {
            // Double tap confirms (the primary button).
            return EmberWatchReply(id: ask.id, text: turn.answer,
                                   actions: [EmberWatchAction(title: "Confirm", followUp: "yes"), EmberWatchAction(title: "Cancel", followUp: "no")],
                                   tier: turn.tier)
        }
        let calls = turn.cards.filter { if case .call = $0.kind { true } else { false } }
        let actions = turn.cards.compactMap { card -> EmberWatchAction? in
            guard let url = card.link, ["sms", "tel"].contains(url.scheme ?? "") else { return nil }
            switch card.kind {
            case .call(let name, let detail, _):
                // Several branches: say which one each button calls.
                let label = calls.count > 1 ? (detail.components(separatedBy: " · ").first ?? name) : name
                return EmberWatchAction(title: "Call \(label)", url: url.absoluteString)
            case .handoff(let title, _, _):
                return EmberWatchAction(title: title == "Message" ? "Send Text" : title, url: url.absoluteString)
            default:
                return nil
            }
        }
        return EmberWatchReply(id: ask.id, text: turn.answer, actions: Array(actions.prefix(2)), tier: turn.tier)
    }
}

extension EmberWatchRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in EmberWatchRelay.shared.pushGlances() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let ask = EmberWire.decode(EmberWatchAsk.self, from: message[EmberWire.ask] as? Data) else {
            replyHandler([:])
            return
        }
        let reply = SendableReply(replyHandler)
        Task { @MainActor in
            let answer = await EmberWatchRelay.shared.answer(ask)
            reply.send([EmberWire.reply: EmberWire.encode(answer) ?? Data()])
        }
    }
}

/// WatchConnectivity's reply handler, carried to the main actor.
nonisolated private struct SendableReply: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ message: [String: Any]) { handler(message) }
}
