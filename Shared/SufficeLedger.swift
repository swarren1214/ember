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
        let decoder = JSONDecoder()
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
                let splits = splitsJSON.data(using: .utf8).flatMap { try? decoder.decode([SufficeSplit].self, from: $0) } ?? []
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

    /// The month's budgets, each with its subcategories, as Suffice shows them (HearthMoney's
    /// math, the same code Suffice runs).
    func statuses(in month: EmberRange) -> [SufficeBudgetStatus] {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func convert(_ status: HearthMoney.Status) -> SufficeBudgetStatus? {
            guard let category = byID[status.category.id] else { return nil }
            return SufficeBudgetStatus(category: category, spentCents: status.spentCents, limitCents: status.limitCents,
                                       children: status.children.compactMap(convert))
        }
        return HearthMoney.statuses(book.categories, entries: book.entries, in: HearthMoney.Span(start: month.start, end: month.end))
            .compactMap(convert)
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

    /// For an empty answer: how far the mirrored ledger reaches, so a range past its newest entry
    /// reads as "not synced yet", not "nothing was spent".
    func coverageNote(for range: EmberRange) -> String? {
        let dated = entries.filter { $0.date > .distantPast }
        guard let newest = dated.max(by: { $0.date < $1.date }) else {
            return "Ember has no Suffice entries yet (Suffice may not have synced to iCloud)."
        }
        let when = newest.date.formatted(.dateTime.month(.abbreviated).day().year())
        if newest.date < range.start {
            return "Suffice's newest entry that Ember can see is from \(when), before this period, so Suffice may not have synced its latest transactions to iCloud yet. Say that rather than that nothing was spent."
        }
        return "Ember sees \(dated.count) Suffice entries, the newest from \(when)."
    }

    /// Spending in a range, optionally only one budget, one place or one person (HearthMoney's query).
    func spending(in range: EmberRange, budget: SufficeCategory? = nil, payee: String? = nil, memberID: UUID? = nil) -> Spending {
        let book = self.book
        let query = HearthMoney.Query(span: HearthMoney.Span(start: range.start, end: range.end),
                                      member: memberID.flatMap { id in book.members.first { $0.id == id } },
                                      payee: payee, budget: budget.flatMap { book.category($0.id) })
        let result = HearthMoney.run(query, in: book, comparing: false)
        var byMember: [String: Int] = [:]
        for match in result.matches {
            byMember[members.first { $0.id == match.entry.memberID }?.name ?? "Unassigned", default: 0] += match.cents
        }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let largest = result.matches.sorted { $0.entry.amountCents > $1.entry.amountCents }.prefix(5).compactMap { byID[$0.entry.id] }
        return Spending(
            totalCents: result.spentCents,
            incomeCents: result.incomeCents,
            count: result.count,
            byBudget: result.byBudget,
            byPayee: result.byPayee,
            byMember: byMember.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
            largest: Array(largest)
        )
    }

    // MARK: Bills

    /// Due dates in a range, paid or not; late ones up to 45 days back are included when the
    /// range starts today (HearthMoney's math).
    func dues(in range: EmberRange, includeLate: Bool = true, now: Date = .now, calendar: Calendar = .current) -> [SufficeDue] {
        let byID = Dictionary(bills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return HearthMoney.dues(book.bills, entries: book.entries, in: HearthMoney.Span(start: range.start, end: range.end),
                                includeLate: includeLate, now: now, calendar: calendar)
            .compactMap { due in byID[due.bill.id].map { SufficeDue(bill: $0, date: due.date, isPaid: due.isPaid) } }
    }

    func findBill(_ spoken: String) -> SufficeBill? {
        let key = Self.fold(spoken)
        let live = bills.filter(\.isActive)
        return live.first { Self.fold($0.name) == key }
            ?? live.first { Self.fold($0.name).contains(key) || key.contains(Self.fold($0.name)) }
    }

    func occurrences(of bill: SufficeBill, from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        HearthMoney.occurrences(of: Self.money(bill), from: start, to: end, calendar: calendar)
    }

    // MARK: HearthMoney

    /// The budget as HearthMoney's values: what the shared math and answers read.
    var book: HearthMoney.Book {
        HearthMoney.Book(
            categories: categories.map { HearthMoney.Category(id: $0.id, name: $0.name, limitCents: $0.limitCents, parentID: $0.parentID,
                                                              startMonth: $0.startMonth, repeatsMonthly: $0.repeatsMonthly,
                                                              isArchived: $0.isArchived, sortOrder: $0.sortOrder) },
            entries: entries.map { entry in
                HearthMoney.Entry(id: entry.id, date: entry.date, payee: entry.payee, place: entry.placeName, amountCents: entry.amountCents,
                                  isIncome: entry.isIncome, categoryID: entry.categoryID, memberID: entry.memberID, billID: entry.billID,
                                  billDueDate: entry.billDueDate,
                                  splits: entry.splits.map { HearthMoney.Part(categoryID: $0.categoryID, amountCents: $0.amountCents) },
                                  stashCents: entry.stashCents)
            },
            bills: bills.map(Self.money),
            members: members.map { HearthMoney.Member(id: $0.id, name: $0.name) }
        )
    }

    static func money(_ bill: SufficeBill) -> HearthMoney.Bill {
        HearthMoney.Bill(id: bill.id, name: bill.name, amountCents: bill.amountCents, isVariable: bill.isVariable, dueDay: bill.dueDay,
                         frequency: HearthMoney.Bill.Frequency(rawValue: bill.frequency.rawValue) ?? .monthly, interval: bill.interval,
                         startDate: bill.startDate, endDate: bill.endDate, isAutopay: bill.isAutopay, isActive: bill.isActive)
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
