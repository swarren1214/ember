import Foundation

// Ember's answers about the family's data, worked out on the device: the numbers are computed
// here and the model only words them. Shared by the iPhone (which adds cards and actions) and
// the Watch (which answers on its own, away from the iPhone).
//
// Each answer is facts for the model, not prose for the person: short lines with the numbers,
// the exact range used, and what's missing and why.

nonisolated struct EmberRow: Sendable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var value: String = ""
    var detail: String = ""
    /// Shown as a check (done), an open circle (to do) or nothing.
    var done: Bool? = nil
}

nonisolated struct EmberAnswer: Sendable {
    /// What the model reads.
    var facts: String
    /// What the card shows (title, big value, rows).
    var title: String = ""
    var value: String = ""
    var subtitle: String = ""
    var rows: [EmberRow] = []
    /// 0…1 for a progress bar (a budget), when there is one.
    var fraction: Double?

    static func missing(_ facts: String) -> EmberAnswer { EmberAnswer(facts: facts) }
}

nonisolated enum EmberMoney {
    /// "$86", whole dollars.
    static func text(_ cents: Int, code: String = "USD") -> String {
        (Double(cents) / 100).formatted(.currency(code: code).precision(.fractionLength(0)))
    }

    /// "$12.50" when there are cents, "$12" when not.
    static func exact(_ cents: Int, code: String = "USD") -> String {
        let digits = cents % 100 == 0 ? 0 : 2
        return (Double(cents) / 100).formatted(.currency(code: code).precision(.fractionLength(digits)))
    }
}

