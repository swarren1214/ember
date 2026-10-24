import CloudKit
import EventKit
import Foundation
import Observation

// Ember's tools, run on the device in every tier. The on-device model calls them as dynamic
// FoundationModels tools; Claude asks for them by name through hearth-api and the device runs
// them here (EmberBrain). Either way:
//
// - Reads compute on the device (EmberSkills) and return facts with numbers and the exact range
//   used. Privacy rule 1: sensitive work stays here and only conclusions go back (allergies are
//   checked here; budgets return totals, not transaction lists, unless asked for purchases).
// - Changes go through the same records the apps write (Suffice's and Caloma's zones, BigTable's
//   kitchen) or the system (EventKit, AlarmKit, Messages, Mail), via EmberActions: confirm first
//   for money, other people and family plans; do-it-with-undo for small personal things.
// - A tool never says something happened unless it did.

/// Something an answer shows under the text.
struct EmberCard: Identifiable {
    enum Kind {
        case meal(title: String, detail: String, imageURL: URL?, fitsEveryone: Bool?)
        case reading([ReadingLine])
        case people([String])
        case allowance([String])
        /// Open another Hearth app (or Messages) to finish something there.
        case handoff(title: String, detail: String, symbol: String)
        /// Someone to call: a contact, or a business with its logo.
        case call(name: String, detail: String, logo: URL?)
        /// Figures worked out on the device: a total, a list, a progress bar.
        case answer(EmberAnswer)
        /// A change: waiting to be confirmed, done (with Undo), or failed. Its state lives in
        /// EmberActions.
        case action(id: UUID, title: String, detail: String, symbol: String)
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
    /// A second button beside the first (a place: Directions, then Call).
    var secondaryLink: URL?
    var secondaryTitle: String?
    /// Opened for them once Ember has finished speaking (a call: the system still asks first).
    var opensWhenSpoken = false
}

@MainActor
final class EmberToolbox {
    static let shared = EmberToolbox()

    private var context: EmberContext { .shared }
    private var data: EmberData { .shared }
    private var actions: EmberActions { .shared }
    private var cards: [EmberCard] = []
    private(set) var usedApps: [HearthApp] = []
    /// Ember asked "which one?" this turn (calls, texts, contacts): listen for the answer.
    private(set) var asksToChoose = false

    /// What was asked this turn, for the period when the model leaves it out or garbles it.
    private var question = ""

    /// The period a tool should use: the model's, when it reads as a date; otherwise the one
    /// said in the question ("last week", "October 10"); otherwise the tool's default. The small
    /// model often leaves the range empty, which turned "last week" into this week.
    private func when(_ argument: String) -> String {
        if !argument.isEmpty, EmberDates.reads(argument) { return argument }
        return EmberDates.phrase(in: question) ?? argument
    }

    func beginTurn() {
        cards = []
        usedApps = []
        asksToChoose = false
        context.refresh()
    }

    func takeCards() -> [EmberCard] {
        defer { cards = [] }
        return cards
    }

    private func use(_ app: HearthApp) {
        if !usedApps.contains(app) { usedApps.append(app) }
    }

    // MARK: The tools on offer

    private lazy var all: [EmberToolSpec] = makeTools()

    /// Tools for these domains that the person allows (What Ember Knows). The general tools
    /// (remember, forget, open an app) are offered only when the question asks for them: offered
    /// every turn, the small model reached for "open Hearken" when asked for restaurants.
    func tools(for domains: Set<EmberDomain>, question: String? = nil) -> [EmberToolSpec] {
        if let question { self.question = question }
        let text = (question ?? "").lowercased()
        return all.filter { spec in
            guard spec.app.map({ EmberSettings.shared.canRead($0) }) ?? true else { return false }
            if !spec.domains.isDisjoint(with: domains.subtracting([.general])) { return true }
            guard spec.domains.contains(.general) else { return false }
            guard question != nil else { return true }
            switch spec.name {
            case "remember": return text.contains("remember") || text.contains("don't forget") || text.contains("note that")
            case "forget": return text.contains("forget")
            case "open_app": return text.contains("open ") || text.contains("take me to")
            case "household_people": return domains.contains(.general)
            default: return false
            }
        }
    }

    var allowedTools: [EmberToolSpec] { tools(for: Set(EmberDomain.allCases)) }

    /// Runs a tool Claude asked for. Only tools offered this turn run.
    func run(_ name: String, input: [String: EmberJSON], offered: [String]) async -> String {
        guard offered.contains(name), let spec = all.first(where: { $0.name == name }) else { return "That tool isn't available." }
        return await spec.run(EmberArgs(values: input))
    }

    // MARK: Definitions

