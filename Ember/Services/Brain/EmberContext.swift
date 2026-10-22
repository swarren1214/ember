import Foundation
import Observation

// What Ember knows right now. Every Hearth app publishes its own files to the app group
// (HearthShared.swift); Ember reads them and writes none. Changes to another app's data go
// through that app (a link or an App Intent), as every Hearth app does.
//
// The household comes from HearthHouseholdStore, which Ember starts like every Hearth app.

@Observable
final class EmberContext {
    static let shared = EmberContext()

    private(set) var mealPlan: HearthEnvelope<HearthMealPlan>?
    private(set) var groceries: HearthEnvelope<HearthGroceries>?
    private(set) var groceryBudget: HearthEnvelope<HearthGroceryBudget>?
    private(set) var reading: HearthEnvelope<HearthReading>?
    private(set) var allowance: HearthEnvelope<HearthAllowance>?
    private(set) var foodLog: HearthEnvelope<HearthFoodLog>?
    private(set) var refreshedAt = Date.distantPast

    @ObservationIgnored private var observer: NSObjectProtocol?

    func start() {
        refresh()
        guard observer == nil else { return }
        Hearth.startObservingChanges()
        observer = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EmberContext.shared.refresh() }
        }
    }

    /// Re-reads every app's files. Cheap: small JSON files on this device.
    func refresh() {
        let settings = EmberSettings.shared
        mealPlan = settings.canRead(.bigtable) ? Hearth.read(HearthMealPlan.self, from: .bigtable) : nil
        groceries = settings.canRead(.bigtable) ? Hearth.read(HearthGroceries.self, from: .bigtable) : nil
        groceryBudget = settings.canRead(.suffice) ? Hearth.read(HearthGroceryBudget.self, from: .suffice) : nil
        reading = settings.canRead(.hearken) ? Hearth.read(HearthReading.self, from: .hearken) : nil
        allowance = settings.canRead(.caloma) ? Hearth.read(HearthAllowance.self, from: .caloma) : nil
        foodLog = settings.canRead(.sated) ? Hearth.read(HearthFoodLog.self, from: .sated) : nil
        refreshedAt = .now
    }

    // MARK: The household

    var store: HearthHouseholdStore { .shared }
    var people: [HearthMember] { store.people }
    var me: HearthMember? { store.me }

    /// The household for the redactor: names stay on the device, roles and ages go as bands.
    var redactionPeople: [EmberPerson] {
        people.map { EmberPerson(name: $0.name, role: $0.role.rawValue, age: $0.age()) }
    }

    /// "Steve", or nil.
    var myFirstName: String? {
        me?.name.split(separator: " ").first.map(String.init)
    }

    // MARK: Glances (the idle screen and the Watch face)

    struct Glance: Identifiable, Hashable {
        var app: HearthApp
        var value: String
        var detail: String
        var link: URL?
        var id: String { app.rawValue }
    }

    /// One line from each app that has something to say today.
    var glances: [Glance] {
        var result: [Glance] = []
        if let plan = mealPlan?.value {
            let dinner = plan.meal("dinner", on: .now)
            result.append(Glance(app: .bigtable, value: dinner?.title ?? "Not planned", detail: "Tonight’s dinner",
                                 link: URL(string: dinner?.link ?? "bigtable://plan")))
        }
        if let budget = groceryBudget?.value {
            result.append(Glance(app: .suffice, value: EmberFormat.money(cents: budget.leftCents, code: budget.currencyCode),
                                 detail: "Left for \(budget.name.lowercased())", link: budget.link.flatMap(URL.init(string:))))
        }
        if let list = groceries?.value.list, list.remainingCount > 0 {
            result.append(Glance(app: .bigtable, value: "\(list.remainingCount) items", detail: "On the grocery list",
                                 link: URL(string: list.link ?? "bigtable://grocery")))
        }
        if let today = reading?.value.day(.now), !today.readings.isEmpty {
            let left = today.readings.filter { !$0.isDone }
            result.append(Glance(app: .hearken, value: left.isEmpty ? "Done" : left[0].title,
                                 detail: left.isEmpty ? "Today’s reading" : "To read today",
                                 link: (left.first ?? today.readings[0]).link.flatMap(URL.init(string:))))
        }
        return result
    }

    /// The day's facts as short lines, for a Watch that can't reach the iPhone. Allergies and
    /// money beyond the grocery budget stay off it.
    var watchFacts: [String] {
        var facts: [String] = []
        if let plan = mealPlan?.value {
            for offset in 0..<2 {
                guard let day = Calendar.current.date(byAdding: .day, value: offset, to: .now) else { continue }
                for slot in ["breakfast", "lunch", "dinner"] {
                    if let meal = plan.meal(slot, on: day) {
                        facts.append("\(EmberToolbox.dayLabel(day)) \(slot): \(meal.title)")
                    }
                }
            }
        }
        if let list = groceries?.value.list {
            facts.append("Grocery list: \(list.remainingCount) of \(list.itemCount) items left")
        }
        if let budget = groceryBudget?.value {
            facts.append("\(budget.name) budget: \(EmberFormat.money(cents: budget.leftCents, code: budget.currencyCode)) left of \(EmberFormat.money(cents: budget.limitCents, code: budget.currencyCode))")
        }
        if let today = reading?.value.day(.now) {
            for reading in today.readings {
                facts.append("Today's reading: \(reading.title) (\(reading.isDone ? "done" : "not yet"))")
            }
        }
        let times = HearthMealTimes.current
        facts.append("Meals at \(times.start(for: "breakfast", on: .now).formatted(date: .omitted, time: .shortened)), \(times.start(for: "lunch", on: .now).formatted(date: .omitted, time: .shortened)) and \(times.start(for: "dinner", on: .now).formatted(date: .omitted, time: .shortened))")
        return facts
    }

    /// The Watch's copy of the glances.
    var watchGlances: [EmberGlance] {
        glances.map { EmberGlance(app: $0.app.rawValue, title: $0.value, detail: $0.detail) }
    }
}

/// Numbers said the way a person says them.
nonisolated enum EmberFormat {
    /// "$86", whole units.
    static func money(cents: Int, code: String) -> String {
        (Double(cents) / 100).formatted(.currency(code: code).precision(.fractionLength(0)))
    }

    static func money(_ amount: Double, code: String = Locale.current.currency?.identifier ?? "USD") -> String {
        amount.formatted(.currency(code: code).precision(.fractionLength(0)))
    }
}
