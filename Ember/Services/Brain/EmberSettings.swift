import Foundation
import Observation

/// What the person chose in What Ember Knows. Kept on this device.
@Observable
final class EmberSettings {
    static let shared = EmberSettings()

    /// Privacy rule 6: the person picks, nothing is pre-picked. Until they do, Ember stays on
    /// the device.
    enum CloudHelp: String, CaseIterable, Identifiable {
        /// On device only. A standalone Watch can't answer.
        case off
        /// Apple's Private Cloud Compute only.
        case apple
        /// Private Cloud Compute, then Claude for the hardest questions. The most capable.
        case appleAndClaude

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Off"
            case .apple: "Apple Private Cloud Only"
            case .appleAndClaude: "Private Cloud and Claude"
            }
        }

        var detail: String {
            switch self {
            case .off: "Everything stays on your iPhone. Ember can’t answer from Apple Watch without your iPhone nearby."
            case .apple: "Harder questions go to Apple’s Private Cloud Compute, which keeps nothing."
            case .appleAndClaude: "The hardest questions can go to Claude, with names replaced and nothing that identifies you."
            }
        }

        var allowsClaude: Bool { self == .appleAndClaude }
    }

    /// Nil until the person chooses (onboarding).
    var cloudHelp: CloudHelp? {
        didSet {
            defaults.set(cloudHelp?.rawValue, forKey: Keys.cloudHelp)
            // The Watch follows the choice when it's on its own.
            EmberWatchRelay.shared.pushGlances()
        }
    }

    /// The Hearth apps Ember may read. Trove is never read without asking each time.
    var readable: Set<HearthApp> {
        didSet { defaults.set(readable.map(\.rawValue), forKey: Keys.readable) }
    }

    /// Kokoro when it's downloaded; off uses Apple's voice.
    var naturalVoice: Bool {
        didSet { defaults.set(naturalVoice, forKey: Keys.naturalVoice) }
    }

    /// Kids can talk to Ember: on device only, and only about meals, study and the calendar.
    var kidsCanTalk: Bool {
        didSet { defaults.set(kidsCanTalk, forKey: Keys.kidsCanTalk) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let cloudHelp = "ember.cloudHelp"
        static let readable = "ember.readable"
        static let naturalVoice = "ember.naturalVoice"
        static let kidsCanTalk = "ember.kidsCanTalk"
    }

    /// The apps Ember can read from today (the others publish nothing yet).
    static let sources: [HearthApp] = [.bigtable, .suffice, .sated, .caloma, .hearken, .trove]

    private init() {
        cloudHelp = defaults.string(forKey: Keys.cloudHelp).flatMap(CloudHelp.init(rawValue:))
        if let stored = defaults.stringArray(forKey: Keys.readable) {
            readable = Set(stored.compactMap(HearthApp.init(rawValue:)))
        } else {
            readable = Set(Self.sources.filter { $0 != .trove })
        }
        naturalVoice = defaults.object(forKey: Keys.naturalVoice) as? Bool ?? true
        kidsCanTalk = defaults.object(forKey: Keys.kidsCanTalk) as? Bool ?? false
    }

    func canRead(_ app: HearthApp) -> Bool { readable.contains(app) }

    func setReadable(_ app: HearthApp, _ on: Bool) {
        if on { readable.insert(app) } else { readable.remove(app) }
    }
}
