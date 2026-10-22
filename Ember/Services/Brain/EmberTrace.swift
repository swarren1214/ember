import CoreLocation
import Foundation
import MapKit
import Observation

// A private log of the last 50 turns on this iPhone (implementation plan › Dependability 6):
// the question, the areas picked, the route, the tools that ran, how long it took, what went
// wrong. Nothing leaves the device unless the person taps Report a Problem, which opens an
// email to support with the log de-identified (names become tokens, numbers and addresses go)
// for them to read before sending.

@Observable
final class EmberTrace {
    static let shared = EmberTrace()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        var at: Date
        var question: String
        var notes: [String] = []
        var answer = ""
        var tier = ""
        var seconds: Double = 0
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var current: Entry?

    private var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "ember-trace.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func begin(_ question: String) {
        current = Entry(at: .now, question: question)
    }

    func note(_ text: String) {
        current?.notes.append(text)
    }

    func end(_ turn: EmberTurn) {
        guard var entry = current else { return }
        entry.answer = turn.answer
        entry.tier = turn.tier.rawValue
        entry.seconds = Date.now.timeIntervalSince(entry.at)
        entries.append(entry)
        entries = Array(entries.suffix(50))
        current = nil
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
    }

    /// The log as text, de-identified, for a report the person reads before sending.
    func report() -> String {
        var redactor = EmberRedactor(household: EmberContext.shared.redactionPeople)
        let device = "\(DeviceName.current), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let lines = entries.suffix(20).map { entry in
            """
            \(entry.at.formatted(date: .abbreviated, time: .standard)) · \(entry.tier) · \(String(format: "%.1f", entry.seconds)) s
            Q: \(redactor.redact(entry.question))
            \(entry.notes.map { "  - " + redactor.redact($0) }.joined(separator: "\n"))
            A: \(redactor.redact(entry.answer))
            """
        }
        return "Ember report (\(device))\n\n" + lines.joined(separator: "\n\n")
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// The city the person is in, roughly, for answers that depend on it ("the nearest Costco").
/// Kept on the device; only the on-device prompt sees it.
enum EmberPlace {
    private static let key = "ember.city"

    static var city: String? { UserDefaults.standard.string(forKey: key) }

    /// Looks up the city when Location is already allowed (never asks just for this).
    static func refresh() {
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        Task {
            guard let location = CLLocationManager().location else { return }
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first,
                  let name = item.addressRepresentations?.cityName else { return }
            UserDefaults.standard.set(name, forKey: key)
        }
    }
}
