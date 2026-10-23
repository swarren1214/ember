import Foundation

// HearthMoney: Suffice's money math and the answers built from it, shared by Suffice and Ember so
// they can never disagree. Canonical copy in ~/Developer/hearthkit; `bash sync.sh` copies it to
// suffice/Suffice/Services/Hearth and ember/Shared. Edit it here, never in a copy.
//
//   Values     Entry, Category, Bill, Member: plain copies of Suffice's records. Codable: Suffice
//              shares its Book with Ember on the iPhone (the app group's suffice.money.json)
//   Math       which budgets count in a month, what's spent in each, when bills come due and
//              whether they're paid (Suffice's BudgetMath calls these)
//   Query      every purchase matching a period, person, budget or store, with totals
//   Answers    what to say for spending, purchases, a budget, or bills: the period always named,
//              every number from the data, and missing data never read as $0
//
// Pure functions over values: no SwiftData, no CloudKit, no model, so the same question always
// gets the same answer and all of it is covered by tests.

nonisolated enum HearthMoney {

    // MARK: - Values

    nonisolated struct Part: Hashable, Sendable, Codable {
        var categoryID: UUID?
        var amountCents: Int

        init(categoryID: UUID?, amountCents: Int) {
            self.categoryID = categoryID
            self.amountCents = amountCents
        }
    }

    nonisolated struct Entry: Hashable, Sendable, Identifiable, Codable {
        var id: UUID
        var date: Date
        var payee: String
        /// Where it happened, when the bank said (a place name).
        var place: String?
        var amountCents: Int
        var isIncome: Bool
        var categoryID: UUID?
        var memberID: UUID?
        var billID: UUID?
        var billDueDate: Date?
        /// A split charge's parts; empty when it isn't split.
        var splits: [Part]
        /// How much of it a stash paid for.
        var stashCents: Int

        init(id: UUID = UUID(), date: Date, payee: String, place: String? = nil, amountCents: Int, isIncome: Bool = false,
             categoryID: UUID? = nil, memberID: UUID? = nil, billID: UUID? = nil, billDueDate: Date? = nil,
             splits: [Part] = [], stashCents: Int = 0) {
            self.id = id; self.date = date; self.payee = payee; self.place = place; self.amountCents = amountCents
            self.isIncome = isIncome; self.categoryID = categoryID; self.memberID = memberID; self.billID = billID
            self.billDueDate = billDueDate; self.splits = splits; self.stashCents = stashCents
        }

        /// Where the money went: the parts of a split, or the whole charge in its one budget.
        var parts: [Part] {
            splits.isEmpty ? [Part(categoryID: categoryID, amountCents: amountCents)] : splits
        }

        /// What counts as spending: its parts, less what a stash covered (taken off the part in
        /// its main budget first, then the others). A bill paid in full from a stash leaves nothing.
        var spendingParts: [Part] {
            let covered = min(max(stashCents, 0), amountCents)
            guard covered > 0 else { return parts }
            var result = parts
            var left = covered
            let main = categoryID
            func rank(_ index: Int) -> Int { result[index].categoryID == main ? 0 : 1 }
            let order = result.indices.sorted { (rank($0), $0) < (rank($1), $1) }
            for index in order where left > 0 {
                let taken = min(result[index].amountCents, left)
                result[index].amountCents -= taken
                left -= taken
            }
            return result.filter { $0.amountCents > 0 }
        }

        var spendingCents: Int { amountCents - min(max(stashCents, 0), amountCents) }
    }

    nonisolated struct Category: Hashable, Sendable, Identifiable, Codable {
        var id: UUID
        var name: String
        var limitCents: Int
        var parentID: UUID?
        var startMonth: Date
        var repeatsMonthly: Bool
        var isArchived: Bool
        var sortOrder: Int

        init(id: UUID = UUID(), name: String, limitCents: Int, parentID: UUID? = nil, startMonth: Date = .distantPast,
             repeatsMonthly: Bool = true, isArchived: Bool = false, sortOrder: Int = 0) {
            self.id = id; self.name = name; self.limitCents = limitCents; self.parentID = parentID
            self.startMonth = startMonth; self.repeatsMonthly = repeatsMonthly; self.isArchived = isArchived; self.sortOrder = sortOrder
        }
    }

    nonisolated struct Member: Hashable, Sendable, Identifiable, Codable {
        var id: UUID
        var name: String

        init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    nonisolated struct Bill: Hashable, Sendable, Identifiable, Codable {
        nonisolated enum Frequency: String, Hashable, Sendable, Codable { case once, weekly, monthly, yearly }

        var id: UUID
        var name: String
        var amountCents: Int
        var isVariable: Bool
        var dueDay: Int
        var frequency: Frequency
        var interval: Int
        var startDate: Date
        var endDate: Date?
        var isAutopay: Bool
        var isActive: Bool

        init(id: UUID = UUID(), name: String, amountCents: Int, isVariable: Bool = false, dueDay: Int, frequency: Frequency = .monthly,
             interval: Int = 1, startDate: Date = .distantPast, endDate: Date? = nil, isAutopay: Bool = false, isActive: Bool = true) {
            self.id = id; self.name = name; self.amountCents = amountCents; self.isVariable = isVariable; self.dueDay = dueDay
            self.frequency = frequency; self.interval = interval; self.startDate = startDate; self.endDate = endDate
            self.isAutopay = isAutopay; self.isActive = isActive
        }
    }

    /// A span of days: its first moment and the first moment after it.
    nonisolated struct Span: Hashable, Sendable {
        var start: Date
        var end: Date

        init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }

        /// The calendar month holding `date`.
        static func month(containing date: Date, calendar: Calendar = .current) -> Span {
            let interval = calendar.dateInterval(of: .month, for: date)
            return Span(start: interval?.start ?? calendar.startOfDay(for: date), end: interval?.end ?? date.addingTimeInterval(31 * 86_400))
        }

        func contains(_ date: Date) -> Bool { date >= start && date < end }

        func days(calendar: Calendar = .current) -> Int {
            max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
        }

        /// The same number of days just before.
        func previous(calendar: Calendar = .current) -> Span {
            let length = days(calendar: calendar)
            return Span(start: calendar.date(byAdding: .day, value: -length, to: start) ?? start, end: start)
        }

        /// Cut off at the end of today: for questions about what already happened.
        func throughToday(now: Date, calendar: Calendar = .current) -> Span {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return Span(start: start, end: min(end, tomorrow))
        }
    }

    // MARK: - Math (Suffice's BudgetMath calls these)

    /// Whether a budget counts in `month`: started by then, and either repeating or a one-month
    /// budget for exactly that month. Archived budgets drop out.
    static func isActive(_ category: Category, in month: Span, calendar: Calendar = .current) -> Bool {
        guard !category.isArchived else { return false }
        let starts = Span.month(containing: category.startMonth, calendar: calendar)
        if category.startMonth > .distantPast, starts.start > month.start { return false }
        if !category.repeatsMonthly, category.startMonth > .distantPast, starts.start != month.start { return false }
        return true
    }

    /// Spending per budget for entries in `month`. Income is ignored; nil = no budget. What a
    /// stash paid for doesn't count.
    static func spentByCategory(_ entries: [Entry], in month: Span) -> [UUID?: Int] {
        var totals: [UUID?: Int] = [:]
        for entry in entries where !entry.isIncome && month.contains(entry.date) {
            for part in entry.spendingParts { totals[part.categoryID, default: 0] += part.amountCents }
        }
        return totals
    }

    nonisolated struct Status: Hashable, Sendable, Identifiable {
        var category: Category
        /// Spent in it (and, for a budget with subcategories, in them).
        var spentCents: Int
        /// Its own amount, or the sum of its subcategories' when it has none of its own.
        var limitCents: Int
        var children: [Status] = []

        var id: UUID { category.id }
        var leftCents: Int { limitCents - spentCents }
        var isOver: Bool { limitCents > 0 ? spentCents > limitCents : spentCents > 0 }
    }

    /// The top-level budgets for `month`, each with its subcategories, in sort order. A budget
    /// that isn't active still shows if money was spent in it.
    static func statuses(_ categories: [Category], entries: [Entry], in month: Span, calendar: Calendar = .current) -> [Status] {
        let spent = spentByCategory(entries, in: month)
        let sorted = categories.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        return sorted.filter { $0.parentID == nil }.compactMap { parent in
            let children = sorted.filter { $0.parentID == parent.id }.compactMap { child -> Status? in
                let childSpent = spent[child.id] ?? 0
                let active = isActive(child, in: month, calendar: calendar)
                guard active || childSpent > 0 else { return nil }
                return Status(category: child, spentCents: childSpent, limitCents: active ? child.limitCents : 0)
            }
            let total = (spent[parent.id] ?? 0) + children.reduce(0) { $0 + $1.spentCents }
            let active = isActive(parent, in: month, calendar: calendar)
            guard active || total > 0 else { return nil }
            let childLimits = children.reduce(0) { $0 + $1.limitCents }
            let limit = !active ? 0 : (parent.limitCents > 0 || children.isEmpty ? parent.limitCents : childLimits)
            return Status(category: parent, spentCents: total, limitCents: limit, children: children)
        }
    }

    /// Every date a bill comes due from `start` up to (not including) `end`, oldest first.
    static func occurrences(of bill: Bill, from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        let from = calendar.startOfDay(for: start)
        let hasStart = bill.startDate > .distantPast
        let first = hasStart ? calendar.startOfDay(for: bill.startDate) : .distantPast
        let last = bill.endDate.map { calendar.startOfDay(for: $0) }
        let interval = max(bill.interval, 1)
        var dates: [Date] = []
        func keep(_ date: Date) -> Bool {
            date >= from && date < end && date >= first && (last.map { date <= $0 } ?? true)
        }
        switch bill.frequency {
        case .once:
            if hasStart, keep(first) { dates.append(first) }
        case .weekly:
            // Weekly needs a first date to know the weekday.
            guard hasStart else { break }
            let step = 7 * interval
            let daysIn = calendar.dateComponents([.day], from: first, to: from).day ?? 0
            var index = max(0, daysIn / step)
            while let date = calendar.date(byAdding: .day, value: index * step, to: first), date < end {
                if keep(date) { dates.append(date) }
                index += 1
            }
        case .monthly, .yearly:
            let monthsPerStep = bill.frequency == .yearly ? 12 * interval : interval
            // Old bills have no first date: they come due every month on their day.
            let anchor = Span.month(containing: hasStart ? first : from, calendar: calendar).start
            let fromMonth = Span.month(containing: from, calendar: calendar).start
            let monthsIn = calendar.dateComponents([.month], from: anchor, to: fromMonth).month ?? 0
            var index = max(0, monthsIn / monthsPerStep)
            while let month = calendar.date(byAdding: .month, value: index * monthsPerStep, to: anchor), month < end {
                let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 28
                let day = min(max(bill.dueDay, 1), days)
                if let date = calendar.date(byAdding: .day, value: day - 1, to: month), keep(date) { dates.append(date) }
                index += 1
            }
        }
        return dates
    }

    /// The payment recorded for one due date of a bill. A payment marks the due date it names;
    /// an older one without a due date counts for its month.
    static func payment(for bill: Bill, dueOn due: Date, payments: [Entry], calendar: Calendar = .current) -> Entry? {
        payments.filter { entry in
            guard entry.billID == bill.id else { return false }
            if let paidFor = entry.billDueDate { return calendar.isDate(paidFor, inSameDayAs: due) }
            return calendar.isDate(entry.date, equalTo: due, toGranularity: .month)
        }.max { $0.date < $1.date }
    }

    nonisolated struct Due: Hashable, Sendable {
        var bill: Bill
        var date: Date
        var isPaid: Bool
    }

    /// Due dates in a span, paid or not, plus unpaid ones up to 45 days late when the span
    /// starts today or earlier.
    static func dues(_ bills: [Bill], entries: [Entry], in span: Span, includeLate: Bool = true, now: Date = .now,
                     calendar: Calendar = .current) -> [Due] {
        let today = calendar.startOfDay(for: now)
        let lateFrom = includeLate && span.start <= today ? (calendar.date(byAdding: .day, value: -45, to: today) ?? today) : span.start
        let payments = entries.filter { $0.billID != nil }
        var result: [Due] = []
        for bill in bills where bill.isActive {
            for date in occurrences(of: bill, from: min(lateFrom, span.start), to: span.end, calendar: calendar) {
                let paid = payment(for: bill, dueOn: date, payments: payments, calendar: calendar) != nil
                // Before the span: only the unpaid (late) ones.
                if date < span.start && paid { continue }
                result.append(Due(bill: bill, date: date, isPaid: paid))
            }
        }
        return result.sorted { ($0.date, $0.bill.name) < ($1.date, $1.bill.name) }
    }

    // MARK: - The book: everything an answer reads

    nonisolated struct Book: Sendable, Codable {
        var categories: [Category] = []
        var entries: [Entry] = []
        var bills: [Bill] = []
        var members: [Member] = []

        init(categories: [Category] = [], entries: [Entry] = [], bills: [Bill] = [], members: [Member] = []) {
            self.categories = categories
            self.entries = entries
            self.bills = bills
            self.members = members
        }

        func category(_ id: UUID?) -> Category? { id.flatMap { id in categories.first { $0.id == id } } }

        /// The top-level budget a category belongs to (itself, for a top-level one).
        func topLevel(_ id: UUID?) -> Category? {
            guard let category = category(id) else { return nil }
            return category.parentID.flatMap { self.category($0) } ?? category
        }

        /// A budget by what someone called it: "groceries", "eating out", "gas".
        func findCategory(_ spoken: String) -> Category? {
            let key = HearthMoney.fold(spoken)
            guard !key.isEmpty else { return nil }
            let live = categories.filter { !$0.isArchived }
            if let exact = live.first(where: { HearthMoney.fold($0.name) == key }) { return exact }
            if let partial = live.first(where: { HearthMoney.fold($0.name).contains(key) || key.contains(HearthMoney.fold($0.name)) }) { return partial }
            // Singular and plural: "grocery" / "groceries".
            let stem = String(key.prefix(5))
            return stem.count >= 4 ? live.first { HearthMoney.fold($0.name).hasPrefix(stem) } : nil
        }

        /// A person by name: exact, then by first name.
        func member(named name: String) -> Member? {
            let key = HearthMoney.fold(name)
            guard !key.isEmpty else { return nil }
            let first = key.split(separator: " ").first.map(String.init) ?? key
            return members.first { HearthMoney.fold($0.name) == key } ?? members.first { HearthMoney.fold($0.name).hasPrefix(first) }
        }

        /// A bill by name.
        func findBill(_ spoken: String) -> Bill? {
            let key = HearthMoney.fold(spoken)
            guard !key.isEmpty else { return nil }
            let live = bills.filter(\.isActive)
            return live.first { HearthMoney.fold($0.name) == key }
                ?? live.first { HearthMoney.fold($0.name).contains(key) || key.contains(HearthMoney.fold($0.name)) }
        }

        /// A budget and its subcategories.
        func ids(under budget: Category) -> Set<UUID> {
            Set([budget.id] + categories.filter { $0.parentID == budget.id }.map(\.id))
        }

        /// The newest transaction's date: which of two copies is more up to date.
        var newestEntry: Date? { entries.lazy.map(\.date).filter { $0 > .distantPast }.max() }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    // MARK: - Coverage

    /// Where the data reaches: an empty answer past the newest entry is "not synced", not "$0".
    nonisolated struct Coverage: Sendable, Equatable {
        var newest: Date?
        var entryCount: Int

        init(newest: Date?, entryCount: Int) {
            self.newest = newest
            self.entryCount = entryCount
        }

        init(_ book: Book) {
            let dated = book.entries.filter { $0.date > .distantPast }
            newest = dated.map(\.date).max()
            entryCount = dated.count
        }

        /// Nothing in the data reaches this span.
        func cannotSee(_ span: Span) -> Bool {
            guard entryCount > 0, let newest else { return true }
            return newest < span.start
        }

        /// The newest entry, when the span runs more than two days past it.
        func stopsShort(of span: Span, now: Date, calendar: Calendar) -> Date? {
            guard let newest, newest >= span.start else { return nil }
            let end = min(span.end, now)
            let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: newest), to: end).day ?? 0
            return gap > 2 ? newest : nil
        }
    }

    // MARK: - Query

    nonisolated struct Query: Sendable {
        var span: Span
        var member: Member?
        /// Words to find in the payee or place ("Costco").
        var payee: String?
        var budget: Category?

        init(span: Span, member: Member? = nil, payee: String? = nil, budget: Category? = nil) {
            self.span = span
            self.member = member
            self.payee = payee
            self.budget = budget
        }
    }

    nonisolated struct Match: Hashable, Sendable {
        var entry: Entry
        /// What counts toward the question: the part in the budget asked about, less stash.
        var cents: Int
    }

    nonisolated struct Result: Sendable {
        var query: Query
        /// Newest first.
        var matches: [Match]
        var spentCents: Int
        var incomeCents: Int
        /// Top-level budget name → cents, largest first.
        var byBudget: [(String, Int)]
        var byPayee: [(String, Int)]
        /// The same filters over the span before, the same length.
        var previousSpentCents: Int?

        var count: Int { matches.count }
    }

    /// Every purchase matching the query, with totals. Income is counted separately, never as
    /// spending.
    static func run(_ query: Query, in book: Book, comparing: Bool = true, calendar: Calendar = .current) -> Result {
        let budgetIDs = query.budget.map(book.ids(under:))
        let payeeKey = query.payee.map(fold).flatMap { $0.isEmpty ? nil : $0 }

        func scan(_ span: Span) -> (spent: [Match], income: Int, byBudget: [String: Int]) {
            var found: [Match] = []
            var income = 0
            var byBudget: [String: Int] = [:]
            for entry in book.entries where span.contains(entry.date) {
                if let member = query.member, entry.memberID != member.id { continue }
                if let payeeKey, !fold(entry.payee + " " + (entry.place ?? "")).contains(payeeKey) { continue }
                if entry.isIncome {
                    if budgetIDs == nil { income += entry.amountCents }
                    continue
                }
                var cents = 0
                for part in entry.spendingParts {
                    if let budgetIDs, !(part.categoryID.map(budgetIDs.contains) ?? false) { continue }
                    cents += part.amountCents
                    byBudget[book.topLevel(part.categoryID)?.name ?? "Not in a budget", default: 0] += part.amountCents
                }
                if cents > 0 { found.append(Match(entry: entry, cents: cents)) }
            }
            return (found.sorted { $0.entry.date > $1.entry.date }, income, byBudget)
        }

        let now = scan(query.span)
        var byPayee: [String: Int] = [:]
        for match in now.spent { byPayee[match.entry.payee.isEmpty ? "Unknown" : match.entry.payee, default: 0] += match.cents }
        func ranked(_ values: [String: Int]) -> [(String, Int)] {
            values.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        let previous = comparing ? scan(query.span.previous(calendar: calendar)).spent.reduce(0) { $0 + $1.cents } : nil
        return Result(query: query, matches: now.spent, spentCents: now.spent.reduce(0) { $0 + $1.cents }, incomeCents: now.income,
                      byBudget: ranked(now.byBudget), byPayee: ranked(byPayee), previousSpentCents: previous)
    }

    // MARK: - Answers

    /// A money question with its period already worked out.
    nonisolated struct Ask: Sendable {
        nonisolated enum Kind: String, Sendable { case spending, transactions, budget, bills }

        var kind: Kind
        var span: Span
        /// The words for the period as said ("last week"), for the answer; may be empty.
        var said: String = ""
        /// A person, as said.
        var person: String = ""
        /// A budget, as said.
        var budget: String = ""
        /// A store or payee (or, for bills, the bill's name), as said.
        var place: String = ""

        init(kind: Kind, span: Span, said: String = "", person: String = "", budget: String = "", place: String = "") {
            self.kind = kind; self.span = span; self.said = said; self.person = person; self.budget = budget; self.place = place
        }
    }

    nonisolated struct Row: Hashable, Sendable {
        var title: String
        var value: String
        var detail: String = ""
        /// Shown as a check (paid) or an open circle (to pay); nil shows nothing.
        var done: Bool?
    }

    /// What to say, and what the card shows.
    nonisolated struct Reply: Sendable {
        var text: String
        var title = ""
        var value = ""
        var subtitle = ""
        var rows: [Row] = []
        /// 0…1 for a budget's bar.
        var fraction: Double?
        /// It asked something back (which budget, which day).
        var asksBack = false
        /// Nothing worth a card (a question back, an error).
        var hasCard: Bool { !title.isEmpty }
    }

    static func answer(_ ask: Ask, book: Book, coverage: Coverage? = nil, now: Date = .now, calendar: Calendar = .current) -> Reply {
        let coverage = coverage ?? Coverage(book)

        // Who.
        var member: Member?
        if !ask.person.isEmpty {
            guard let found = book.member(named: ask.person) else {
                let names = book.members.map(\.name)
                return Reply(text: "I don't see \(ask.person) in Suffice. " + (names.isEmpty ? "Nobody is set up there yet." : "Suffice has \(list(names))."))
            }
            member = found
        }
        // Which budget.
        var budget: Category?
        if !ask.budget.isEmpty {
            guard let found = book.findCategory(ask.budget) else {
                let names = book.categories.filter { !$0.isArchived && $0.parentID == nil }
                    .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }.map(\.name)
                return Reply(text: "Suffice doesn't have a \(ask.budget) budget. Its budgets are \(list(Array(names.prefix(8)))).", asksBack: true)
            }
            budget = found
        }

        switch ask.kind {
        case .spending, .transactions:
            return purchases(ask, book: book, member: member, budget: budget, coverage: coverage, now: now, calendar: calendar)
        case .budget:
            return budgetReply(ask, book: book, budget: budget, coverage: coverage, now: now, calendar: calendar)
        case .bills:
            return billsReply(ask, book: book, now: now, calendar: calendar)
        }
    }

    // MARK: Spending and purchases

    private static func purchases(_ ask: Ask, book: Book, member: Member?, budget: Category?, coverage: Coverage,
                                  now: Date, calendar: Calendar) -> Reply {
        let span = ask.span.throughToday(now: now, calendar: calendar)
        let query = Query(span: span, member: member, payee: ask.place.isEmpty ? nil : ask.place, budget: budget)
        let result = run(query, in: book, comparing: ask.kind == .spending, calendar: calendar)
        let when = period(span, said: ask.said, now: now, calendar: calendar)

        if result.count == 0, coverage.cannotSee(span) {
            return notSynced(when, coverage: coverage, now: now, calendar: calendar)
        }

        var text: String
        if ask.kind == .transactions {
            text = transactionsText(result, when: when, now: now, calendar: calendar)
        } else {
            text = spendingText(result, when: when, place: ask.place)
        }
        if let newest = coverage.stopsShort(of: span, now: now, calendar: calendar) {
            text += " I can only see transactions through \(day(newest, now: now, calendar: calendar))."
        }

        var scope: [String] = []
        if let budget { scope.append(budget.name) }
        if !ask.place.isEmpty { scope.append(ask.place.hmTitleCased) }
        if let member { scope.append(member.name) }
        let rows = result.matches.prefix(8).map { match in
            Row(title: match.entry.payee.isEmpty ? "Purchase" : match.entry.payee, value: exact(match.cents),
                detail: shortDate(match.entry.date, calendar: calendar))
        }
        return Reply(text: text,
                     title: (ask.kind == .transactions ? "Purchases " : "Spent ") + label(span, calendar: calendar),
                     value: exact(result.spentCents),
                     subtitle: ([result.count == 1 ? "1 purchase" : "\(result.count) purchases"] + scope).joined(separator: " · "),
                     rows: Array(rows))
    }

    private static func spendingText(_ result: Result, when: String, place: String) -> String {
        let query = result.query
        var scope = ""
        if let budget = query.budget { scope += " on \(budget.name)" }
        if !place.isEmpty { scope += " at \(place)" }
        guard result.count > 0 else {
            return "\(query.member?.name ?? "You") didn’t spend anything\(scope) \(when)."
        }
        var text = "\(query.member.map { "\($0.name) spent" } ?? "You spent") \(money(result.spentCents))\(scope) \(when)"
        if result.count <= 3 {
            text += ": " + list(result.matches.map { "\($0.entry.payee.isEmpty ? "a purchase" : $0.entry.payee) \(exact($0.cents))" }) + "."
        } else {
            text += ", across \(result.count) purchases."
            if query.budget == nil, result.byBudget.count > 1 {
                text += " Most went to \(list(result.byBudget.prefix(2).map { "\($0.0) (\(money($0.1)))" }))."
            } else if place.isEmpty, let biggest = result.byPayee.first {
                text += " The most went to \(biggest.0), \(money(biggest.1))."
            }
        }
        let days = query.span.days()
        if let previous = result.previousSpentCents, previous > 0, days > 1 {
            let delta = result.spentCents - previous
            if abs(delta) >= max(100, previous / 20) {
                text += " That’s \(money(abs(delta))) \(delta > 0 ? "more" : "less") than the \(days) days before."
            } else {
                text += " About the same as the \(days) days before."
            }
        }
        return text
    }

    private static func transactionsText(_ result: Result, when: String, now: Date, calendar: Calendar) -> String {
        guard result.count > 0 else { return "No purchases \(when)." }
        let oneDay = result.query.span.days(calendar: calendar) <= 1
        func item(_ match: Match) -> String {
            let name = match.entry.payee.isEmpty ? "a purchase" : match.entry.payee
            return oneDay ? "\(name) \(exact(match.cents))" : "\(name) \(exact(match.cents)) on \(day(match.entry.date, now: now, calendar: calendar))"
        }
        if result.count <= 4 { return "\(when.hmCapitalized): \(list(result.matches.map(item)))." }
        let biggest = result.matches.sorted { $0.cents > $1.cents }.prefix(2).map(item)
        return "\(result.count) purchases \(when), \(money(result.spentCents)) in all. The biggest: \(list(Array(biggest)))."
    }

    private static func notSynced(_ when: String, coverage: Coverage, now: Date, calendar: Calendar) -> Reply {
        let about = when.hasPrefix("on ") ? String(when.dropFirst(3)) : when
        guard let newest = coverage.newest else {
            return Reply(text: "I can’t read Suffice’s transactions right now, so I can’t tell you about \(about). Try again in a moment.")
        }
        return Reply(text: "The newest transaction I can see from Suffice is from \(day(newest, now: now, calendar: calendar)), so I can’t tell you about \(about) yet.")
    }

    // MARK: Budgets

    private static func budgetReply(_ ask: Ask, book: Book, budget: Category?, coverage: Coverage, now: Date, calendar: Calendar) -> Reply {
        let month = Span.month(containing: ask.span.start, calendar: calendar)
        let statuses = HearthMoney.statuses(book.categories, entries: book.entries, in: month, calendar: calendar)
        let isNow = month.contains(now)
        let monthWords = isNow ? "this month" : "in \(monthName(month.start, calendar: calendar))"
        let today = calendar.startOfDay(for: now)
        let daysLeft = isNow ? max(1, calendar.dateComponents([.day], from: today, to: month.end).day ?? 1) : 0
        let toGo = isNow ? ", with \(daysLeft) \(daysLeft == 1 ? "day" : "days") to go" : ""
        let notSyncedNote: String = {
            guard isNow, let newest = coverage.stopsShort(of: month, now: now, calendar: calendar) else { return "" }
            return " I can only see transactions through \(day(newest, now: now, calendar: calendar))."
        }()

        if let budget {
            guard let status = statuses.flatMap({ [$0] + $0.children }).first(where: { $0.id == budget.id }) else {
                return Reply(text: "\(budget.name) isn’t a budget \(monthWords).")
            }
            let text: String
            if status.limitCents == 0 {
                text = "You’ve spent \(money(status.spentCents)) on \(budget.name) \(monthWords); it has no amount set."
            } else if status.isOver {
                text = "\(budget.name) is \(money(-status.leftCents)) over its \(money(status.limitCents)) \(monthWords)\(toGo)."
            } else {
                text = "\(budget.name) has \(money(status.leftCents)) left of \(money(status.limitCents)) \(monthWords)\(toGo)."
            }
            let rows = status.children.map { child in
                Row(title: child.category.name, value: child.isOver ? "\(money(-child.leftCents)) over" : "\(money(child.leftCents)) left",
                    detail: "\(money(child.spentCents)) of \(money(child.limitCents))")
            }
            return Reply(text: text + notSyncedNote, title: budget.name,
                         value: status.isOver ? "\(money(-status.leftCents)) over" : money(status.leftCents),
                         subtitle: status.limitCents > 0 ? "left of \(money(status.limitCents))" : "\(money(status.spentCents)) spent",
                         rows: rows,
                         fraction: status.limitCents > 0 ? min(1, Double(status.spentCents) / Double(status.limitCents)) : nil)
        }

        let planned = statuses.filter { $0.limitCents > 0 }
        guard !planned.isEmpty else {
            return Reply(text: "Suffice has no budgets with amounts \(monthWords).")
        }
        let limit = planned.reduce(0) { $0 + $1.limitCents }
        let spent = planned.reduce(0) { $0 + $1.spentCents }
        let over = planned.filter(\.isOver)
        var text = limit >= spent
            ? "Across your budgets you have \(money(limit - spent)) left of \(money(limit)) \(monthWords)\(toGo)."
            : "Your budgets are \(money(spent - limit)) over their \(money(limit)) \(monthWords)\(toGo)."
        if !over.isEmpty {
            text += " Over: \(list(over.prefix(3).map { "\($0.category.name) by \(money(-$0.leftCents))" }))."
        } else if limit >= spent {
            text += " Nothing is over."
        }
        let rows = planned.map { status in
            Row(title: status.category.name, value: status.isOver ? "\(money(-status.leftCents)) over" : "\(money(status.leftCents)) left",
                detail: "\(money(status.spentCents)) of \(money(status.limitCents))")
        }
        return Reply(text: text + notSyncedNote, title: "Budgets \(isNow ? "this month" : monthName(month.start, calendar: calendar))",
                     value: money(limit - spent), subtitle: "left of \(money(limit))", rows: rows,
                     fraction: limit > 0 ? min(1, Double(spent) / Double(limit)) : nil)
    }

    // MARK: Bills

    private static func billsReply(_ ask: Ask, book: Book, now: Date, calendar: Calendar) -> Reply {
        var bills = book.bills
        if !ask.place.isEmpty {
            guard let bill = book.findBill(ask.place) else {
                let names = book.bills.filter(\.isActive).map(\.name)
                return Reply(text: "I don't see a bill called \(ask.place) in Suffice." + (names.isEmpty ? "" : " Its bills are \(list(Array(names.prefix(8))))."),
                             asksBack: !names.isEmpty)
            }
            bills = [bill]
        }
        let dues = HearthMoney.dues(bills, entries: book.entries, in: ask.span, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let unpaid = dues.filter { !$0.isPaid }
        let late = unpaid.filter { $0.date < today }
        let coming = unpaid.filter { $0.date >= today }
        let when = billPeriod(ask.span, said: ask.said, now: now, calendar: calendar)

        func item(_ due: Due) -> String {
            "\(due.bill.name) \(due.bill.isVariable ? "about " : "")\(money(due.bill.amountCents)) \(dueWords(due.date, now: now, calendar: calendar))"
                + (due.bill.isAutopay ? " (autopay)" : "")
        }
        var sentences: [String] = []
        if coming.isEmpty {
            let paidCount = dues.filter { $0.isPaid && $0.date >= ask.span.start }.count
            sentences.append(paidCount > 0 ? "Nothing left to pay \(when); \(paidCount == 1 ? "the one bill is" : "all \(paidCount) are") paid." : "No bills due \(when).")
        } else {
            let total = coming.reduce(0) { $0 + $1.bill.amountCents }
            let count = coming.count == 1 ? "One bill" : "\(coming.count) bills"
            sentences.append("\(count) due \(when), \(money(total)) in all: \(list(coming.prefix(4).map(item)))\(coming.count > 4 ? ", and more" : "").")
        }
        if !late.isEmpty {
            sentences.append(late.count == 1
                ? "\(late[0].bill.name) was due \(day(late[0].date, now: now, calendar: calendar)) and isn’t marked paid."
                : "\(late.count) are late: \(list(late.prefix(3).map { "\($0.bill.name), due \(day($0.date, now: now, calendar: calendar))" })).")
        }
        let rows = dues.prefix(10).map { due in
            Row(title: due.bill.name, value: money(due.bill.amountCents), detail: shortDate(due.date, calendar: calendar), done: due.isPaid)
        }
        return Reply(text: sentences.joined(separator: " "), title: "Bills", value: money(coming.reduce(0) { $0 + $1.bill.amountCents } + late.reduce(0) { $0 + $1.bill.amountCents }),
                     subtitle: unpaid.isEmpty ? "All paid" : "\(unpaid.count) to pay", rows: Array(rows))
    }

    // MARK: - Words

    /// "$412" for big amounts, "$30.40" when the cents matter.
    static func money(_ cents: Int) -> String {
        cents >= 10_000 || cents % 100 == 0 ? whole(cents) : exact(cents)
    }

    static func whole(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    /// "$12.50", or "$12" when there are no cents.
    static func exact(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: "USD").precision(.fractionLength(cents % 100 == 0 ? 0 : 2)))
    }

    /// How a past period is said: "today", "yesterday", "on Saturday, October 10", "last week
    /// (October 11 to 17)", "this month", "in September".
    static func period(_ span: Span, said: String, now: Date, calendar: Calendar) -> String {
        let last = calendar.date(byAdding: .second, value: -1, to: span.end) ?? span.end
        if calendar.isDate(span.start, inSameDayAs: last) {
            let spoken = day(span.start, now: now, calendar: calendar)
            return spoken == "today" || spoken == "yesterday" ? spoken : "on " + longDay(span.start, now: now, calendar: calendar)
        }
        let month = Span.month(containing: span.start, calendar: calendar)
        if month.start == span.start, calendar.isDate(last, equalTo: month.start, toGranularity: .month) {
            return calendar.isDate(span.start, equalTo: now, toGranularity: .month) ? "this month" : "in \(monthName(span.start, calendar: calendar))"
        }
        let words = said.lowercased().trimmingCharacters(in: .whitespaces)
        let range = spanText(span.start, last, calendar: calendar)
        return words.isEmpty || words.contains(where: \.isNumber) || words.hasPrefix("since") ? "from \(range)" : "\(words) (\(range))"
    }

    /// How a coming period is said, for bills: "this week (October 18 to 24)", "in the next 14 days".
    static func billPeriod(_ span: Span, said: String, now: Date, calendar: Calendar) -> String {
        let words = said.lowercased().trimmingCharacters(in: .whitespaces)
        if !words.isEmpty, !words.contains(where: \.isNumber) {
            let last = calendar.date(byAdding: .second, value: -1, to: span.end) ?? span.end
            return calendar.isDate(span.start, inSameDayAs: last) ? words : "\(words) (\(spanText(span.start, last, calendar: calendar)))"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: max(span.start, now)), to: span.end).day ?? span.days(calendar: calendar)
        return "in the next \(max(days, 1)) days"
    }

    /// "today", "tomorrow", "on Monday" (this week), "on November 1".
    static func dueWords(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days == 0 { return "today" }
        if days == 1 { return "tomorrow" }
        if days > 1, days < 7 { return "on " + formatter("EEEE", calendar).string(from: date) }
        return "on " + day(date, now: now, calendar: calendar)
    }

    /// "October 8", or "today" / "yesterday".
    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        return "\(monthName(date, calendar: calendar)) \(calendar.component(.day, from: date))"
    }

    /// "Saturday, October 10" (with the year when it isn't this year's).
    static func longDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        formatter(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "EEEE, MMMM d" : "EEEE, MMMM d, yyyy", calendar).string(from: date)
    }

    /// "Oct 10" for cards.
    static func shortDate(_ date: Date, calendar: Calendar) -> String {
        formatter("EEE, MMM d", calendar).string(from: date)
    }

    /// "Oct 11–17", "Oct 10", "October" for card titles.
    static func label(_ span: Span, calendar: Calendar) -> String {
        let last = calendar.date(byAdding: .second, value: -1, to: span.end) ?? span.end
        if calendar.isDate(span.start, inSameDayAs: last) { return formatter("MMM d", calendar).string(from: span.start) }
        if calendar.isDate(span.start, equalTo: last, toGranularity: .month) {
            return "\(formatter("MMM d", calendar).string(from: span.start))–\(calendar.component(.day, from: last))"
        }
        return "\(formatter("MMM d", calendar).string(from: span.start))–\(formatter("MMM d", calendar).string(from: last))"
    }

    static func monthName(_ date: Date, calendar: Calendar) -> String {
        formatter("MMMM", calendar).string(from: date)
    }

    private static func spanText(_ start: Date, _ end: Date, calendar: Calendar) -> String {
        let startMonth = monthName(start, calendar: calendar)
        let endMonth = monthName(end, calendar: calendar)
        let startDay = calendar.component(.day, from: start)
        let endDay = calendar.component(.day, from: end)
        return startMonth == endMonth ? "\(startMonth) \(startDay) to \(endDay)" : "\(startMonth) \(startDay) to \(endMonth) \(endDay)"
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = format
        return formatter
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

private extension String {
    nonisolated var hmCapitalized: String { prefix(1).uppercased() + dropFirst() }
    nonisolated var hmTitleCased: String { split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
}
