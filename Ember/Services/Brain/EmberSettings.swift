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
            case .appleAndClaude: "The hardest questions can go to Claude, with names replaced and nothing that identifies you. On Apple Watch, answers are spoken by a cloud voice, which hears first names but keeps nothing."
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

    /// The Kokoro voice ("af_heart") and how fast it speaks (0.9 to 1.2).
    var voiceID: String {
        didSet { defaults.set(voiceID, forKey: Keys.voiceID) }
    }

    var voiceSpeed: Double {
        didSet { defaults.set(voiceSpeed, forKey: Keys.voiceSpeed) }
    }

    /// How Ember should say a word: "Caloma" → "kuh LOH muh". Applied before speaking.
    var pronunciations: [String: String] {
        didSet { defaults.set(pronunciations, forKey: Keys.pronunciations) }
    }

    /// Things the person asked Ember to remember about them ("my store is the Springville
    /// Smith's"). Kept on this iPhone; the on-device model reads them, and they're shown and
    /// deletable in What Ember Knows.
    var remembered: [String] {
        didSet { defaults.set(remembered, forKey: Keys.remembered) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let cloudHelp = "ember.cloudHelp"
        static let readable = "ember.readable"
        static let naturalVoice = "ember.naturalVoice"
        static let voiceID = "ember.voiceID"
        static let voiceSpeed = "ember.voiceSpeed"
        static let pronunciations = "ember.pronunciations"
        static let remembered = "ember.remembered"
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
        voiceID = defaults.string(forKey: Keys.voiceID) ?? KokoroVoices.defaultID
        voiceSpeed = defaults.object(forKey: Keys.voiceSpeed) as? Double ?? 1.05
        pronunciations = defaults.dictionary(forKey: Keys.pronunciations) as? [String: String] ?? Self.defaultPronunciations
        remembered = defaults.stringArray(forKey: Keys.remembered) ?? []
    }

    /// Hearth's own names, said right from the start.
    static let defaultPronunciations = ["Caloma": "kuh LOH muh", "Sated": "SAY tid", "Hearken": "HAR kun", "Suffice": "suh FICE"]

    func canRead(_ app: HearthApp) -> Bool { readable.contains(app) }

    func setReadable(_ app: HearthApp, _ on: Bool) {
        if on { readable.insert(app) } else { readable.remove(app) }
    }
}