nonisolated enum EmberSkills {
    // MARK: Money (Suffice)

    static func spending(_ ledger: SufficeLedger, range spoken: String, budget: String, place: String, person: String,
                         now: Date = .now) -> EmberAnswer {
        let range = EmberDates.range(spoken, lean: .past, fallback: "this week", now: now).throughToday(now: now)
        let category = budget.isEmpty ? nil : ledger.findCategory(budget)
        if !budget.isEmpty, category == nil {
            let names = ledger.categories.filter { !$0.isArchived && $0.parentID == nil }.map(\.name)
            return .missing("Suffice has no budget called \"\(budget)\". Its budgets: \(names.joined(separator: ", ")).")
        }
        let member = person.isEmpty ? nil : ledger.member(named: person)
        let result = ledger.spending(in: range, budget: category, payee: place.isEmpty ? nil : place, memberID: member?.id)
        let previousRange = range.previous()
        let previous = ledger.spending(in: previousRange, budget: category, payee: place.isEmpty ? nil : place, memberID: member?.id)
        var scope: [String] = []
        if let category { scope.append("in \(category.name)") }
        if !place.isEmpty { scope.append("at \(place)") }
        if let member { scope.append("by \(member.name)") }
        var lines = ["Spent \(scope.joined(separator: " ")) \(range.label()) (\(range.days) days): \(EmberMoney.text(result.totalCents)) across \(result.count) purchases."]
        if result.count > 0, category == nil {
            lines.append("By budget: " + result.byBudget.prefix(5).map { "\($0.0) \(EmberMoney.text($0.1))" }.joined(separator: ", "))
        }
        if result.count > 0, place.isEmpty {
            lines.append("Biggest places: " + result.byPayee.prefix(3).map { "\($0.0) \(EmberMoney.text($0.1))" }.joined(separator: ", "))
        }
        let delta = result.totalCents - previous.totalCents
        lines.append("The \(previousRange.days) days before (\(previousRange.label())): \(EmberMoney.text(previous.totalCents)) (\(delta >= 0 ? "up" : "down") \(EmberMoney.text(abs(delta)))).")
        if result.incomeCents > 0, category == nil, place.isEmpty { lines.append("Income in that time: \(EmberMoney.text(result.incomeCents)).") }

        let rows = (category == nil ? result.byBudget : result.byPayee).prefix(5).map { EmberRow(title: $0.0, value: EmberMoney.text($0.1)) }
        return EmberAnswer(facts: lines.joined(separator: "\n"),
                           title: "Spent \(range.label())", value: EmberMoney.text(result.totalCents),
                           subtitle: scope.isEmpty ? "\(result.count) purchases" : scope.joined(separator: " ").capitalizedFirst,
                           rows: Array(rows))
    }

    static func budgets(_ ledger: SufficeLedger, budget: String, month spoken: String, now: Date = .now) -> EmberAnswer {
        let month = EmberDates.range(spoken.isEmpty ? "this month" : spoken, lean: .past, fallback: "this month", now: now)
        let calendar = Calendar.current
        let monthRange = calendar.dateInterval(of: .month, for: month.start).map { EmberRange(start: $0.start, end: $0.end) } ?? month
        let statuses = ledger.statuses(in: monthRange)
        guard !statuses.isEmpty else { return .missing("Suffice has no budgets set for \(monthRange.label()).") }
        let isCurrent = monthRange.contains(now)
        let daysLeft = isCurrent ? max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: monthRange.end).day ?? 0) : 0
        if !budget.isEmpty {
            guard let category = ledger.findCategory(budget),
                  let status = statuses.first(where: { $0.category.id == category.id || $0.children.contains { $0.category.id == category.id } })
            else {
                return .missing("Suffice has no budget called \"\(budget)\". Its budgets: \(statuses.map(\.category.name).joined(separator: ", ")).")
            }
            let one = status.category.id == category.id ? status : status.children.first { $0.category.id == category.id }!
            var line = "\(one.category.name), \(monthRange.label()): \(EmberMoney.text(one.leftCents)) left of \(EmberMoney.text(one.limitCents)) (\(EmberMoney.text(one.spentCents)) spent)."
            if one.leftCents < 0 { line = "\(one.category.name), \(monthRange.label()): \(EmberMoney.text(-one.leftCents)) over its \(EmberMoney.text(one.limitCents)) (\(EmberMoney.text(one.spentCents)) spent)." }
            if isCurrent, daysLeft > 0, one.leftCents > 0 { line += " \(daysLeft) days left in the month, about \(EmberMoney.text(one.leftCents / daysLeft)) a day." }
            let rows = one.children.map { EmberRow(title: $0.category.name, value: EmberMoney.text($0.leftCents), detail: "\(EmberMoney.text($0.spentCents)) of \(EmberMoney.text($0.limitCents))") }
            return EmberAnswer(facts: line, title: one.category.name, value: EmberMoney.text(one.leftCents),
                               subtitle: "left of \(EmberMoney.text(one.limitCents))", rows: rows,
                               fraction: one.limitCents > 0 ? Double(one.spentCents) / Double(one.limitCents) : nil)
        }
        let limit = statuses.reduce(0) { $0 + $1.limitCents }
        let spent = statuses.reduce(0) { $0 + $1.spentCents }
        var lines = ["\(monthRange.label()): \(EmberMoney.text(spent)) spent of \(EmberMoney.text(limit)) budgeted, \(EmberMoney.text(limit - spent)) left\(isCurrent ? ", \(daysLeft) days to go" : "")."]
        let over = statuses.filter { $0.limitCents > 0 && $0.spentCents > $0.limitCents }
        if !over.isEmpty { lines.append("Over: " + over.map { "\($0.category.name) by \(EmberMoney.text($0.spentCents - $0.limitCents))" }.joined(separator: ", ")) }
        lines.append(statuses.map { "\($0.category.name): \(EmberMoney.text($0.leftCents)) left of \(EmberMoney.text($0.limitCents))" }.joined(separator: "; "))
        let rows = statuses.map { EmberRow(title: $0.category.name, value: EmberMoney.text($0.leftCents), detail: "left of \(EmberMoney.text($0.limitCents))") }
        return EmberAnswer(facts: lines.joined(separator: "\n"), title: "Budgets, \(monthRange.label())", value: EmberMoney.text(limit - spent),
                           subtitle: "left of \(EmberMoney.text(limit))", rows: rows,
                           fraction: limit > 0 ? Double(spent) / Double(limit) : nil)
    }

    static func bills(_ ledger: SufficeLedger, range spoken: String, now: Date = .now) -> EmberAnswer {
        let range = EmberDates.range(spoken.isEmpty ? "next 14 days" : spoken, lean: .future, fallback: "next 14 days", now: now)
        let dues = ledger.dues(in: range, now: now)
        let unpaid = dues.filter { !$0.isPaid }
        let today = Calendar.current.startOfDay(for: now)
        guard !dues.isEmpty else { return EmberAnswer(facts: "No bills due \(range.label()), and none late.", title: "Bills", value: "None due") }
        func when(_ date: Date) -> String {
            if date < today { return "late since \(date.formatted(.dateTime.month(.abbreviated).day()))" }
            if Calendar.current.isDateInToday(date) { return "today" }
            if Calendar.current.isDateInTomorrow(date) { return "tomorrow" }
            return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        let lines = dues.map { due in
            "\(due.bill.name) \(EmberMoney.text(due.bill.amountCents))\(due.bill.isVariable ? " (varies)" : ""): \(due.isPaid ? "paid" : "due \(when(due.date))")\(due.bill.isAutopay ? ", autopay" : "")"
        }
        let total = unpaid.reduce(0) { $0 + $1.bill.amountCents }
        let rows = dues.map { EmberRow(title: $0.bill.name, value: EmberMoney.text($0.bill.amountCents), detail: $0.isPaid ? "Paid" : when($0.date).capitalizedFirst, done: $0.isPaid) }
        return EmberAnswer(facts: "Bills \(range.label()) (and any late): \(unpaid.count) unpaid, \(EmberMoney.text(total)) in all.\n" + lines.joined(separator: "\n"),
                           title: "Bills", value: EmberMoney.text(total), subtitle: "\(unpaid.count) unpaid", rows: rows)
    }

    static func recent(_ ledger: SufficeLedger, range spoken: String, place: String, budget: String, now: Date = .now) -> EmberAnswer {
        let range = EmberDates.range(spoken, lean: .past, fallback: "last 7 days", now: now).throughToday(now: now)
        let category = budget.isEmpty ? nil : ledger.findCategory(budget)
        let ids: Set<UUID>? = category.map { c in Set([c.id] + ledger.categories.filter { $0.parentID == c.id }.map(\.id)) }
        let key = SufficeLedger.fold(place)
        let entries = ledger.entries
            .filter { range.contains($0.date) && !$0.isIncome }
            .filter { key.isEmpty || SufficeLedger.fold($0.payee).contains(key) }
            .filter { entry in ids.map { ids in entry.parts.contains { $0.categoryID.map(ids.contains) ?? false } } ?? true }
            .sorted { $0.date > $1.date }
        guard !entries.isEmpty else { return .missing("No purchases \(range.label())\(place.isEmpty ? "" : " at \(place)").") }
        let lines = entries.prefix(12).map { "\($0.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())): \($0.payee) \(EmberMoney.exact($0.amountCents)) (\(ledger.topLevel($0.categoryID)?.name ?? "uncategorized"))" }
        let rows = entries.prefix(8).map { EmberRow(title: $0.payee, value: EmberMoney.exact($0.amountCents), detail: $0.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
        return EmberAnswer(facts: "\(entries.count) purchases \(range.label()), newest first:\n" + lines.joined(separator: "\n"),
                           title: "Purchases", value: "\(entries.count)", subtitle: range.label(), rows: Array(rows))
    }

    // MARK: Family (Caloma)

    static func chores(_ family: CalomaFamily, day spoken: String, person: String, now: Date = .now) -> EmberAnswer {
        let range = EmberDates.range(spoken, lean: .past, fallback: "today", now: now)
        var items = family.board(on: range.start)
        var who = ""
        if !person.isEmpty {
            guard let member = family.findMember(person) else {
                return .missing("Caloma has nobody called \(person). The family: \(family.members.filter { !$0.isArchived }.map(\.name).joined(separator: ", ")).")
            }
            items = items.filter { $0.memberID == member.id || ($0.chore.upForGrabs && $0.memberID == nil) }
            who = member.name
        }
        guard !items.isEmpty else { return .missing("No chores on Caloma's board \(range.label())\(who.isEmpty ? "" : " for \(who)").") }
        let done = items.filter { $0.status != .open }
        func line(_ item: CalomaBoardItem) -> String {
            let name = item.memberID.map { family.name($0) } ?? "up for grabs"
            let state = switch item.status { case .open: "not done"; case .pending: "done, waiting for a parent's OK"; case .approved: "done" }
            return "\(item.chore.title) (\(name)): \(state)"
        }
        let rows = items.map { EmberRow(title: $0.chore.title, value: $0.memberID.map { family.name($0) } ?? "Anyone",
                                        detail: $0.status == .pending ? "Needs OK" : "", done: $0.status != .open) }
        return EmberAnswer(facts: "Chores \(range.label())\(who.isEmpty ? "" : " for \(who)"): \(done.count) of \(items.count) done.\n" + items.map(line).joined(separator: "\n"),
                           title: who.isEmpty ? "Chores" : "\(who)’s chores", value: "\(done.count) of \(items.count)", subtitle: "done \(range.label())", rows: rows)
    }

    static func approvals(_ family: CalomaFamily) -> EmberAnswer {
        let waiting = family.waitingForApproval
        guard !waiting.isEmpty else { return EmberAnswer(facts: "Nothing is waiting for a parent's OK in Caloma.", title: "Approvals", value: "All clear") }
        let lines = waiting.map { completion -> String in
            let chore = family.chores.first { $0.id == completion.choreID }?.title ?? "A chore"
            return "\(chore) by \(family.name(completion.memberID)), \(completion.day.formatted(.dateTime.weekday(.wide))), \(completion.points) points"
        }
        let rows = waiting.map { completion in
            EmberRow(title: family.chores.first { $0.id == completion.choreID }?.title ?? "Chore", value: family.name(completion.memberID), detail: "\(completion.points) pts")
        }
        return EmberAnswer(facts: "\(waiting.count) chores waiting for a parent's OK:\n" + lines.joined(separator: "\n"),
                           title: "Waiting for your OK", value: "\(waiting.count)", rows: rows)
    }

    static func calendar(_ family: CalomaFamily, range spoken: String, person: String, now: Date = .now) -> EmberAnswer {
        let range = EmberDates.range(spoken, lean: .future, fallback: "today", now: now)
        var occurrences = family.occurrences(in: range)
        var who = ""
        if !person.isEmpty, let member = family.findMember(person) {
            occurrences = occurrences.filter { $0.event.attendeeIDs.isEmpty || $0.event.attendeeIDs.contains(member.id) || $0.event.driverID == member.id }
            who = member.name
        }
        guard !occurrences.isEmpty else { return EmberAnswer(facts: "Nothing on the family calendar \(range.label())\(who.isEmpty ? "" : " for \(who)").", title: "Family calendar", value: "Nothing planned", subtitle: range.label()) }
        func time(_ o: CalomaOccurrence) -> String {
            let day = range.days > 1 ? o.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " " : ""
            return o.event.isAllDay ? "\(day)all day" : day + o.start.formatted(date: .omitted, time: .shortened)
        }
        let lines = occurrences.prefix(25).map { o -> String in
            var line = "\(time(o)): \(o.event.title)"
            if !o.event.location.isEmpty { line += " at \(o.event.location)" }
            if !o.event.attendeeIDs.isEmpty { line += " (\(o.event.attendeeIDs.map { family.name($0) }.joined(separator: ", ")))" }
            if let driver = o.event.driverID { line += ", \(family.name(driver)) driving" }
            if !o.event.bring.isEmpty { line += "; bring \(o.event.bring.joined(separator: ", "))" }
            return line
        }
        let rows = occurrences.prefix(10).map { EmberRow(title: $0.event.title, value: time($0), detail: $0.event.location) }
        return EmberAnswer(facts: "Family calendar \(range.label())\(who.isEmpty ? "" : " for \(who)"):\n" + lines.joined(separator: "\n"),
                           title: "Family calendar", value: "\(occurrences.count) \(occurrences.count == 1 ? "event" : "events")", subtitle: range.label(), rows: Array(rows))
    }

    // MARK: Groceries (BigTable)

    static func groceries(_ list: BigTableGroceries, item: String) -> EmberAnswer {
        guard list.activeRecordName != nil else { return .missing("There's no grocery list in BigTable right now.") }
        if !item.isEmpty {
            let found = list.matching(item)
            guard !found.isEmpty else { return EmberAnswer(facts: "\(item) isn't on the grocery list.", title: "Grocery list", value: "Not on the list") }
            return EmberAnswer(facts: found.map { "\($0.name)\($0.quantity.isEmpty || $0.quantity == "1" ? "" : " (\($0.quantity))") is on the list, \($0.isChecked ? "checked off" : "still to buy")" }.joined(separator: "\n"),
                               title: "Grocery list", value: found[0].isChecked ? "Got it" : "On the list",
                               rows: found.map { EmberRow(title: $0.name, value: $0.quantity, done: $0.isChecked) })
        }
        let left = list.remaining
        let bySection = Dictionary(grouping: left, by: \.section)
        let lines = bySection.keys.sorted().map { section in "\(section): " + bySection[section]!.map(\.name).joined(separator: ", ") }
        let cost = list.estimatedCost.map { ", about \(EmberMoney.text(Int($0 * 100))) for the whole list" } ?? ""
        return EmberAnswer(facts: "\(left.count) of \(list.lines.count) items still to buy\(cost).\n" + lines.joined(separator: "\n"),
                           title: "Grocery list", value: "\(left.count) to buy", subtitle: "of \(list.lines.count) items",
                           rows: left.prefix(12).map { EmberRow(title: $0.name, value: $0.quantity == "1" ? "" : $0.quantity, done: false) })
    }
}

extension String {
    nonisolated var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
