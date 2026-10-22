import Foundation
import Observation
import OSLog
import WatchConnectivity

// Ember on Apple Watch (implementation plan › Apple Watch). The Watch picks a mode for each
// question:
//
//   Tethered    the iPhone is reachable: it runs the turn exactly as if asked there.
//   Standalone  no iPhone, but Wi-Fi or cellular: the Watch calls hearth-api itself, with its
//               own Hearth session, the redactor running here, and the day's facts the iPhone
//               last sent as its one tool. (Live iCloud reads replace those facts in Phase 4.)
//   Offline     neither: glances only, and Ember says it needs a connection.

@Observable
final class WatchModel: NSObject {
    static let shared = WatchModel()

    enum Phase: Equatable {
        case face
        case thinking(String)
        case answer(EmberWatchReply)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.face, .face): true
            case (.thinking(let a), .thinking(let b)): a == b
            case (.answer(let a), .answer(let b)): a.id == b.id
            case (.failed(let a), .failed(let b)): a == b
            default: false
            }
        }
    }

    private(set) var phase: Phase = .face
    private(set) var context: EmberWatchContext?
    private(set) var isIPhoneReachable = false

    @ObservationIgnored private let speaker = WatchSpeaker()
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.ember.watch", category: "model")

    var glances: [EmberGlance] { context?.glances ?? [] }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        if let data = WCSession.default.receivedApplicationContext[EmberWire.context] as? Data {
            context = EmberWire.decode(EmberWatchContext.self, from: data)
        }
    }

    /// What was dictated.
    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        speaker.stop()
        phase = .thinking(question)
        Task {
            let reply: EmberWatchReply
            if WCSession.default.isReachable, let tethered = await askIPhone(question) {
                reply = tethered
            } else {
                reply = await WatchBrain.shared.ask(question, context: context)
            }
            phase = .answer(reply)
            speaker.speak(reply.text)
        }
    }

    func dismiss() {
        speaker.stop()
        phase = .face
    }

    /// Tethered: the iPhone answers. Nil when it stopped answering (out of range mid-question).
    private func askIPhone(_ question: String) async -> EmberWatchReply? {
        let ask = EmberWatchAsk(id: UUID(), text: question)
        guard let data = EmberWire.encode(ask) else { return nil }
        return await withCheckedContinuation { continuation in
            let once = WatchOnce(continuation)
            WCSession.default.sendMessage([EmberWire.ask: data]) { response in
                once.resume(EmberWire.decode(EmberWatchReply.self, from: response[EmberWire.reply] as? Data))
            } errorHandler: { error in
                Logger(subsystem: "com.stephenwarren.ember.watch", category: "model")
                    .notice("iPhone didn't answer: \(error.localizedDescription, privacy: .public)")
                once.resume(nil)
            }
        }
    }

    fileprivate func received(_ context: EmberWatchContext) {
        self.context = context
    }

    fileprivate func reachabilityChanged(_ reachable: Bool) {
        isIPhoneReachable = reachable
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in WatchModel.shared.reachabilityChanged(reachable) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in WatchModel.shared.reachabilityChanged(reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let context = EmberWire.decode(EmberWatchContext.self, from: applicationContext[EmberWire.context] as? Data) else { return }
        Task { @MainActor in WatchModel.shared.received(context) }
    }
}

/// Resumes a continuation once, whichever WatchConnectivity handler fires.
private final class WatchOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EmberWatchReply?, Never>?

    init(_ continuation: CheckedContinuation<EmberWatchReply?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: EmberWatchReply?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
