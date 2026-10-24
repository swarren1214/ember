import Foundation
import Observation

// Where Ember reads the Hearth apps from on the iPhone:
//
// - Suffice's budget, Caloma's family and BigTable's kitchen: straight from their iCloud zones in
//   the Hearth container (EmberZone), which the household's engines keep in sync. Complete and
//   current, and Ember can change them the way those apps do.
// - Meal plans, Hearken's reading, Sated's food log, allowance: the summaries those apps publish
//   in the app group (EmberContext), refreshed whenever the apps change them.
//
// Zones are fetched when a question needs them, at most once a minute, and ahead of time when
// Ember opens or starts listening.

@Observable
final class EmberData {
    static let shared = EmberData()

    @ObservationIgnored let budget = EmberZone(zoneName: SufficeLedger.zoneName)
    @ObservationIgnored let family = EmberZone(zoneName: CalomaFamily.zoneName)
    @ObservationIgnored let kitchen = EmberZone(zoneName: BigTableGroceries.zoneName)

    private var household: HearthHouseholdStore { .shared }

    /// Points every zone at the household's iCloud: this person's own, or the family they joined.
    private func locate() {
        let owner: String? = if case .member(let name) = household.mode { name } else { nil }
        for zone in [budget, family, kitchen] { zone.setHouseholdOwner(owner) }
    }

    /// Fetches whatever changed in all three zones (in parallel). Cheap when nothing did.
    /// Warms the mirrors ahead of a question. Called on every listen, so it looks at iCloud at
    /// most every few minutes; a question that needs fresher data fetches for itself.
    func prefetch() {
        if let lastPrefetch, Date.now.timeIntervalSince(lastPrefetch) < 300 { return }
        lastPrefetch = .now
        locate()
        Task(priority: .utility) { await refreshAll() }
    }

    @ObservationIgnored private var lastPrefetch: Date?

    func refreshAll(force: Bool = false) async {
        locate()
        async let a: Void = budget.refresh(force: force)
        async let b: Void = family.refresh(force: force)
        async let c: Void = kitchen.refresh(force: force)
        _ = await (a, b, c)
    }

    // MARK: Snapshots for a question

    func ledger() async -> Result<SufficeLedger, EmberZoneError> {
        locate()
        await budget.refresh()
        let ledger = await budget.snapshot(SufficeLedger.init(records:))
        if ledger.isEmpty, let error = budget.lastError { return .failure(error) }
        return .success(ledger)
    }

    func familyBoard() async -> Result<CalomaFamily, EmberZoneError> {
        locate()
        await family.refresh()
        // Never an answer from a copy that couldn't be brought up to date: chores and approvals
        // change by the minute, and an old copy reads as the wrong answer.
        if let error = family.lastError { return .failure(error) }
        let value = await family.snapshot(CalomaFamily.init(records:))
        return .success(value)
    }

    func groceries() async -> Result<BigTableGroceries, EmberZoneError> {
        locate()
        await kitchen.refresh()
        if let error = kitchen.lastError { return .failure(error) }
        let value = await kitchen.snapshot(BigTableGroceries.init(records:))
        return .success(value)
    }

    /// What to tell the model when an app's zone can't be read. Never "no access" unless the
    /// person switched the app off in What Ember Knows.
    static func explain(_ error: EmberZoneError, app: HearthApp) -> String {
        switch error {
        case .noAccount:
            return "This iPhone isn't signed in to iCloud, which is where \(app.displayName) keeps the family's data. Ask them to sign in to iCloud in Settings."
        case .notShared:
            return "\(app.displayName) hasn't synced anything to iCloud yet. Opening \(app.displayName) once (signed in to iCloud) fixes it."
        case .failed(let reason):
            return "Couldn't reach iCloud for \(app.displayName) just now (\(reason)). Ask them to try again in a moment."
        }
    }
}
