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
    /// Suffice's own numbers on this iPhone (SufficeMoney).
    private(set) var money: HearthMoney.Book?
    /// Caloma's family from iCloud (Caloma shares nothing on the device yet), for today's glance.
    private(set) var family: CalomaFamily?
    private(set) var refreshedAt = Date.distantPast
    @ObservationIgnored private var loadingFamily: Task<Void, Never>?

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
        money = settings.canRead(.suffice) ? SufficeMoney.onThisPhone()?.book : nil
        refreshedAt = .now
        if settings.canRead(.caloma), loadingFamily == nil {
            loadingFamily = Task {
                if case .success(let board) = await EmberData.shared.familyBoard(), !board.isEmpty { family = board }
                loadingFamily = nil
            }
        } else if !settings.canRead(.caloma) {
            family = nil
        }
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
        /// What tapping it asks Ember.
        var question: String
        /// One app can have more than one line (dinner and the grocery list).
        var id: String { "\(app.rawValue)-\(detail)" }
    }

    /// A line from each app that has something to say today, in the order a day runs:
    /// the family's schedule, dinner, groceries, money, food, reading.
    var glances: [Glance] {
        var result: [Glance] = []
        let now = Date.now
        let calendar = Calendar.current

        // Caloma: what's next on the family calendar today, else the chores still to do.
        if let family {
            let today = EmberRange(start: calendar.startOfDay(for: now), end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now)
            let next = family.occurrences(in: today).filter { !$0.event.isAllDay && $0.end > now }.min { $0.start < $1.start }
            if let next {
                result.append(Glance(app: .caloma, value: next.event.title,
                                     detail: next.start <= now ? "Happening now" : "At \(next.start.formatted(date: .omitted, time: .shortened))",
                                     link: URL(string: "caloma://calendar"), question: "What’s on the family calendar today?"))
            } else {
                let open = family.board(on: now).filter { $0.status == .open }.count
                if open > 0 {
                    result.append(Glance(app: .caloma, value: open == 1 ? "1 chore left" : "\(open) chores left", detail: "Today",
                                         link: URL(string: "caloma://chores"), question: "Which chores are left today?"))
                }
            }
        }
        if let plan = mealPlan?.value {
            let dinner = plan.meal("dinner", on: now)
            result.append(Glance(app: .bigtable, value: dinner?.title ?? "Not planned", detail: "Tonight’s dinner",
                                 link: URL(string: dinner?.link ?? "bigtable://plan"), question: "What’s for dinner tonight?"))
        }
        if let list = groceries?.value.list, list.remainingCount > 0 {
            result.append(Glance(app: .bigtable, value: "\(list.remainingCount) items", detail: "On the grocery list",
                                 link: URL(string: list.link ?? "bigtable://grocery"), question: "What’s on the grocery list?"))
        }
        // Suffice: what's left across the budgets, from Suffice's own numbers; else the
        // groceries budget it shares with BigTable.
        if let money {
            let month = HearthMoney.Span.month(containing: now, calendar: calendar)
            let planned = HearthMoney.statuses(money.categories, entries: money.entries, in: month, calendar: calendar).filter { $0.limitCents > 0 }
            if !planned.isEmpty {
                let left = planned.reduce(0) { $0 + $1.leftCents }
                result.append(Glance(app: .suffice, value: left >= 0 ? "\(HearthMoney.whole(left)) left" : "\(HearthMoney.whole(-left)) over",
                                     detail: "Budgets this month", link: URL(string: "suffice://budget"),
                                     question: "How are our budgets doing this month?"))
            }
        } else if let budget = groceryBudget?.value {
            result.append(Glance(app: .suffice, value: EmberFormat.money(cents: budget.leftCents, code: budget.currencyCode),
                                 detail: "Left for \(budget.name.lowercased())", link: budget.link.flatMap(URL.init(string:)),
                                 question: "How much is left for \(budget.name.lowercased())?"))
        }
        // Sated: calories left today.
        if let log = foodLog?.value, log.goals.calories > 0 {
            let todayKey = HearthDay.string(from: now)
            let eaten = log.days.first { $0.date == todayKey }?.totals.calories ?? 0
            let left = Int((log.goals.calories - eaten).rounded())
            result.append(Glance(app: .sated, value: left >= 0 ? "\(left) calories left" : "\(-left) calories over",
                                 detail: "Today", link: URL(string: log.addLink ?? "sated://add"),
                                 question: "How many calories do I have left today?"))
        }
        if let today = reading?.value.day(now), !today.readings.isEmpty {
            let left = today.readings.filter { !$0.isDone }
            result.append(Glance(app: .hearken, value: left.isEmpty ? "Done" : left[0].title,
                                 detail: left.isEmpty ? "Today’s reading" : "To read today",
                                 link: (left.first ?? today.readings[0]).link.flatMap(URL.init(string:)),
                                 question: "What’s my reading today?"))
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
