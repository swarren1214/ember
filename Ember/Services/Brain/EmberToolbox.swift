import Foundation
import Observation

// Ember's tools, run on the device in every tier. The on-device model calls them through
// EmberTools.swift; Claude asks for them by name through hearth-api and the device runs them
// here (EmberBrain). Either way:
//
// - Each tool reads what the Hearth apps published (EmberContext) and returns a few lines of
//   plain text for the model, and a card for the screen.
// - Privacy rule 1: sensitive work stays here and only the conclusion goes back. Allergies are
//   checked on the device ("fits everyone: yes"); budgets return the figure asked about.
// - Changes go through the app that owns the data: Ember hands off with that app's link, as
//   every Hearth app does. It never writes another app's data.

/// Something an answer shows under the text.
struct EmberCard: Identifiable {
    enum Kind {
        case meal(title: String, detail: String, imageURL: URL?, fitsEveryone: Bool?)
        case groceries(remaining: Int, cost: String?)
        case budget(name: String, left: String, spent: String, fraction: Double)
        case reading([ReadingLine])
        case people([String])
        case allowance([String])
        /// Open another Hearth app (or Messages) to finish something there.
        case handoff(title: String, detail: String, symbol: String)
    }

    struct ReadingLine: Hashable {
        var title: String
        var plan: String
        var isDone: Bool
    }

    let id = UUID()
    var app: HearthApp?
    var kind: Kind
    /// Opens the thing in its app.
    var link: URL?
    var actionTitle: String?
    /// Opened for them once Ember has finished speaking (a call: the system still asks first).
    var opensWhenSpoken = false
}

@MainActor
final class EmberToolbox {
    static let shared = EmberToolbox()

    private var context: EmberContext { .shared }
    private var cards: [EmberCard] = []
    private(set) var usedApps: [HearthApp] = []

    /// The tools on offer this turn. Kids get no money tools.
    var toolNames: [String] {
        var names = ["household_people", "meals_planned", "meal_fits_household", "meal_times", "grocery_status", "study_today", "open_app", "message_draft", "place_call"]
        if !context.isKid { names += ["budget_status", "allowance_recent"] }
        return names.filter { name in
            guard let app = Self.app(for: name) else { return true }
            return EmberSettings.shared.canRead(app)
        }
    }

    func beginTurn() {
        cards = []
        usedApps = []
        context.refresh()
    }

    func takeCards() -> [EmberCard] {
        defer { cards = [] }
        return cards
    }

    private func use(_ app: HearthApp) {
        if !usedApps.contains(app) { usedApps.append(app) }
    }

    /// Which app a tool reads, for the "From BigTable and Suffice" line.
    static func app(for tool: String) -> HearthApp? {
        switch tool {
        case "meals_planned", "meal_fits_household", "grocery_status": .bigtable
        case "budget_status": .suffice
        case "allowance_recent": .caloma
        case "study_today": .hearken
        default: nil
        }
    }

    // MARK: Running a tool by name (the cloud path)

    func run(_ name: String, input: [String: EmberJSON]) async -> String {
        guard toolNames.contains(name) else { return "That tool isn't available." }
        let arg = { (key: String) in input[key]?.string ?? "" }
        switch name {
        case "household_people": return householdPeople()
        case "meals_planned": return mealsPlanned(days: arg("days"), meal: arg("meal"))
        case "meal_fits_household": return mealFits(days: arg("day"), meal: arg("meal"))
        case "meal_times": return mealTimes()
        case "grocery_status": return groceryStatus()
        case "budget_status": return budgetStatus()
        case "allowance_recent": return allowanceRecent()
        case "study_today": return studyToday()
        case "open_app": return openApp(arg("place"))
        case "message_draft": return messageDraft(arg("text"))
        case "place_call": return await placeCall(who: arg("who"), near: arg("near"))
        default: return "That tool isn't available."
        }
    }

    // MARK: Household

    func householdPeople() -> String {
        let people = context.people
        guard !people.isEmpty else { return "No household is set up yet." }
        let lines = people.map { person -> String in
            let age = person.age().map { ", \($0)" } ?? ""
            let me = person.id == context.me?.id ? " (the person asking)" : ""
            return "- \(person.name): \(person.role.rawValue)\(age)\(me)"
        }
        cards.append(EmberCard(app: nil, kind: .people(people.map(\.name))))
        return "The household (\(people.count) people):\n" + lines.joined(separator: "\n")
    }

    // MARK: Meals (BigTable)