    private func makeTools() -> [EmberToolSpec] {
        let rangeHelp = "When, in their words: \"this week\", \"last month\", \"since the 1st\", \"in September\", \"October 5 to 12\", \"yesterday\"."
        return [
            // General
            EmberToolSpec(name: "household_people", description: "Lists who is in the household: names, roles (parent, adult, kid) and ages, and who is asking.",
                          domains: [.general, .family]) { [unowned self] _ in householdPeople() },
            EmberToolSpec(name: "remember", description: "Saves something they asked Ember to remember about them or their family (a preference, their usual store, what to call someone). Only when they ask.",
                          domains: [.general], params: [.text("fact", "What to remember, in their words, as a short statement.")]) { [unowned self] args in
                remember(args.text("fact"))
            },
            EmberToolSpec(name: "forget", description: "Removes something Ember was asked to remember.",
                          domains: [.general], params: [.text("fact", "What to forget, in their words.")]) { [unowned self] args in
                forget(args.text("fact"))
            },
            EmberToolSpec(name: "open_app", description: "Adds a button that opens a Hearth app at the right screen, for changes too detailed to do by voice (editing a recipe, rearranging the meal plan).",
                          domains: [.general],
                          params: [.choice("place", "Where to go", ["meal_plan", "grocery_list", "budget", "chores", "calendar", "reading", "food_log"])]) { [unowned self] args in
                openApp(args.text("place"))
            },

            // Money (Suffice)
            EmberToolSpec(name: "spending", description: "How much was spent in a period, overall or in one budget, at one place, or by one person, with the period before for comparison. Use for any \"how much did we spend\" question.",
                          domains: [.money], params: [
                            .text("range", rangeHelp + " Default this week.", optional: true),
                            .text("budget", "A budget name, like groceries or eating out, or empty for all.", optional: true),
                            .text("place", "A store or place, like Costco, or empty.", optional: true),
                            .text("person", "Whose spending, or empty for everyone.", optional: true),
                          ], app: .suffice) { [unowned self] args in
                await money { ledger in
                    EmberSkills.spending(ledger, range: self.when(args.text("range")), budget: args.text("budget"), place: args.text("place"), person: args.text("person"))
                }
            },
            EmberToolSpec(name: "budgets", description: "How the month's budgets stand: left, spent and planned, for all budgets or one, with days left in the month.",
                          domains: [.money], params: [
                            .text("budget", "A budget name, or empty for all of them.", optional: true),
                            .text("month", "Which month, like \"this month\" or \"September\". Default this month.", optional: true),
                          ], app: .suffice) { [unowned self] args in
                await money { ledger in EmberSkills.budgets(ledger, budget: args.text("budget"), month: self.when(args.text("month"))) }
            },
            EmberToolSpec(name: "bills", description: "Bills coming due and any that are late, with amounts and whether each is paid.",
                          domains: [.money], params: [.text("range", "When: \"this week\", \"next 30 days\". Default the next 14 days.", optional: true)],
                          app: .suffice) { [unowned self] args in
                await money { ledger in EmberSkills.bills(ledger, range: self.when(args.text("range"))) }
            },
            EmberToolSpec(name: "purchases", description: "The individual purchases in a period, newest first, optionally at one place or in one budget. Use when they ask what they bought or spent it on.",
                          domains: [.money], params: [
                            .text("range", rangeHelp + " Default the last 7 days.", optional: true),
                            .text("place", "A store or place, or empty.", optional: true),
                            .text("budget", "A budget name, or empty.", optional: true),
                          ], app: .suffice) { [unowned self] args in
                await money { ledger in EmberSkills.recent(ledger, range: self.when(args.text("range")), place: args.text("place"), budget: args.text("budget")) }
            },
            EmberToolSpec(name: "log_spending", description: "Logs a purchase in Suffice. It waits for them to confirm before anything changes.",
                          domains: [.money], params: [
                            .number("amount", "How much, in dollars, like 12.50."),
                            .text("place", "Where, like Target."),
                            .text("budget", "Which budget, or empty to use the one that place always goes to.", optional: true),
                            .text("date", "When, if not today, like \"yesterday\".", optional: true),
                          ], app: .suffice) { [unowned self] args in
                await logSpending(amount: args.number("amount"), place: args.text("place"), budget: args.text("budget"), date: args.text("date"))
            },
            EmberToolSpec(name: "mark_bill_paid", description: "Marks the next unpaid due date of a bill as paid in Suffice, for its usual amount. Waits for them to confirm.",
                          domains: [.money], params: [.text("bill", "The bill's name, like rent or Netflix.")], app: .suffice) { [unowned self] args in
                await markBillPaid(args.text("bill"))
            },

            // Meals and groceries (BigTable)
            EmberToolSpec(name: "meals_planned", description: "What BigTable has planned for breakfast, lunch or dinner on a day or a week, and who isn't eating.",
                          domains: [.meals], params: [
                            .text("days", "Which days: \"today\", \"tomorrow\", \"this week\", \"next week\", \"Saturday\".", optional: true),
                            .choice("meal", "The meal they asked about, or all", ["breakfast", "lunch", "dinner", "all"], optional: true),
                          ], app: .bigtable) { [unowned self] args in
                mealsPlanned(days: args.text("days"), meal: args.text("meal"))
            },
            EmberToolSpec(name: "meal_fits_household", description: "Checks whether a planned meal fits everyone's food allergies. Use before suggesting a planned meal.",
                          domains: [.meals], params: [
                            .text("day", "The day, like today or Saturday.", optional: true),
                            .choice("meal", "The meal", ["breakfast", "lunch", "dinner"], optional: true),
                          ], app: .bigtable) { [unowned self] args in
                mealFits(day: args.text("day"), meal: args.text("meal"))
            },
            EmberToolSpec(name: "meal_times", description: "When the family eats breakfast, lunch and dinner.", domains: [.meals, .family]) { [unowned self] _ in mealTimes() },
            EmberToolSpec(name: "grocery_list", description: "What's on BigTable's grocery list: everything still to buy, or whether one thing is on it.",
                          domains: [.meals], params: [.text("item", "One item to look for, like milk, or empty for the whole list.", optional: true)],
                          app: .bigtable) { [unowned self] args in
                await groceryList(item: args.text("item"))
            },
            EmberToolSpec(name: "add_groceries", description: "Adds items to BigTable's grocery list right away (they can undo).",
                          domains: [.meals], params: [.text("items", "The items, comma separated, with amounts if said: \"milk, 2 dozen eggs, bananas\".")],
                          app: .bigtable) { [unowned self] args in
                await addGroceries(args.text("items"))
            },
            EmberToolSpec(name: "check_off_groceries", description: "Checks items off BigTable's grocery list (they got them). They can undo.",
                          domains: [.meals], params: [.text("items", "The items they got, comma separated.")], app: .bigtable) { [unowned self] args in
                await checkOffGroceries(args.text("items"))
            },

            // Family (Caloma)
            EmberToolSpec(name: "chores", description: "Who has which chores on a day in Caloma and which are done.",
                          domains: [.family], params: [
                            .text("day", "Which day, like today or yesterday. Default today.", optional: true),
                            .text("person", "One person, or empty for everyone.", optional: true),
                          ], app: .caloma) { [unowned self] args in
                await family { EmberSkills.chores($0, day: args.text("day"), person: args.text("person")) }
            },
            EmberToolSpec(name: "chores_waiting", description: "Chores the kids marked done that are waiting for a parent's OK in Caloma.",
                          domains: [.family], app: .caloma) { [unowned self] _ in
                await family { EmberSkills.approvals($0) }
            },
            EmberToolSpec(name: "approve_chores", description: "Approves chores waiting for a parent's OK (the kids get their points). Waits for them to confirm.",
                          domains: [.family], params: [
                            .text("person", "Only this kid's, or empty for all.", optional: true),
                            .text("chore", "Only this chore, or empty for all.", optional: true),
                          ], app: .caloma) { [unowned self] args in
                await approveChores(person: args.text("person"), chore: args.text("chore"))
            },
            EmberToolSpec(name: "mark_chore_done", description: "Marks someone's chore done for today in Caloma, approved (a parent saying so). They can undo.",
                          domains: [.family], params: [
                            .text("chore", "The chore, like trash or dishes."),
                            .text("person", "Whose chore, or empty if only one person has it.", optional: true),
                          ], app: .caloma) { [unowned self] args in
                await markChoreDone(chore: args.text("chore"), person: args.text("person"))
            },
            EmberToolSpec(name: "family_calendar", description: "What's on the family calendar in Caloma: practices, games, appointments, who's going and who's driving.",
                          domains: [.family], params: [
                            .text("range", "When: today, tomorrow, this weekend, next week, Saturday. Default today.", optional: true),
                            .text("person", "One person, or empty for everyone.", optional: true),
                          ], app: .caloma) { [unowned self] args in
                await family { EmberSkills.calendar($0, range: args.text("range"), person: args.text("person")) }
            },
            EmberToolSpec(name: "add_family_event", description: "Adds an event to the family calendar in Caloma. Waits for them to confirm.",
                          domains: [.family], params: [
                            .text("title", "What it is, like \"Soccer practice\"."),
                            .text("when", "When it starts, in their words: \"Saturday at 9am\", \"tomorrow 4:30pm\", \"October 30\"."),
                            .number("minutes", "How long, in minutes. Default 60.", optional: true),
                            .text("location", "Where, or empty.", optional: true),
                            .text("who", "Who's going, comma separated, or empty for everyone.", optional: true),
                          ], app: .caloma) { [unowned self] args in
                await addFamilyEvent(title: args.text("title"), when: args.text("when"), minutes: args.number("minutes"),
                                     location: args.text("location"), who: args.text("who"))
            },
            EmberToolSpec(name: "allowance_recent", description: "The allowance Caloma paid each kid in the last 30 days.",
                          domains: [.family, .money], app: .caloma) { [unowned self] _ in allowanceRecent() },

            // Food (Sated)
            EmberToolSpec(name: "food_log", description: "What was eaten and how it compares to the goals in Sated: calories, protein, carbs and fat left today, a day's meals, or a week's average.",
                          domains: [.food], params: [.text("day", "Which day or range: today, yesterday, this week. Default today.", optional: true)],
                          app: .sated) { [unowned self] args in
                foodLog(day: args.text("day"))
            },
            EmberToolSpec(name: "log_food", description: "Opens Sated's Add Food to log something they ate (Sated finds the nutrition).",
                          domains: [.food], params: [.text("food", "What they ate, in their words.", optional: true)], app: .sated) { [unowned self] args in
                logFood(args.text("food"))
            },

            // Study (Hearken)
            EmberToolSpec(name: "study_today", description: "Today's scripture reading from Hearken and whether it's done.",
                          domains: [.study], app: .hearken) { [unowned self] _ in studyToday() },

            // Phone
            EmberToolSpec(name: "find_places", description: "Finds restaurants, stores or any kind of place near them (or in a town they name) on Apple Maps, closest first, with buttons for directions and calling. Use for \"find\", \"where's a good…\", \"anything nearby\".",
                          domains: [.places], params: [
                            .text("query", "What to look for, in their words: \"good restaurants\", \"coffee\", \"a pharmacy\", \"Mexican food\"."),
                            .text("near", "The town or area they named, or empty for near them.", optional: true),
                          ]) { [unowned self] args in
                await findPlaces(args.text("query"), near: args.text("near"))
            },
            EmberToolSpec(name: "place_call", description: "Calls a person from Contacts or a business from Apple Maps near them (a named town means the nearest town by that name). One match: the call screen opens and they tap Call. Several: it lists them so you can ask which.",
                          domains: [.phone], params: [
                            .text("who", "Who to call: a person or a business, as they said it."),
                            .text("near", "Only a town they said out loud for a business (\"the Costco in Orem\"). Empty for people and when they named no town.", optional: true),
                            .text("which", "Only after you asked which of several: their answer, like a street or \"the closest\". Otherwise empty.", optional: true),
                          ]) { [unowned self] args in
                await placeCall(who: args.text("who"), near: args.text("near"), which: args.text("which"))
            },
            EmberToolSpec(name: "send_text", description: "Writes a text to someone in Contacts and opens Messages with it filled in; they tap Send.",
                          domains: [.phone], params: [
                            .text("to", "Who it's for, as they said it."),
                            .text("message", "The message, in the person's own voice, first person."),
                          ]) { [unowned self] args in
                await compose(.message, to: args.text("to"), subject: "", body: args.text("message"))
            },
            EmberToolSpec(name: "draft_email", description: "Drafts an email to someone in Contacts and opens it ready to send; they tap Send.",
                          domains: [.phone], params: [
                            .text("to", "Who it's for, as they said it."),
                            .text("subject", "A short subject line."),
                            .text("body", "The email, in the person's own voice, with a greeting and sign-off."),
                          ]) { [unowned self] args in
                await compose(.mail, to: args.text("to"), subject: args.text("subject"), body: args.text("body"))
            },
            EmberToolSpec(name: "add_reminder", description: "Adds a reminder to their Reminders, at a time if given. Done right away; they can undo.",
                          domains: [.phone], params: [
                            .text("title", "What to remember."),
                            .text("when", "When to remind them, like \"tomorrow at 8am\" or \"in 2 hours\", or empty.", optional: true),
                          ]) { [unowned self] args in
                await addReminder(title: args.text("title"), when: args.text("when"))
            },
            EmberToolSpec(name: "set_timer", description: "Starts a timer that rings even if Ember is closed. They can undo.",
                          domains: [.phone, .meals], params: [
                            .number("minutes", "How long, in minutes (1.5 for 90 seconds)."),
                            .text("label", "What it's for, like \"pasta\", or empty.", optional: true),
                          ]) { [unowned self] args in
                await setTimer(minutes: args.number("minutes"), label: args.text("label"))
            },
            EmberToolSpec(name: "set_alarm", description: "Sets an alarm at a time. They can undo.",
                          domains: [.phone], params: [
                            .text("when", "When, like \"6:30am\" or \"tomorrow at 7\"."),
                            .text("label", "What it's for, or empty.", optional: true),
                          ]) { [unowned self] args in
                await setAlarm(when: args.text("when"), label: args.text("label"))
            },
            EmberToolSpec(name: "my_calendar", description: "What's on their own calendars (work, personal; not the family calendar in Caloma) in a range.",
                          domains: [.phone], params: [.text("range", "When: today, tomorrow, this week. Default today.", optional: true)]) { [unowned self] args in
                await myCalendar(range: args.text("range"))
            },
            EmberToolSpec(name: "add_my_event", description: "Adds an event to their own calendar (not the family's). Waits for them to confirm.",
                          domains: [.phone], params: [
                            .text("title", "What it is."),
                            .text("when", "When it starts, in their words."),
                            .number("minutes", "How long, in minutes. Default 60.", optional: true),
                            .text("location", "Where, or empty.", optional: true),
                          ]) { [unowned self] args in
                await addMyEvent(title: args.text("title"), when: args.text("when"), minutes: args.number("minutes"), location: args.text("location"))
            },
            EmberToolSpec(name: "directions", description: "Opens Apple Maps with directions to a place near them.",
                          domains: [.phone, .places], params: [.text("place", "Where to, as they said it.")]) { [unowned self] args in
                await directions(args.text("place"))
            },
        ]
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

    // MARK: Money

    private func money(_ answer: (SufficeLedger) -> EmberAnswer) async -> String {
        switch await data.ledger() {
        case .success(let ledger) where !ledger.isEmpty:
            use(.suffice)
            let result = answer(ledger)
            show(result, app: .suffice, link: URL(string: "suffice://budget"), action: "Open in Suffice")
            return result.facts + Self.freshness(data.budget.lastFetched)
        case .success:
            return fallbackBudget() ?? "Suffice's budget in iCloud is empty. If they use Suffice, opening it once while signed in to iCloud shares it."
        case .failure(let error):
            return fallbackBudget().map { $0 + "\n(Only the grocery budget is available: " + EmberData.explain(error, app: .suffice) + ")" }
                ?? EmberData.explain(error, app: .suffice)
        }
    }

    /// The grocery budget Suffice publishes on this iPhone, when iCloud can't be reached.
    private func fallbackBudget() -> String? {
        guard let budget = context.groceryBudget?.value else { return nil }
        use(.suffice)
        let left = EmberMoney.text(budget.leftCents, code: budget.currencyCode)
        let limit = EmberMoney.text(budget.limitCents, code: budget.currencyCode)
        let spent = EmberMoney.text(budget.spentCents, code: budget.currencyCode)
        show(EmberAnswer(facts: "", title: budget.name, value: left, subtitle: "left of \(limit)",
                         fraction: budget.limitCents > 0 ? Double(budget.spentCents) / Double(budget.limitCents) : nil),
             app: .suffice, link: budget.link.flatMap(URL.init(string:)), action: "Open in Suffice")
        return "\(budget.name) this month: \(left) left of \(limit) (\(spent) spent)."
    }

    private func logSpending(amount: Double?, place: String, budget: String, date: String) async -> String {
        guard let amount, amount > 0 else { return "Ask how much it was." }
        guard !place.isEmpty else { return "Ask where they spent it." }
        guard case .success(let ledger) = await data.ledger(), !ledger.categories.isEmpty else {
            return "Suffice's budget isn't in iCloud yet, so Ember can't log it. Offer to open Suffice."
        }
        let cents = Int((amount * 100).rounded())
        let category = budget.isEmpty ? ledger.category(ledger.ruleCategory(for: place)) : ledger.findCategory(budget)
        guard let category else {
            let names = ledger.categories.filter { !$0.isArchived && $0.parentID == nil }.map(\.name)
            return "Ask which budget it's for. Suffice's budgets: \(names.joined(separator: ", "))."
        }
        let day = date.isEmpty ? Date.now : (EmberDates.moment(date, lean: .past) ?? EmberDates.range(date, lean: .past).start)
        let member = ledger.member(named: context.me?.name)
        let month = Calendar.current.dateInterval(of: .month, for: day).map { EmberRange(start: $0.start, end: $0.end) }
        let left = month.flatMap { month in
            ledger.statuses(in: month).flatMap { [$0] + $0.children }.first { $0.category.id == category.id }?.leftCents
        }
        let title = "Log \(EmberMoney.exact(cents)) at \(place)"
        let detail = "\(category.name) · \(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.wide).month().day()))"
        let zone = data.budget
        let id = actions.propose(title) {
            let record = SufficeLedger.newExpense(in: zone, payee: place, amountCents: cents, categoryID: category.id, memberID: member?.id, date: day)
            try await zone.save([record])
            let name = record.recordID.recordName
            var spoken = "Logged \(EmberMoney.exact(cents)) at \(place) in \(category.name)."
            if let left { spoken += left - cents >= 0 ? " \(EmberMoney.text(left - cents)) left there this month." : " That's \(EmberMoney.text(cents - left)) over this month." }
            return (spoken, EmberActions.Undo(title: title) { try await zone.save([], deleting: [name]) })
        }
        use(.suffice)
        cards.append(EmberCard(app: .suffice, kind: .action(id: id, title: title, detail: detail, symbol: "creditcard")))
        var facts = "Ready to log \(EmberMoney.exact(cents)) at \(place) in \(category.name), \(detail.components(separatedBy: " · ").last ?? "today"). Nothing is logged yet: ask them to confirm in a few words."
        if let left { facts += " \(category.name) has \(EmberMoney.text(left)) left this month before this." }
        return facts
    }

    private func markBillPaid(_ name: String) async -> String {
        guard case .success(let ledger) = await data.ledger(), !ledger.bills.isEmpty else { return "Suffice has no bills in iCloud yet." }
        guard let bill = ledger.findBill(name) else {
            return "Suffice has no bill called \"\(name)\". Its bills: \(ledger.bills.filter(\.isActive).map(\.name).joined(separator: ", "))."
        }
        let today = Calendar.current.startOfDay(for: .now)
        let window = EmberRange(start: today, end: Calendar.current.date(byAdding: .day, value: 31, to: today)!)
        guard let due = ledger.dues(in: window).first(where: { $0.bill.id == bill.id && !$0.isPaid }) else {
            return "\(bill.name) has nothing due right now."
        }
        let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
        let paidOn = due.date < monthAgo ? due.date : Date.now
        let member = ledger.member(named: context.me?.name)
        let title = "Mark \(bill.name) paid"
        let detail = "\(EmberMoney.exact(bill.amountCents)) · due \(due.date.formatted(.dateTime.month().day()))"
        let zone = data.budget
        let id = actions.propose(title) {
            let record = SufficeLedger.newExpense(in: zone, payee: bill.name, amountCents: bill.amountCents, categoryID: bill.categoryID,
                                                  memberID: member?.id, date: paidOn, billID: bill.id,
                                                  billDueDate: Calendar.current.startOfDay(for: due.date))
            try await zone.save([record])
            let name = record.recordID.recordName
            return ("Marked \(bill.name) paid, \(EmberMoney.exact(bill.amountCents)) for \(due.date.formatted(.dateTime.month(.wide).day())).",
                    EmberActions.Undo(title: title) { try await zone.save([], deleting: [name]) })
        }
        use(.suffice)
        cards.append(EmberCard(app: .suffice, kind: .action(id: id, title: title, detail: detail, symbol: "checkmark.seal")))
        return "Ready to mark \(bill.name) paid: \(EmberMoney.exact(bill.amountCents)) for the \(due.date.formatted(.dateTime.month(.wide).day())) due date. Nothing changed yet: ask them to confirm."
    }

    // MARK: Meals (BigTable)

    func mealsPlanned(days: String, meal: String) -> String {
        guard let plan = context.mealPlan?.value else {
            return "BigTable hasn't shared a meal plan on this iPhone. Opening BigTable once shares it."
        }
        use(.bigtable)
        let range = EmberDates.range(days, lean: .future, fallback: "today")
        let dates = (0..<min(range.days, 14)).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: range.start) }
        let slots = ["breakfast", "lunch", "dinner"].filter { meal.isEmpty || meal == "all" || meal == $0 }
        var lines: [String] = []
        for date in dates {
            let label = Self.dayLabel(date)
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
        let cardSlot = slots.count == 1 ? slots[0] : "dinner"
        if dates.count == 1, let planned = plan.meal(cardSlot, on: dates[0]) {
            cards.append(EmberCard(
                app: .bigtable,
                kind: .meal(title: planned.title, detail: "\(Self.dayLabel(dates[0])) · \(cardSlot.capitalized)",
                            imageURL: planned.imageURL.flatMap(URL.init(string:)), fitsEveryone: nil),
                link: planned.link.flatMap(URL.init(string:)) ?? URL(string: "bigtable://plan"),
                actionTitle: "Open in BigTable"
            ))
        }
        return lines.joined(separator: "\n") + Self.freshness(context.mealPlan?.updatedAt)
    }

