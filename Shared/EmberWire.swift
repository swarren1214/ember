import Foundation

// What Ember's iPhone and Apple Watch apps say to each other over WatchConnectivity, and the
// little the Watch keeps to show before you ask. Compiled into both apps.

nonisolated enum EmberWire {
    /// `sendMessage` keys.
    static let ask = "ember.ask"
    static let reply = "ember.reply"
    /// `updateApplicationContext` key.
    static let context = "ember.context"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

/// Which resource answered a turn. Shown as a small mark on cloud-assisted answers.
nonisolated enum EmberTier: String, Codable, Sendable {
    /// Apple's on-device model: nothing left the device.
    case onDevice
    /// Apple's Private Cloud Compute.
    case privateCloud
    /// Claude, through hearth-api, de-identified.
    case claude
    /// Answered without a model (a quick lookup, or an error message).
    case none

    var usedCloud: Bool { self == .privateCloud || self == .claude }
}

/// The Watch asks the iPhone.
nonisolated struct EmberWatchAsk: Codable, Sendable {
    var id: UUID
    var text: String
}

/// The iPhone's answer to the Watch: what to say, and at most two buttons.
nonisolated struct EmberWatchReply: Codable, Sendable {
    var id: UUID
    var text: String
    var actions: [EmberWatchAction]
    var tier: EmberTier
}

nonisolated struct EmberWatchAction: Codable, Sendable, Hashable, Identifiable {
    var title: String
    /// A system handoff the Watch can open itself (`sms:`, `tel:`), or nil when the action is a
    /// follow-up question the Watch sends back as `followUp`.
    var url: String?
    var followUp: String?
    var id: String { title }
}

/// One line for the Watch face before you ask ("Dinner isn't planned").
nonisolated struct EmberGlance: Codable, Sendable, Hashable, Identifiable {
    /// The Hearth app it's from (`HearthApp.rawValue`).
    var app: String
    var title: String
    var detail: String
    var id: String { app + title }
}

/// What the iPhone keeps on the Watch for when it's out of reach: the glances, who's who (for
/// the redactor, which runs on the Watch), Cloud Help, and the day's facts as short lines.
/// It travels only between the person's own devices.
nonisolated struct EmberWatchContext: Codable, Sendable {
    nonisolated struct Person: Codable, Sendable, Hashable {
        var name: String
        var role: String
        var age: Int?
    }

    var glances: [EmberGlance]
    var people: [Person]
    /// `EmberSettings.CloudHelp.rawValue`, or nil when not chosen yet.
    var cloudHelp: String?
    /// "Tonight's dinner: Sheet-Pan Chicken Fajitas", "Groceries budget: $86 left of $300".
    var facts: [String]
    var updatedAt: Date
    /// Who owns the household when this person joined someone else's (their iCloud zones are
    /// shared from that owner); nil when it's theirs.
    var householdOwner: String? = nil

    var allowsClaude: Bool { cloudHelp == "appleAndClaude" }
}