    func mealsPlanned(days: String, meal: String) -> String {
        guard let plan = context.mealPlan?.value else {
            return "BigTable hasn't shared a meal plan on this iPhone. Opening BigTable once shares it."
        }
        use(.bigtable)
        let dates = EmberDays.dates(for: days)
        let slots = ["breakfast", "lunch", "dinner"].filter { meal.isEmpty || meal == "all" || meal == $0 }
        var lines: [String] = []
        for date in dates {
            let label = EmberDays.label(date)
            let meals = slots.compactMap { slot in plan.meal(slot, on: date).map { (slot, $0) } }
            if meals.isEmpty {
                lines.append("\(label): nothing planned")
                continue
            }
            for (slot, planned) in meals {
                var line = "\(label) \(slot): \(planned.title)"
                if let place = planned.placeName { line += " (out, at \(place))" }
                if let away = planned.notEating, !away.isEmpty { line += "; not eating: \(away.joined(separator: ", "))" }
                lines.append(line)
            }
        }
        // A card for a single meal; a week is just text.
        let cardSlot = slots.count == 1 ? slots[0] : "dinner"
        if dates.count == 1, let planned = plan.meal(cardSlot, on: dates[0]) {
            let slot = cardSlot
            cards.append(EmberCard(
                app: .bigtable,
                kind: .meal(title: planned.title, detail: "\(EmberDays.label(dates[0])) · \(slot.capitalized)",
                            imageURL: planned.imageURL.flatMap(URL.init(string:)), fitsEveryone: nil),
                link: planned.link.flatMap(URL.init(string:)) ?? URL(string: "bigtable://plan"),
                actionTitle: "Open in BigTable"
            ))
        }
        return lines.joined(separator: "\n")
    }

    /// Checks a planned meal's ingredients against everyone's allergies, here. Only the verdict
    /// leaves the device.
    func mealFits(days: String, meal: String) -> String {
        guard let plan = context.mealPlan?.value else { return "No meal plan on this iPhone." }
        let date = EmberDays.dates(for: days.isEmpty ? "today" : days).first ?? .now
        let slot = ["breakfast", "lunch", "dinner"].contains(meal) ? meal : "dinner"
        guard let planned = plan.meal(slot, on: date) else { return "Nothing is planned for that meal." }
        use(.bigtable)
        let ingredients = (planned.recipes ?? []).flatMap(\.ingredients).map { $0.name.lowercased() }
        guard !ingredients.isEmpty else {
            return "\(planned.title): BigTable hasn't shared its ingredients, so Ember can't check allergies. BigTable checks them when it plans."
        }
        var conflicts: [String] = []
        for person in context.people where person.allergies.contains(where: { Self.matches($0, in: ingredients) }) {
            conflicts.append(person.name)
        }
        let fits = conflicts.isEmpty
        cards.append(EmberCard(
            app: .bigtable,
            kind: .meal(title: planned.title, detail: "\(EmberDays.label(date)) · \(slot.capitalized)",
                        imageURL: planned.imageURL.flatMap(URL.init(string:)), fitsEveryone: fits),
            link: planned.link.flatMap(URL.init(string:)), actionTitle: "Open in BigTable"
        ))
        return fits
            ? "\(planned.title): fits everyone's allergies."
            : "\(planned.title): doesn't fit an allergy for \(conflicts.joined(separator: ", ")). Don't name the allergy."
    }

    private static func matches(_ allergy: String, in ingredients: [String]) -> Bool {
        let word = allergy.lowercased().trimmingCharacters(in: .whitespaces)
        guard word.count > 2 else { return false }
        let stem = word.hasSuffix("s") ? String(word.dropLast()) : word
        return ingredients.contains { $0.contains(stem) }
    }

    func mealTimes() -> String {
        let times = HearthMealTimes.current
        func time(_ slot: String) -> String {
            times.start(for: slot, on: .now).formatted(date: .omitted, time: .shortened)
        }
        return "Breakfast \(time("breakfast")), lunch \(time("lunch")), dinner \(time("dinner"))."
    }

    // MARK: Groceries and money

    func groceryStatus() -> String {
        guard let list = context.groceries?.value.list else {
            return "There's no active grocery list in BigTable."
        }
        use(.bigtable)
        let cost = list.estimatedCost.map { EmberFormat.money($0) }
        cards.append(EmberCard(app: .bigtable, kind: .groceries(remaining: list.remainingCount, cost: cost),
                               link: URL(string: list.link ?? "bigtable://grocery"), actionTitle: "Open List"))
        var line = "\(list.remainingCount) of \(list.itemCount) items still to buy"
        if let cost { line += ", about \(cost) for the whole list" }
        return line + ". (Ember can see the counts, not the items: open BigTable to see or add items.)"
    }

    func budgetStatus() -> String {
        guard let budget = context.groceryBudget?.value else {
            return "Suffice hasn't shared a budget on this iPhone."
        }
        use(.suffice)
        let left = EmberFormat.money(cents: budget.leftCents, code: budget.currencyCode)
        let spent = EmberFormat.money(cents: budget.spentCents, code: budget.currencyCode)
        let limit = EmberFormat.money(cents: budget.limitCents, code: budget.currencyCode)
        let fraction = budget.limitCents > 0 ? Double(budget.spentCents) / Double(budget.limitCents) : 0
        cards.append(EmberCard(app: .suffice, kind: .budget(name: budget.name, left: left, spent: "\(spent) of \(limit) spent", fraction: fraction),
                               link: budget.link.flatMap(URL.init(string:)), actionTitle: "Open in Suffice"))
        return "\(budget.name) this month: \(left) left of \(limit) (\(spent) spent). Suffice shares only this budget with Ember so far."
    }

