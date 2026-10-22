import CloudKit
import Foundation

// Suffice's budget as Ember reads it from the "Budget" zone: budgets, transactions, bills and
// people, decoded from the same encrypted record fields Suffice writes (Suffice ›
// SyncRecords.swift), with Suffice's own rules for what counts as spending (BudgetMath). New
// transactions are written as Suffice writes them, so Suffice files them like its own.
//
// Keep in step with Suffice: a field renamed there must be renamed here.

nonisolated struct SufficeCategory: Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var limitCents: Int
    var parentID: UUID?
    var startMonth: Date
    var repeatsMonthly: Bool
    var isArchived: Bool
    var sortOrder: Int
}

nonisolated struct SufficeSplit: Sendable, Hashable, Codable {
    var id: UUID?
    var categoryID: UUID?
    var amountCents: Int
}

nonisolated struct SufficeEntry: Sendable, Hashable, Identifiable {
    var id: UUID
    var recordName: String
    var date: Date
    var payee: String
    var amountCents: Int
    var isIncome: Bool
    var categoryID: UUID?
    var memberID: UUID?
    var billID: UUID?
    var billDueDate: Date?
    var splits: [SufficeSplit]
    var stashCents: Int
    var placeName: String?

    /// Where the money went: a split's parts, or the whole charge in its one budget.
    var parts: [SufficeSplit] {
        splits.isEmpty ? [SufficeSplit(categoryID: categoryID, amountCents: amountCents)] : splits
    }

    /// What counts as spending: its parts, less what a stash covered (the main budget's part
    /// first), as Suffice counts it.
    var spendingParts: [SufficeSplit] {
        let covered = min(max(stashCents, 0), amountCents)
        guard covered > 0 else { return parts }
        var result = parts
        var left = covered
        let order = result.indices.sorted { a, b in
            let rankA = result[a].categoryID == categoryID ? 0 : 1
            let rankB = result[b].categoryID == categoryID ? 0 : 1
            return (rankA, a) < (rankB, b)
        }
        for index in order where left > 0 {
            let taken = min(result[index].amountCents, left)
            result[index].amountCents -= taken
            left -= taken
        }
        return result.filter { $0.amountCents > 0 }
    }

    var spendingCents: Int { amountCents - min(max(stashCents, 0), amountCents) }
}

nonisolated struct SufficeBill: Sendable, Hashable, Identifiable {
    enum Frequency: String, Sendable { case once, weekly, monthly, yearly }

    var id: UUID
    var name: String
    var amountCents: Int
    var isVariable: Bool
    var dueDay: Int
    var frequency: Frequency
    var interval: Int
    var startDate: Date
    var endDate: Date?
    var categoryID: UUID?
    var isAutopay: Bool
    var isActive: Bool
}

nonisolated struct SufficeMember: Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
}

/// How one budget is doing in a month.
nonisolated struct SufficeBudgetStatus: Sendable, Hashable, Identifiable {
    var category: SufficeCategory
    var spentCents: Int
    var limitCents: Int
    var children: [SufficeBudgetStatus] = []
    var id: UUID { category.id }
    var leftCents: Int { limitCents - spentCents }
}

nonisolated struct SufficeDue: Sendable, Hashable {
    var bill: SufficeBill
    var date: Date
    var isPaid: Bool
}