    /// Checks a planned meal's ingredients against everyone's allergies, here. Only the verdict
    /// leaves the device.
    func mealFits(day: String, meal: String) -> String {
        guard let plan = context.mealPlan?.value else { return "No meal plan on this iPhone." }
        let date = EmberDates.range(day, lean: .future, fallback: "today").start
        let slot = ["breakfast", "lunch", "dinner"].contains(meal) ? meal : "dinner"
        guard let planned = plan.meal(slot, on: date) else { return "Nothing is planned for that meal." }
        use(.bigtable)
        let ingredients = (planned.recipes ?? []).flatMap(\.ingredients).map { $0.name.lowercased() }
        guard !ingredients.isEmpty else {
            return "\(planned.title): BigTable hasn't shared its ingredients, so Ember can't check allergies. BigTable checks them when it plans."
        }
        let conflicts = context.people.filter { person in person.allergies.contains { Self.matches($0, in: ingredients) } }.map(\.name)
        let fits = conflicts.isEmpty
        cards.append(EmberCard(
            app: .bigtable,
            kind: .meal(title: planned.title, detail: "\(Self.dayLabel(date)) · \(slot.capitalized)",
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
        func time(_ slot: String) -> String { times.start(for: slot, on: .now).formatted(date: .omitted, time: .shortened) }
        return "Breakfast \(time("breakfast")), lunch \(time("lunch")), dinner \(time("dinner"))."
    }

    private func groceryList(item: String) async -> String {
        switch await data.groceries() {
        case .success(let list) where list.activeRecordName != nil:
            use(.bigtable)
            let answer = EmberSkills.groceries(list, item: item)
            show(answer, app: .bigtable, link: URL(string: "bigtable://grocery"), action: "Open List")
            return answer.facts
        case .success, .failure:
            // The counts BigTable publishes here, when the kitchen can't be read.
            guard let list = context.groceries?.value.list else { return "There's no grocery list in BigTable right now." }
            use(.bigtable)
            return "\(list.remainingCount) of \(list.itemCount) items still to buy. (Only the counts are available right now, not the items.)"
        }
    }

    private static func splitItems(_ text: String) -> [(name: String, quantity: String)] {
        text.replacingOccurrences(of: " and ", with: ", ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { phrase in
                // "2 dozen eggs" → ("eggs", "2 dozen"); "a gallon of milk" → ("milk", "a gallon")
                let words = phrase.split(separator: " ").map(String.init)
                let units = ["dozen", "gallon", "gallons", "lb", "lbs", "pound", "pounds", "bag", "bags", "box", "boxes", "pack", "packs",
                             "bottle", "bottles", "can", "cans", "jar", "jars", "loaf", "loaves", "bunch", "bunches", "carton", "cartons"]
                var count = 0
                if let first = words.first, Double(first) != nil || ["a", "an", "one", "two", "three", "four", "five", "six"].contains(first.lowercased()) { count = 1 }
                if count == 1, words.count > 2, units.contains(words[1].lowercased()) { count = 2 }
                if count < words.count, words.count > count, words[count].lowercased() == "of" { count += 1 }
                guard count > 0, count < words.count else { return (phrase, "") }
                let quantity = words.prefix(count).filter { $0.lowercased() != "of" }.joined(separator: " ")
                return (words.dropFirst(count).joined(separator: " "), ["a", "an"].contains(quantity.lowercased()) ? "1" : quantity)
            }
    }

    private func addGroceries(_ text: String) async -> String {
        let items = Self.splitItems(text)
        guard !items.isEmpty else { return "Ask what to add." }
        guard case .success(let list) = await data.groceries(), list.activeRecordName != nil else {
            cards.append(EmberCard(app: .bigtable, kind: .handoff(title: "Grocery list", detail: "Add items in BigTable", symbol: "cart"),
                                   link: URL(string: "bigtable://grocery"), actionTitle: "Open BigTable"))
            return "There's no grocery list in BigTable's kitchen to add to yet. A button to open BigTable is ready; say so."
        }
        let names = items.map(\.name)
        let title = "Add \(names.formatted(.list(type: .and))) to the grocery list"
        let zone = data.kitchen
        let active = list.activeRecordName
        let before = Set(list.lines.map(\.id))
        let (id, spoken) = await actions.perform(title) {
            guard let record = BigTableGroceries.adding(items, in: zone, activeRecordName: active) else {
                throw EmberActionError("the grocery list changed; try again")
            }
            try await zone.save([record])
            let added = Set(BigTableGroceries(records: Array(zone.records.values)).lines.map(\.id)).subtracting(before)
            return ("Added \(names.formatted(.list(type: .and))) to the list.", EmberActions.Undo(title: title) {
                guard let undo = BigTableGroceries.removing(added, in: zone, activeRecordName: active) else { return }
                try await zone.save([undo])
            })
        }
        use(.bigtable)
        cards.append(EmberCard(app: .bigtable, kind: .action(id: id, title: "Grocery list", detail: names.joined(separator: ", "), symbol: "cart.badge.plus"),
                               link: URL(string: "bigtable://grocery"), actionTitle: "Open List"))
        return spoken
    }

    private func checkOffGroceries(_ text: String) async -> String {
        let names = Self.splitItems(text).map(\.name)
        guard case .success(let list) = await data.groceries(), list.activeRecordName != nil else { return "There's no grocery list in BigTable right now." }
        var ids: [String] = []
        var found: [String] = []
        var missing: [String] = []
        for name in names {
            let lines = list.matching(name).filter { !$0.isChecked }
            if lines.isEmpty { missing.append(name) } else { ids += lines.map(\.id); found += lines.map(\.name) }
        }
        guard !ids.isEmpty else { return "\(names.formatted(.list(type: .and))) \(names.count == 1 ? "isn't" : "aren't") on the list still to buy." }
        let title = "Check off \(found.formatted(.list(type: .and)))"
        let zone = data.kitchen
        let active = list.activeRecordName
        let (id, spoken) = await actions.perform(title) {
            guard let record = BigTableGroceries.checking(ids, checked: true, in: zone, activeRecordName: active) else {
                throw EmberActionError("the grocery list changed; try again")
            }
            try await zone.save([record])
            return ("Checked off \(found.formatted(.list(type: .and))).", EmberActions.Undo(title: title) {
                guard let undo = BigTableGroceries.checking(ids, checked: false, in: zone, activeRecordName: active) else { return }
                try await zone.save([undo])
            })
        }
        use(.bigtable)
        cards.append(EmberCard(app: .bigtable, kind: .action(id: id, title: "Grocery list", detail: "Got " + found.joined(separator: ", "), symbol: "checkmark.circle"),
                               link: URL(string: "bigtable://grocery"), actionTitle: "Open List"))
        return spoken + (missing.isEmpty ? "" : " \(missing.formatted(.list(type: .and))) wasn't on the list.")
    }

    // MARK: Family (Caloma)

    /// Why Caloma's data couldn't be used: iCloud's own reason when it failed.
    private static func reason(_ result: Result<CalomaFamily, EmberZoneError>, fallback: String) -> String {
        if case .failure(let error) = result { return EmberData.explain(error, app: .caloma) }
        return fallback
    }

    private func family(_ answer: (CalomaFamily) -> EmberAnswer) async -> String {
        switch await data.familyBoard() {
        case .success(let family) where !family.isEmpty:
            use(.caloma)
            let result = answer(family)
            show(result, app: .caloma, link: URL(string: "caloma://"), action: "Open Caloma")
            return result.facts + Self.freshness(data.family.lastFetched)
        case .success:
            return "Caloma's family is empty in iCloud. If they use Caloma, opening it once while signed in to iCloud shares it."
        case .failure(let error):
            return EmberData.explain(error, app: .caloma)
        }
    }

    private func approveChores(person: String, chore: String) async -> String {
        let loaded = await data.familyBoard()
        guard case .success(let family) = loaded else { return Self.reason(loaded, fallback: "Caloma's family isn't in iCloud yet.") }
        var waiting = family.waitingForApproval
        if !person.isEmpty, let member = family.findMember(person) { waiting = waiting.filter { $0.memberID == member.id } }
        if !chore.isEmpty, let match = family.findChore(chore) { waiting = waiting.filter { $0.choreID == match.id } }
        guard !waiting.isEmpty else { return "Nothing matching is waiting for a parent's OK." }
        let lines = waiting.map { completion in
            "\(family.chores.first { $0.id == completion.choreID }?.title ?? "Chore") (\(family.name(completion.memberID)))"
        }
        let title = waiting.count == 1 ? "Approve \(lines[0])" : "Approve \(waiting.count) chores"
        let zone = data.family
        let id = actions.propose(title) {
            var records: [CKRecord] = []
            for completion in waiting {
                if let more = CalomaFamily.approveRecords(completion, family: family, in: zone) { records += more }
            }
            guard !records.isEmpty else { throw EmberActionError("they were already reviewed") }
            try await zone.save(records)
            return ("Approved \(waiting.count == 1 ? lines[0] : "\(waiting.count) chores"). Points are in.", nil)
        }
        use(.caloma)
        cards.append(EmberCard(app: .caloma, kind: .action(id: id, title: title, detail: lines.joined(separator: ", "), symbol: "checkmark.seal")))
        return "Ready to approve: \(lines.joined(separator: "; ")). Nothing changed yet: ask them to confirm."
    }

    private func markChoreDone(chore: String, person: String) async -> String {
        let loaded = await data.familyBoard()
        guard case .success(let family) = loaded else { return Self.reason(loaded, fallback: "Caloma's family isn't in iCloud yet.") }
        let board = family.board(on: .now).filter { $0.status == .open }
        var items = chore.isEmpty ? board : board.filter { SufficeLedger.fold($0.chore.title).contains(SufficeLedger.fold(chore)) || SufficeLedger.fold(chore).contains(SufficeLedger.fold($0.chore.title)) }
        if !person.isEmpty, let member = family.findMember(person) {
            items = items.filter { $0.memberID == member.id || ($0.chore.upForGrabs && $0.memberID == nil) }
        }
        guard let item = items.first else { return "No open chore like \"\(chore)\" on today's board\(person.isEmpty ? "" : " for \(person)")." }
        if items.count > 1, person.isEmpty, Set(items.compactMap(\.memberID)).count > 1 {
            asksToChoose = true
            return "\(item.chore.title) is on the board for \(items.compactMap(\.memberID).map { family.name($0) }.formatted(.list(type: .or))). Ask whose."
        }
        guard let memberID = item.memberID ?? family.findMember(person)?.id ?? item.chore.assigneeIDs.first else { return "Ask who did it." }
        let who = family.name(memberID)
        let title = "\(item.chore.title) done for \(who)"
        let zone = data.family
        let (id, spoken) = await actions.perform(title) {
            let records = CalomaFamily.markDoneRecords(item, for: memberID, family: family, in: zone)
            try await zone.save(records)
            let names = records.map(\.recordID.recordName)
            return ("Marked \(item.chore.title) done for \(who).", EmberActions.Undo(title: title) { try await zone.save([], deleting: names) })
        }
        use(.caloma)
        cards.append(EmberCard(app: .caloma, kind: .action(id: id, title: title, detail: "\(item.chore.points) points", symbol: "checkmark.circle")))
        return spoken
    }

    private func addFamilyEvent(title: String, when: String, minutes: Double?, location: String, who: String) async -> String {
        guard !title.isEmpty else { return "Ask what the event is." }
        guard let start = EmberDates.moment(when) else { return "Ask when it is." }
        let loaded = await data.familyBoard()
        guard case .success(let family) = loaded else { return Self.reason(loaded, fallback: "Caloma's family calendar isn't in iCloud yet.") }
        let hasTime = when.rangeOfCharacter(from: .decimalDigits) != nil || ["noon", "morning", "evening", "afternoon", "tonight"].contains { when.lowercased().contains($0) }
        let isAllDay = !hasTime
        let end = isAllDay ? (Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start) : start.addingTimeInterval((minutes ?? 60) * 60)
        let attendees = who.split(separator: ",").compactMap { family.findMember(String($0)) }
        let whenText = isAllDay ? start.formatted(.dateTime.weekday(.wide).month().day()) : start.formatted(.dateTime.weekday(.wide).month().day().hour().minute())
        let clash = family.occurrences(in: EmberRange(start: start, end: end)).filter { !$0.event.isAllDay }
        let detail = [whenText, location, attendees.map(\.name).joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · ")
        let zone = data.family
        let id = actions.propose("Add \(title)") {
            let record = CalomaFamily.newEventRecord(title: title, start: start, end: end, isAllDay: isAllDay, location: location,
                                                     notes: "", attendeeIDs: attendees.map(\.id), in: zone)
            try await zone.save([record])
            let name = record.recordID.recordName
            return ("Added \(title) to the family calendar, \(whenText).", EmberActions.Undo(title: "Add \(title)") { try await zone.save([], deleting: [name]) })
        }
        use(.caloma)
        cards.append(EmberCard(app: .caloma, kind: .action(id: id, title: title, detail: detail, symbol: "calendar.badge.plus")))
        var facts = "Ready to add \(title) to the family calendar: \(detail). Nothing added yet: ask them to confirm."
        if !clash.isEmpty { facts += " It overlaps \(clash.map(\.event.title).formatted(.list(type: .and))); mention it." }
        return facts
    }

    func allowanceRecent() -> String {
        guard let allowance = context.allowance?.value else { return "Caloma hasn't shared allowance on this iPhone." }
        use(.caloma)
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let recent = allowance.payouts.filter { $0.date >= cutoff }
        guard !recent.isEmpty else { return "No allowance paid in the last 30 days." }
        let byKid = Dictionary(grouping: recent, by: \.name).map { name, payouts in
            "\(name): \(EmberMoney.text(payouts.reduce(0) { $0 + $1.cents }, code: allowance.currencyCode))"
        }.sorted()
        cards.append(EmberCard(app: .caloma, kind: .allowance(byKid), link: URL(string: "caloma://"), actionTitle: "Open Caloma"))
        return "Allowance paid in the last 30 days: " + byKid.joined(separator: "; ")
    }

    // MARK: Food (Sated)

    private func foodLog(day: String) -> String {
        guard let log = context.foodLog?.value else {
            return "Sated hasn't shared a food log on this iPhone yet. Opening Sated once (after its update) shares it."
        }
        use(.sated)
        let answer = EmberSkills.food(log, day: day)
        show(answer, app: .sated, link: URL(string: "sated://"), action: "Open Sated")
        return answer.facts + Self.freshness(context.foodLog?.updatedAt)
    }

    private func logFood(_ food: String) -> String {
        use(.sated)
        cards.append(EmberCard(app: .sated, kind: .handoff(title: "Log food", detail: food.isEmpty ? "Add it in Sated" : food, symbol: "fork.knife"),
                               link: URL(string: "sated://add"), actionTitle: "Open Sated"))
        return "A button to open Sated's Add Food is ready (Sated works out the nutrition). Say it's ready; it isn't logged yet."
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

    // MARK: Memory

    private func remember(_ fact: String) -> String {
        let fact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return "Ask what to remember." }
        var list = EmberSettings.shared.remembered.filter { $0.caseInsensitiveCompare(fact) != .orderedSame }
        list.append(fact)
        EmberSettings.shared.remembered = Array(list.suffix(30))
        return "Saved on this iPhone: \"\(fact)\". They can see or delete it in What Ember Knows."
    }

    private func forget(_ fact: String) -> String {
        let key = SufficeLedger.fold(fact)
        let before = EmberSettings.shared.remembered
        EmberSettings.shared.remembered = before.filter { item in
            let folded = SufficeLedger.fold(item)
            return !(folded.contains(key) || key.contains(folded))
        }
        return before.count == EmberSettings.shared.remembered.count ? "Nothing like that was saved." : "Forgotten."
    }

    // MARK: Handoffs

    func openApp(_ place: String) -> String {
        let target: (HearthApp, String, String, URL?)? = switch place {
        case "grocery_list": (.bigtable, "Grocery list", "Open the list in BigTable", URL(string: "bigtable://grocery"))
        case "meal_plan": (.bigtable, "Meal plan", "Plan or change a meal in BigTable", URL(string: "bigtable://plan"))
        case "budget": (.suffice, "Budget", "Open your budget in Suffice", URL(string: "suffice://budget"))
        case "chores", "calendar": (.caloma, place == "chores" ? "Chores" : "Family calendar", "Open Caloma", URL(string: "caloma://"))
        case "reading": (.hearken, "Today’s reading", "Open Hearken", URL(string: "hearken://"))
        case "food_log": (.sated, "Food log", "Log it in Sated", URL(string: "sated://add"))
        default: nil
        }
        guard let (app, title, detail, url) = target else { return "Ember can't open that." }
        cards.append(EmberCard(app: app, kind: .handoff(title: title, detail: detail, symbol: "arrow.up.forward.app"),
                               link: url, actionTitle: "Open \(app.displayName)"))
        return "A button to open \(app.displayName) is ready. Say it's ready to open; don't say it's done."
    }

    // MARK: Places

    func findPlaces(_ query: String, near: String) async -> String {
        let near = EmberRequest.appears(near, in: question) ? near : ""
        switch await EmberCallFinder.search(query, near: near) {
        case .success(let places):
            for place in places.prefix(4) {
                cards.append(EmberCard(app: nil, kind: .call(name: place.name, detail: place.detail, logo: place.logo),
                                       link: place.maps, actionTitle: "Directions",
                                       secondaryLink: place.callURL, secondaryTitle: place.callURL == nil ? nil : "Call"))
            }
            let list = places.enumerated().map { index, place in
                "\(index + 1). \(place.name)\(place.category.map { " (\($0))" } ?? "")\(place.street.map { " on \($0)" } ?? "")\(place.miles.map { String(format: ", %.1f miles away", $0) } ?? "")"
            }.joined(separator: "\n")
            return """
            Apple Maps found, closest first:
            \(list)
            The screen shows them with Directions and Call buttons. Name the two or three closest in one or two short sentences. \
            Apple Maps has no ratings, so don't say which is best or invent reviews; if they asked for "good" ones, say these are the closest.
            """
        case .failure(.needsLocation):
            return "Ember needs Location to search near them. Reply in one short sentence: say the town, or allow Location for Ember in Settings."
        case .failure:
            return "Apple Maps found nothing for \(query)\(near.isEmpty ? " nearby" : " in \(near)"). Say so in one short sentence."
        }
    }

    // MARK: Phone

    func placeCall(who: String, near: String, which: String) async -> String {
        // A town only counts if they said it: the model sometimes fills in where they are.
        let near = EmberRequest.appears(near, in: question) ? near : ""
        switch await EmberCallFinder.find(who, near: near, which: which) {
        case .success(.one(let target)):
            cards.append(EmberCard(app: nil, kind: .call(name: target.name, detail: target.detail, logo: target.logo),
                                   link: target.url, actionTitle: "Call", opensWhenSpoken: true))
            return "Found \(target.spoken). The phone's call screen opens as soon as you finish speaking. Reply with exactly this and nothing else: \"Calling \(Self.callName(who: who, target: target)).\""
        case .success(.several(let targets)):
            for target in targets {
                cards.append(EmberCard(app: nil, kind: .call(name: target.name, detail: target.detail, logo: target.logo),
                                       link: target.url, actionTitle: "Call"))
            }
            asksToChoose = true
            let list = targets.enumerated().map { "\($0.offset + 1). \($0.element.spoken)" }.joined(separator: "\n")
            return """
            There are \(targets.count) matches, closest to them first:
            \(list)
            Don't call yet. Ask which one in one short question, naming each by its street (or town). \
            When they answer, use place_call again with the same who and near, and which set to their answer.
            """
        case .failure(.needsLocation):
            return "Ember needs Location to find \(who) nearby. Ask them to say the town, or allow Location for Ember in Settings."
        case .failure(.needsContacts):
            return "Ember isn't allowed to see Contacts. Reply in one short sentence that you need Contacts access to call \(who), which they can allow in Settings › Ember."
        case .failure(.notInContacts) where EmberContactSearch.isLimited && !EmberContactSearch.isRelation(who):
            return "Ember can only see the contacts they chose to share, and \(who) isn't one of them. Reply in one or two short sentences: they can share \(who), or all contacts, in Settings › Apps › Ember › Contacts."
        case .failure(.notInContacts):
            return "Nobody in Contacts is \(who): no contact with that name or nickname, and no related name on their own card. Reply in one or two short sentences: you couldn't find \(who) in Contacts, and adding \(who) as a related name on their own contact card (or giving the contact the nickname \(who)) fixes it."
        case .failure(.nothingFound):
            return "No phone number for \(who)\(near.isEmpty ? "" : " in \(near)") in Contacts or Apple Maps."
        }
    }

    /// How Ember says who it's calling: as they said it for family ("Calling Mom", "Calling your
    /// wife"), the name otherwise.
    static func callName(who: String, target: EmberCallTarget) -> String {
        guard EmberContactSearch.isRelation(who) else { return target.name }
        let trimmed = who.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("my ") { return "your " + trimmed.dropFirst(3) }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private func compose(_ kind: EmberComposeRequest.Kind, to who: String, subject: String, body: String) async -> String {
        guard !body.isEmpty else { return "Ask what to say." }
        let lookup = await EmberContacts.find(who, needs: kind == .message ? \.phones : \.emails)
        switch lookup {
        case .denied:
            return "Ember needs Contacts access to find \(who). Ask them to allow it in Settings › Ember."
        case .none:
            return "No one called \(who) in Contacts with \(kind == .message ? "a phone number" : "an email address")."
        case .several(let people):
            asksToChoose = true
            return "Several people match \(who): \(people.map(\.name).formatted(.list(type: .or))). Ask which one, then try again with their full name."
        case .found(let person):
            let recipient = kind == .message ? person.phones[0] : person.emails[0]
            EmberCompose.shared.queue(EmberComposeRequest(kind: kind, recipients: [recipient], subject: subject, body: body))
            let title = kind == .message ? "Text \(person.name)" : "Email \(person.name)"
            cards.append(EmberCard(app: nil, kind: .handoff(title: title, detail: kind == .message ? "“\(body)”" : subject,
                                                            symbol: kind == .message ? "message" : "envelope")))
            return "The \(kind == .message ? "message" : "email") to \(person.name) opens ready to send as soon as you finish speaking. Reply with exactly this and nothing else: \"Your \(kind == .message ? "text" : "email") to \(person.name) is ready to send.\""
        }
    }

    private func addReminder(title: String, when: String) async -> String {
        guard !title.isEmpty else { return "Ask what to remind them about." }
        let due = when.isEmpty ? nil : EmberDates.moment(when)
        if !when.isEmpty, due == nil { return "Ask when, like \"tomorrow at 8\"." }
        let label = due.map { " for \($0.formatted(.dateTime.weekday(.wide).hour().minute()))" } ?? ""
        let (id, spoken) = await actions.perform("Reminder: \(title)") {
            let identifier = try await EmberCalendar.addReminder(title: title, due: due)
            return ("Added a reminder to \(title)\(label).", EmberActions.Undo(title: "Reminder: \(title)") { try EmberCalendar.removeReminder(identifier) })
        }
        cards.append(EmberCard(app: nil, kind: .action(id: id, title: title, detail: due.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? "Reminders", symbol: "checklist")))
        return spoken
    }

    private func setTimer(minutes: Double?, label: String) async -> String {
        guard let minutes, minutes > 0 else { return "Ask how long." }
        let name = label.isEmpty ? "Timer" : label.capitalizedFirst
        let duration = minutes < 1 ? "\(Int(minutes * 60)) seconds" : minutes == 1 ? "1 minute" : minutes.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(minutes)) minutes" : "\(minutes.formatted()) minutes"
        let (id, spoken) = await actions.perform("\(duration) \(name.lowercased()) timer") {
            let alarm = try await EmberAlarms.timer(seconds: minutes * 60, label: name)
            return ("\(duration) \(label.isEmpty ? "timer" : "\(label) timer"), starting now.", EmberActions.Undo(title: "the timer") { try EmberAlarms.cancel(alarm) })
        }
        cards.append(EmberCard(app: nil, kind: .action(id: id, title: name, detail: duration, symbol: "timer")))
        return spoken
    }

    private func setAlarm(when: String, label: String) async -> String {
        guard var date = EmberDates.moment(when) else { return "Ask what time." }
        if date < .now { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
        let name = label.isEmpty ? "Alarm" : label.capitalizedFirst
        let time = date.formatted(.dateTime.weekday(.wide).hour().minute())
        let (id, spoken) = await actions.perform("Alarm \(time)") {
            let alarm = try await EmberAlarms.alarm(at: date, label: name)
            return ("Alarm set for \(time).", EmberActions.Undo(title: "the alarm") { try EmberAlarms.cancel(alarm) })
        }
        cards.append(EmberCard(app: nil, kind: .action(id: id, title: name, detail: time, symbol: "alarm")))
        return spoken
    }

    private func myCalendar(range spoken: String) async -> String {
        let range = EmberDates.range(spoken, lean: .future, fallback: "today")
        guard let events = await EmberCalendar.events(in: range) else {
            return "Ember needs Calendar access to read their calendar. Ask them to allow it in Settings › Ember."
        }
        guard !events.isEmpty else { return "Nothing on their calendar \(range.label())." }
        let lines = events.prefix(20).map { event -> String in
            let time = event.isAllDay ? "all day" : event.startDate.formatted(range.days > 1 ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute())
            return "\(time): \(event.title ?? "Event")\(event.location.map { " at \($0)" } ?? "")"
        }
        show(EmberAnswer(facts: "", title: "Your calendar", value: "\(events.count) \(events.count == 1 ? "event" : "events")", subtitle: range.label(),
                         rows: events.prefix(8).map { EmberRow(title: $0.title ?? "Event", value: $0.isAllDay ? "All day" : $0.startDate.formatted(date: .omitted, time: .shortened)) }),
             app: nil, link: URL(string: "calshow:\(range.start.timeIntervalSinceReferenceDate)"), action: "Open Calendar")
        return "Their calendar \(range.label()):\n" + lines.joined(separator: "\n")
    }

    private func addMyEvent(title: String, when: String, minutes: Double?, location: String) async -> String {
        guard !title.isEmpty else { return "Ask what the event is." }
        guard let start = EmberDates.moment(when) else { return "Ask when it is." }
        let hasTime = when.rangeOfCharacter(from: .decimalDigits) != nil || ["noon", "morning", "evening", "afternoon", "tonight"].contains { when.lowercased().contains($0) }
        let end = hasTime ? start.addingTimeInterval((minutes ?? 60) * 60) : (Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
        let whenText = hasTime ? start.formatted(.dateTime.weekday(.wide).month().day().hour().minute()) : start.formatted(.dateTime.weekday(.wide).month().day())
        let clashes = await EmberCalendar.conflicts(start: start, end: end)
        let id = actions.propose("Add \(title)") {
            let identifier = try await EmberCalendar.addEvent(title: title, start: start, end: end, isAllDay: !hasTime, location: location)
            return ("Added \(title) to your calendar, \(whenText).", EmberActions.Undo(title: "Add \(title)") { try EmberCalendar.removeEvent(identifier) })
        }
        cards.append(EmberCard(app: nil, kind: .action(id: id, title: title, detail: [whenText, location].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "calendar.badge.plus")))
        var facts = "Ready to add \(title) to their calendar, \(whenText). Nothing added yet: ask them to confirm."
        if !clashes.isEmpty { facts += " It overlaps \(clashes.compactMap(\.title).formatted(.list(type: .and))); mention it." }
        return facts
    }

    private func directions(_ place: String) async -> String {
        guard let found = await EmberDirections.link(to: place) else { return "Apple Maps couldn't find \(place)." }
        cards.append(EmberCard(app: nil, kind: .handoff(title: found.name, detail: found.detail, symbol: "arrow.triangle.turn.up.right.diamond"),
                               link: found.url, actionTitle: "Directions", opensWhenSpoken: true))
        return "Directions to \(found.name) open in Maps when you finish speaking. Say so in a few words."
    }

    // MARK: Helpers

    /// A card for an answer worked out outside the tools (the money pipeline).
    func present(_ answer: EmberAnswer, app: HearthApp, link: URL?, action: String) {
        use(app)
        show(answer, app: app, link: link, action: action)
    }

    private func show(_ answer: EmberAnswer, app: HearthApp?, link: URL?, action: String) {
        guard !answer.title.isEmpty else { return }
        cards.append(EmberCard(app: app, kind: .answer(answer), link: link, actionTitle: action))
    }

    /// "(as of Tuesday)" when the data is over a day old.
    static func freshness(_ date: Date?) -> String {
        guard let date, Date.now.timeIntervalSince(date) > 86_400 else { return "" }
        return "\n(This is as of \(date.formatted(.dateTime.weekday(.wide).month().day())); say so.)"
    }

    static func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide))
    }
}