    func allowanceRecent() -> String {
        guard let allowance = context.allowance?.value else { return "Caloma hasn't shared allowance on this iPhone." }
        use(.caloma)
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let recent = allowance.payouts.filter { $0.date >= cutoff }
        guard !recent.isEmpty else { return "No allowance paid in the last 30 days." }
        let byKid = Dictionary(grouping: recent, by: \.name).map { name, payouts in
            "\(name): \(EmberFormat.money(cents: payouts.reduce(0) { $0 + $1.cents }, code: allowance.currencyCode))"
        }.sorted()
        cards.append(EmberCard(app: .caloma, kind: .allowance(byKid), link: URL(string: "caloma://"), actionTitle: "Open Caloma"))
        return "Allowance paid in the last 30 days: " + byKid.joined(separator: "; ")
    }

    // MARK: Study (Hearken)

    func studyToday() -> String {
        guard let reading = context.reading?.value else { return "Hearken hasn't shared a reading plan on this iPhone." }
        use(.hearken)
        guard let today = reading.day(.now), !today.readings.isEmpty else { return "No reading scheduled today." }
        let lines = today.readings.map { EmberCard.ReadingLine(title: $0.title, plan: $0.planName, isDone: $0.isDone) }
        cards.append(EmberCard(app: .hearken, kind: .reading(lines),
                               link: today.readings.first(where: { !$0.isDone })?.link.flatMap(URL.init(string:)) ?? URL(string: "hearken://"),
                               actionTitle: "Open in Hearken"))
        return lines.map { "\($0.title) (\($0.plan)): \($0.isDone ? "done" : "not yet")" }.joined(separator: "\n")
    }

    // MARK: Handoffs

    /// Adds a button that opens the right app; nothing changes until the person taps it.
    func openApp(_ place: String) -> String {
        let target: (HearthApp, String, String, URL?)? = switch place {
        case "grocery_list": (.bigtable, "Grocery list", "Add or check off items in BigTable", URL(string: "bigtable://grocery"))
        case "meal_plan": (.bigtable, "Meal plan", "Plan or change a meal in BigTable", URL(string: "bigtable://plan"))
        case "budget": (.suffice, "Budget", "Move money or log spending in Suffice", context.groceryBudget?.value.link.flatMap(URL.init(string:)) ?? URL(string: "suffice://"))
        case "chores", "calendar": (.caloma, place == "chores" ? "Chores" : "Family calendar", "Open Caloma", URL(string: "caloma://"))
        case "reading": (.hearken, "Today’s reading", "Open Hearken", URL(string: "hearken://"))
        case "food_log": (.sated, "Food log", "Log it in Sated", URL(string: "sated://"))
        default: nil
        }
        guard let (app, title, detail, url) = target else { return "Ember can't open that." }
        cards.append(EmberCard(app: app, kind: .handoff(title: title, detail: detail, symbol: "arrow.up.forward.app"),
                               link: url, actionTitle: "Open \(app.displayName)"))
        return "A button to open \(app.displayName) is ready. Say it's ready to open; don't say it's done."
    }

    /// A text the person sends themselves from Messages.
    func messageDraft(_ text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "Nothing to send." }
        let url = URL(string: "sms:&body=" + (body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))
        cards.append(EmberCard(app: nil, kind: .handoff(title: "Message", detail: "“\(body)”", symbol: "message"),
                               link: url, actionTitle: "Open Messages"))
        return "A draft is ready in Messages for them to pick who to send it to. Say it's ready; it isn't sent."
    }

    /// A call to someone in their contacts or a place in Apple Maps. The phone's own call screen
    /// opens once Ember finishes speaking and asks before dialing; the number never goes to a model.
    func placeCall(who: String, near: String) async -> String {
        switch await EmberCallFinder.find(who, near: near) {
        case .success(let target):
            cards.append(EmberCard(app: nil, kind: .handoff(title: target.name, detail: target.detail, symbol: "phone.fill"),
                                   link: target.url, actionTitle: "Call", opensWhenSpoken: true))
            let place = target.place.map { " (\($0))" } ?? ""
            return "Found \(target.name)\(place). The call screen opens as soon as you finish speaking, and they tap Call to dial. Say you're calling them, in a few words. Don't say a number."
        case .failure(.needsLocation):
            return "Ember needs Location to find \(who) nearby. Ask them to say the town, or allow Location for Ember in Settings."
        case .failure(.nothingFound):
            let place = near.isEmpty ? "" : " in \(near)"
            return "No phone number for \(who)\(place) in Contacts or Apple Maps."
        }
    }
}

/// Days the way people say them.
nonisolated enum EmberDays {
    static let choices = ["today", "tomorrow", "this week", "next week", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static func dates(for spoken: String, now: Date = .now, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let key = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        switch key {
        case "", "today", "tonight": return [today]
        case "tomorrow": return [day(1)]
        case "this week": return (0..<7).map(day)
        case "next week": return (7..<14).map(day)
        default:
            if let index = choices.firstIndex(of: key), index >= 4 {
                let weekday = index - 3   // sunday = 1
                let current = calendar.component(.weekday, from: today)
                let ahead = (weekday - current + 7) % 7
                return [day(ahead)]
            }
            return [today]
        }
    }

    static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }
}