/// A snapshot of the budget, decoded once per question.
nonisolated struct SufficeLedger: Sendable {
    var categories: [SufficeCategory] = []
    var entries: [SufficeEntry] = []
    var bills: [SufficeBill] = []
    var members: [SufficeMember] = []
    /// payee key ("target") → budget, from "Always use this budget".
    var rules: [String: UUID] = [:]

    static let zoneName = "Budget"

    init() {}

    init(records: [CKRecord]) {
        for record in records {
            guard let (type, id) = Self.parse(record.recordID.recordName) else { continue }
            switch type {
            case "BudgetCategory":
                categories.append(SufficeCategory(
                    id: id,
                    name: record.sealedText("name") ?? "",
                    limitCents: record.sealedInt("limitCents") ?? 0,
                    parentID: record.sealedUUID("parentID"),
                    startMonth: record.sealedDate("startMonth") ?? .distantPast,
                    repeatsMonthly: record.sealedBool("repeatsMonthly") ?? true,
                    isArchived: record.sealedBool("isArchived") ?? false,
                    sortOrder: record.sealedInt("sortOrder") ?? 0
                ))
            case "LedgerEntry":
                let splitsJSON = record.sealedText("splitsJSON") ?? ""
                let splits = splitsJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode([SufficeSplit].self, from: $0) } ?? []
                entries.append(SufficeEntry(
                    id: id,
                    recordName: record.recordID.recordName,
                    date: record.sealedDate("date") ?? .distantPast,
                    payee: record.sealedText("payee") ?? "",
                    amountCents: record.sealedInt("amountCents") ?? 0,
                    isIncome: record.sealedText("kindRaw") == "income",
                    categoryID: record.sealedUUID("categoryID"),
                    memberID: record.sealedUUID("memberID"),
                    billID: record.sealedUUID("billID"),
                    billDueDate: record.sealedDate("billDueDate"),
                    splits: splits.count > 1 ? splits : [],
                    stashCents: record.sealedInt("stashCents") ?? 0,
                    placeName: record.sealedText("placeName")
                ))
            case "Bill":
                bills.append(SufficeBill(
                    id: id,
                    name: record.sealedText("name") ?? "",
                    amountCents: record.sealedInt("amountCents") ?? 0,
                    isVariable: record.sealedBool("isVariable") ?? false,
                    dueDay: record.sealedInt("dueDay") ?? 1,
                    frequency: SufficeBill.Frequency(rawValue: record.sealedText("frequencyRaw") ?? "monthly") ?? .monthly,
                    interval: record.sealedInt("interval") ?? 1,
                    startDate: record.sealedDate("startDate") ?? .distantPast,
                    endDate: record.sealedDate("endDate"),
                    categoryID: record.sealedUUID("categoryID"),
                    isAutopay: record.sealedBool("isAutopay") ?? false,
                    isActive: record.sealedBool("isActive") ?? true
                ))
            case "BudgetMember":
                members.append(SufficeMember(id: id, name: record.sealedText("name") ?? ""))
            case "PayeeRule":
                if let key = record.sealedText("payeeKey"), let category = record.sealedUUID("categoryID") {
                    rules[key] = category
                }
            default:
                break
            }
        }
    }

    /// "LedgerEntry.6F1C…" → ("LedgerEntry", 6F1C…).
    static func parse(_ recordName: String) -> (String, UUID)? {
        guard let dot = recordName.firstIndex(of: ".") else { return nil }
        guard let id = UUID(uuidString: String(recordName[recordName.index(after: dot)...])) else { return nil }
        return (String(recordName[..<dot]), id)
    }

    var isEmpty: Bool { categories.isEmpty && entries.isEmpty && bills.isEmpty }

    // MARK: Budgets

    func category(_ id: UUID?) -> SufficeCategory? {
        id.flatMap { id in categories.first { $0.id == id } }
    }

    /// The top-level budget a category belongs to (itself, for a top-level one).
    func topLevel(_ id: UUID?) -> SufficeCategory? {
        guard let category = category(id) else { return nil }
        return category.parentID.flatMap { self.category($0) } ?? category
    }

    /// A budget by what someone called it: "groceries", "eating out", "gas".
    func findCategory(_ spoken: String) -> SufficeCategory? {
        let key = Self.fold(spoken)
        guard !key.isEmpty else { return nil }
        let live = categories.filter { !$0.isArchived }
        if let exact = live.first(where: { Self.fold($0.name) == key }) { return exact }
        if let partial = live.first(where: { Self.fold($0.name).contains(key) || key.contains(Self.fold($0.name)) }) { return partial }
        // Singular and plural: "grocery" / "groceries".
        let stem = String(key.prefix(5))
        return stem.count >= 4 ? live.first { Self.fold($0.name).hasPrefix(stem) } : nil
    }

    func isActive(_ category: SufficeCategory, in month: EmberRange, calendar: Calendar = .current) -> Bool {
        guard !category.isArchived else { return false }
        let starts = calendar.dateInterval(of: .month, for: category.startMonth)?.start ?? category.startMonth
        if category.startMonth > .distantPast, starts > month.start { return false }
        if !category.repeatsMonthly, category.startMonth > .distantPast, starts != month.start { return false }
        return true
    }

    /// The month's budgets, each with its subcategories, as Suffice shows them.
    func statuses(in month: EmberRange) -> [SufficeBudgetStatus] {
        var spent: [UUID?: Int] = [:]
        for entry in entries where !entry.isIncome && month.contains(entry.date) {
            for part in entry.spendingParts { spent[part.categoryID, default: 0] += part.amountCents }
        }
        let sorted = categories.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        return sorted.filter { $0.parentID == nil }.compactMap { parent in
            let children = sorted.filter { $0.parentID == parent.id }.compactMap { child -> SufficeBudgetStatus? in
                let childSpent = spent[child.id] ?? 0
                let active = isActive(child, in: month)
                guard active || childSpent > 0 else { return nil }
                return SufficeBudgetStatus(category: child, spentCents: childSpent, limitCents: active ? child.limitCents : 0)
            }
            let total = (spent[parent.id] ?? 0) + children.reduce(0) { $0 + $1.spentCents }
            let active = isActive(parent, in: month)
            guard active || total > 0 else { return nil }
            let childLimits = children.reduce(0) { $0 + $1.limitCents }
            let limit = !active ? 0 : (parent.limitCents > 0 || children.isEmpty ? parent.limitCents : childLimits)
            return SufficeBudgetStatus(category: parent, spentCents: total, limitCents: limit, children: children)
        }
    }

    // MARK: Spending

    struct Spending: Sendable {
        var totalCents: Int
        var incomeCents: Int
        var count: Int
        /// Top-level budget name → cents, largest first.
        var byBudget: [(String, Int)]
        var byPayee: [(String, Int)]
        var byMember: [(String, Int)]
        var largest: [SufficeEntry]
    }

    /// Spending in a range, optionally only one budget, one place or one person.
    func spending(in range: EmberRange, budget: SufficeCategory? = nil, payee: String? = nil, memberID: UUID? = nil) -> Spending {
        let inRange = entries.filter { range.contains($0.date) }
        let payeeKey = payee.map(Self.fold).flatMap { $0.isEmpty ? nil : $0 }
        let budgetIDs: Set<UUID>? = budget.map { budget in
            Set([budget.id] + categories.filter { $0.parentID == budget.id }.map(\.id))
        }
        var total = 0
        var count = 0
        var byBudget: [String: Int] = [:]
        var byPayee: [String: Int] = [:]
        var byMember: [String: Int] = [:]
        var matched: [SufficeEntry] = []
        for entry in inRange where !entry.isIncome {
            if let payeeKey, !Self.fold(entry.payee).contains(payeeKey) { continue }
            if let memberID, entry.memberID != memberID { continue }
            var cents = 0
            for part in entry.spendingParts {
                if let budgetIDs, !(part.categoryID.map(budgetIDs.contains) ?? false) { continue }
                cents += part.amountCents
                let name = topLevel(part.categoryID)?.name ?? "Uncategorized"
                byBudget[name, default: 0] += part.amountCents
            }
            guard cents > 0 else { continue }
            total += cents
            count += 1
            byPayee[entry.payee.isEmpty ? "Unknown" : entry.payee, default: 0] += cents
            let who = members.first { $0.id == entry.memberID }?.name ?? "Unassigned"
            byMember[who, default: 0] += cents
            matched.append(entry)
        }
        let income = inRange.filter(\.isIncome).reduce(0) { $0 + $1.amountCents }
        func ranked(_ values: [String: Int]) -> [(String, Int)] { values.sorted { $0.value > $1.value }.map { ($0.key, $0.value) } }
        return Spending(
            totalCents: total,
            incomeCents: income,
            count: count,
            byBudget: ranked(byBudget),
            byPayee: ranked(byPayee),
            byMember: ranked(byMember),
            largest: Array(matched.sorted { $0.amountCents > $1.amountCents }.prefix(5))
        )
    }

    // MARK: Bills

    /// Due dates in a range, paid or not; late ones up to 45 days back are included when the
    /// range starts today.
    func dues(in range: EmberRange, includeLate: Bool = true, now: Date = .now, calendar: Calendar = .current) -> [SufficeDue] {
        let today = calendar.startOfDay(for: now)
        let lateFrom = includeLate && range.start <= today ? (calendar.date(byAdding: .day, value: -45, to: today) ?? today) : range.start
        let payments = entries.filter { $0.billID != nil }
        var result: [SufficeDue] = []
        for bill in bills where bill.isActive {
            for date in occurrences(of: bill, from: lateFrom, to: range.end, calendar: calendar) {
                let paid = payment(for: bill, dueOn: date, payments: payments, calendar: calendar) != nil
                // Before the range: only the unpaid (late) ones.
                if date < range.start && paid { continue }
                result.append(SufficeDue(bill: bill, date: date, isPaid: paid))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    func findBill(_ spoken: String) -> SufficeBill? {
        let key = Self.fold(spoken)
        let live = bills.filter(\.isActive)
        return live.first { Self.fold($0.name) == key }
            ?? live.first { Self.fold($0.name).contains(key) || key.contains(Self.fold($0.name)) }
    }

    func occurrences(of bill: SufficeBill, from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        let from = calendar.startOfDay(for: start)
        let hasStart = bill.startDate > .distantPast
        let first = hasStart ? calendar.startOfDay(for: bill.startDate) : .distantPast
        let last = bill.endDate.map { calendar.startOfDay(for: $0) }
        let interval = max(bill.interval, 1)
        var dates: [Date] = []
        func keep(_ date: Date) -> Bool {
            date >= from && date < end && date >= first && (last.map { date <= $0 } ?? true)
        }
        func monthStart(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)?.start ?? date }
        switch bill.frequency {
        case .once:
            if hasStart, keep(first) { dates.append(first) }
        case .weekly:
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
            let anchor = monthStart(hasStart ? first : from)
            let monthsIn = calendar.dateComponents([.month], from: anchor, to: monthStart(from)).month ?? 0
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

    func payment(for bill: SufficeBill, dueOn due: Date, payments: [SufficeEntry], calendar: Calendar = .current) -> SufficeEntry? {
        payments.filter { entry in
            guard entry.billID == bill.id else { return false }
            if let paidFor = entry.billDueDate { return calendar.isDate(paidFor, inSameDayAs: due) }
            return calendar.isDate(entry.date, equalTo: due, toGranularity: .month)
        }.max { $0.date < $1.date }
    }

    // MARK: Writing

    /// A new expense, as Suffice's Log Spending saves one. Returns the record to save.
    @MainActor
    static func newExpense(in zone: EmberZone, payee: String, amountCents: Int, categoryID: UUID?, memberID: UUID?,
                           date: Date = .now, billID: UUID? = nil, billDueDate: Date? = nil, note: String = "") -> CKRecord {
        let id = UUID()
        let record = zone.newRecord(type: "LedgerEntry", name: "LedgerEntry.\(id.uuidString)")
        let now = Date.now
        let values = record.encryptedValues
        values["date"] = date
        values["payee"] = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        values["amountCents"] = amountCents
        values["kindRaw"] = "expense"
        values["categoryID"] = categoryID?.uuidString
        values["memberID"] = memberID?.uuidString
        values["note"] = note
        values["billID"] = billID?.uuidString
        values["billDueDate"] = billDueDate
        values["isReviewed"] = true
        values["splitsJSON"] = ""
        values["receiptSourceRaw"] = ""
        values["receiptLink"] = ""
        values["stashCents"] = 0
        values["taxTagRaw"] = ""
        values["createdAt"] = now
        return record
    }

    /// The budget a place always goes to, from Suffice's "Always use this budget".
    func ruleCategory(for payee: String) -> UUID? {
        rules[payee.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// The budget person matching a household member's name.
    func member(named name: String?) -> SufficeMember? {
        guard let name else { return nil }
        let key = Self.fold(name)
        return members.first { Self.fold($0.name) == key } ?? members.first { Self.fold($0.name).hasPrefix(key.split(separator: " ").first.map(String.init) ?? key) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }
}
