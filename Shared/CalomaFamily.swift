import CloudKit
import Foundation

// Caloma's family as Ember reads it from the "Caloma" zone: people, chores, completions and the
// family calendar, decoded from the same plain record fields Caloma writes (Caloma ›
// CloudRecord.swift), with Caloma's own rules for who has which chore today (ChoreMath, and
// RotationMath, copied in CalomaRotation.swift) and when an event happens (CalendarMath).
// Ember's changes are the ones Caloma's Family service makes: a parent marking a chore done or
// approving one (with the kid's points), and new events.
//
// Keep in step with Caloma: a field renamed there must be renamed here.

nonisolated struct CalomaMember: Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var isKid: Bool
    var isArchived: Bool
}

nonisolated struct CalomaChore: Sendable, Hashable, Identifiable {
    enum Repeat: String, Sendable { case once, daily, weekdays, someDays }

    var id: UUID
    var title: String
    var points: Int
    var assigneeIDs: [UUID]
    var rotates: Bool
    var upForGrabs: Bool
    var repeatRule: Repeat
    var weekdayMask: Int
    var startDate: Date
    var requiresApproval: Bool
    var isArchived: Bool
    var sortOrder: Int
    var priority: Int
    var rotationRule: RotationRule
    var rotationSlot: Int
}

nonisolated struct CalomaCompletion: Sendable, Hashable, Identifiable {
    enum Status: String, Sendable { case pending, approved, sentBack }

    var id: UUID
    var choreID: UUID?
    var memberID: UUID?
    var day: Date
    var status: Status
    var points: Int
    var completedAt: Date
}

nonisolated struct CalomaEvent: Sendable, Hashable, Identifiable {
    enum Repeat: String, Sendable { case never, daily, weekly, monthly, yearly }

    var id: UUID
    var title: String
    var location: String
    var notes: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var attendeeIDs: [UUID]
    var driverID: UUID?
    var repeatRule: Repeat
    var weekdayMask: Int
    var repeatEnd: Date?
    var bring: [String]
    var skippedDays: Set<String>
    var isArchived: Bool
}

nonisolated struct CalomaOccurrence: Sendable, Hashable {
    var event: CalomaEvent
    var start: Date
    var end: Date
}

/// One chore for one person on one day, and where it stands.
nonisolated struct CalomaBoardItem: Sendable, Hashable {
    enum Status: String, Sendable { case open, pending, approved }

    var chore: CalomaChore
    var memberID: UUID?
    var day: Date
    var status: Status
    var completionID: UUID?
}

nonisolated struct CalomaFamily: Sendable {
    var members: [CalomaMember] = []
    var chores: [CalomaChore] = []
    var completions: [CalomaCompletion] = []
    var events: [CalomaEvent] = []

    static let zoneName = "Caloma"

    init() {}

    init(records: [CKRecord]) {
        for record in records {
            guard let id = UUID(uuidString: record.recordID.recordName) else { continue }
            switch record.recordType {
            case "Member":
                members.append(CalomaMember(id: id, name: record.plainText("name") ?? "",
                                            isKid: record.plainText("roleRaw") == "kid",
                                            isArchived: record.plainBool("isArchived") ?? false))
            case "Chore":
                let start = record.plainDate("startDate") ?? .distantPast
                let rule = RotationRule(
                    mode: RotationMode(rawValue: record.plainText("rotationModeRaw") ?? "") ?? .turns,
                    period: RotationPeriod(rawValue: record.plainText("rotationPeriodRaw") ?? "") ?? .week,
                    weekday: record.plainInt("rotationWeekday") ?? 0,
                    anchor: record.plainDate("rotationAnchor") ?? start,
                    adjustments: RotationAdjustments(raw: record.plainText("rotationAdjustRaw") ?? "")
                )
                chores.append(CalomaChore(
                    id: id,
                    title: record.plainText("title") ?? "",
                    points: record.plainInt("points") ?? 0,
                    assigneeIDs: Self.ids(record.plainText("assigneeIDsRaw")),
                    rotates: record.plainBool("rotates") ?? false,
                    upForGrabs: record.plainBool("upForGrabs") ?? false,
                    repeatRule: CalomaChore.Repeat(rawValue: record.plainText("repeatRaw") ?? "") ?? .daily,
                    weekdayMask: record.plainInt("weekdayMask") ?? 0,
                    startDate: start,
                    requiresApproval: record.plainBool("requiresApproval") ?? true,
                    isArchived: record.plainBool("isArchived") ?? false,
                    sortOrder: record.plainInt("sortOrder") ?? 0,
                    priority: record.plainInt("priorityRaw") ?? 0,
                    rotationRule: rule,
                    rotationSlot: record.plainInt("rotationSlot") ?? 0
                ))
            case "ChoreCompletion":
                completions.append(CalomaCompletion(
                    id: id,
                    choreID: record.plainUUID("choreID"),
                    memberID: record.plainUUID("memberID"),
                    day: record.plainDate("day") ?? .distantPast,
                    status: CalomaCompletion.Status(rawValue: record.plainText("statusRaw") ?? "") ?? .pending,
                    points: record.plainInt("points") ?? 0,
                    completedAt: record.plainDate("completedAt") ?? .distantPast
                ))
            case "FamilyEvent":
                events.append(CalomaEvent(
                    id: id,
                    title: record.plainText("title") ?? "",
                    location: record.plainText("location") ?? "",
                    notes: record.plainText("notes") ?? "",
                    start: record.plainDate("start") ?? .distantPast,
                    end: record.plainDate("end") ?? .distantPast,
                    isAllDay: record.plainBool("isAllDay") ?? false,
                    attendeeIDs: Self.ids(record.plainText("attendeeIDsRaw")),
                    driverID: record.plainUUID("driverID"),
                    repeatRule: CalomaEvent.Repeat(rawValue: record.plainText("repeatRaw") ?? "") ?? .never,
                    weekdayMask: record.plainInt("weekdayMask") ?? 0,
                    repeatEnd: record.plainDate("repeatEnd"),
                    bring: (record.plainText("bringRaw") ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    skippedDays: Set((record.plainText("skippedDaysRaw") ?? "").split(separator: ",").map(String.init)),
                    isArchived: record.plainBool("isArchived") ?? false
                ))
            default:
                break
            }
        }
    }

    static func ids(_ raw: String?) -> [UUID] {
        (raw ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    var isEmpty: Bool { members.isEmpty && chores.isEmpty && events.isEmpty }

    func member(_ id: UUID?) -> CalomaMember? { id.flatMap { id in members.first { $0.id == id } } }

    func name(_ id: UUID?) -> String { member(id)?.name ?? "Someone" }

    /// A person by what someone called them ("Max", "max's").
    func findMember(_ spoken: String) -> CalomaMember? {
        let key = SufficeLedger.fold(spoken.replacingOccurrences(of: "'s", with: ""))
        guard !key.isEmpty else { return nil }
        let live = members.filter { !$0.isArchived }
        return live.first { SufficeLedger.fold($0.name) == key }
            ?? live.first { SufficeLedger.fold($0.name).split(separator: " ").first.map(String.init) == key }
    }

    func findChore(_ spoken: String) -> CalomaChore? {
        let key = SufficeLedger.fold(spoken)
        let live = chores.filter { !$0.isArchived }
        return live.first { SufficeLedger.fold($0.title) == key }
            ?? live.first { SufficeLedger.fold($0.title).contains(key) || key.contains(SufficeLedger.fold($0.title)) }
    }

    // MARK: Chores (ChoreMath)

    static func bit(forWeekday weekday: Int) -> Int { 1 << (weekday - 1) }

    func occurs(_ chore: CalomaChore, on day: Date, calendar: Calendar = .current) -> Bool {
        guard !chore.isArchived else { return false }
        let start = calendar.startOfDay(for: chore.startDate)
        let date = calendar.startOfDay(for: day)
        guard date >= start else { return false }
        let weekday = calendar.component(.weekday, from: date)
        switch chore.repeatRule {
        case .once: return date == start
        case .daily: return true
        case .weekdays: return 0b0111110 & Self.bit(forWeekday: weekday) != 0
        case .someDays: return chore.weekdayMask & Self.bit(forWeekday: weekday) != 0
        }
    }

    func assignees(of chore: CalomaChore, on day: Date, calendar: Calendar = .current) -> [UUID] {
        guard chore.rotates, !chore.upForGrabs, chore.assigneeIDs.count > 1 else { return chore.assigneeIDs }
        return RotationMath.assignees(slot: chore.rotationSlot, on: day, members: chore.assigneeIDs, rule: chore.rotationRule, calendar: calendar)
    }

    /// Everything on the chore board for a day, as Caloma's board shows it.
    func board(on day: Date, calendar: Calendar = .current) -> [CalomaBoardItem] {
        let date = calendar.startOfDay(for: day)
        var result: [CalomaBoardItem] = []
        let ordered = chores.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return (a.sortOrder, a.title) < (b.sortOrder, b.title)
        }
        func status(_ completion: CalomaCompletion?) -> CalomaBoardItem.Status {
            switch completion?.status {
            case .pending: .pending
            case .approved: .approved
            case .sentBack, nil: .open
            }
        }
        for chore in ordered where !chore.isArchived {
            let start = calendar.startOfDay(for: chore.startDate)
            let occurrence: Date
            if chore.repeatRule == .once {
                guard date >= start else { continue }
                occurrence = start
            } else {
                guard occurs(chore, on: date, calendar: calendar) else { continue }
                occurrence = date
            }
            let forDay = completions.filter { $0.choreID == chore.id && calendar.isDate($0.day, inSameDayAs: occurrence) }
            if chore.upForGrabs {
                let claim = forDay.first { $0.status != .sentBack }
                if chore.repeatRule == .once, date > start, claim?.status == .approved,
                   let claim, !calendar.isDate(claim.completedAt, inSameDayAs: date) { continue }
                result.append(CalomaBoardItem(chore: chore, memberID: claim?.memberID, day: occurrence, status: status(claim), completionID: claim?.id))
                continue
            }
            for member in assignees(of: chore, on: date, calendar: calendar) {
                let live = forDay.filter { $0.memberID == member }.first { $0.status != .sentBack }
                if chore.repeatRule == .once, date > start, let live, live.status == .approved,
                   !calendar.isDate(live.completedAt, inSameDayAs: date) { continue }
                result.append(CalomaBoardItem(chore: chore, memberID: member, day: occurrence, status: status(live), completionID: live?.id))
            }
        }
        return result
    }

    /// Chores marked done that wait for a parent's OK.
    var waitingForApproval: [CalomaCompletion] {
        completions.filter { $0.status == .pending }.sorted { $0.completedAt < $1.completedAt }
    }

    // MARK: Calendar (CalendarMath)

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func happens(_ event: CalomaEvent, on day: Date, calendar: Calendar = .current) -> Bool {
        guard !event.isArchived else { return false }
        let date = calendar.startOfDay(for: day)
        let first = calendar.startOfDay(for: event.start)
        guard date >= first else { return false }
        if let end = event.repeatEnd, date > calendar.startOfDay(for: end) { return false }
        if event.skippedDays.contains(Self.dayKey(date, calendar: calendar)) { return false }
        switch event.repeatRule {
        case .never: return date == first
        case .daily: return true
        case .weekly:
            let mask = event.weekdayMask == 0 ? Self.bit(forWeekday: calendar.component(.weekday, from: first)) : event.weekdayMask
            return mask & Self.bit(forWeekday: calendar.component(.weekday, from: date)) != 0
        case .monthly:
            return calendar.component(.day, from: date) == calendar.component(.day, from: first)
        case .yearly:
            return calendar.component(.day, from: date) == calendar.component(.day, from: first)
                && calendar.component(.month, from: date) == calendar.component(.month, from: first)
        }
    }

    /// Every occurrence overlapping a range, all-day first then by time.
    func occurrences(in range: EmberRange, calendar: Calendar = .current) -> [CalomaOccurrence] {
        var result: [CalomaOccurrence] = []
        let first = calendar.startOfDay(for: range.start)
        for event in events where !event.isArchived {
            let spanDays = Int(ceil(max(event.end.timeIntervalSince(event.start), 0) / 86_400))
            var day = calendar.date(byAdding: .day, value: -spanDays, to: first) ?? first
            while day < range.end {
                if happens(event, on: day, calendar: calendar) {
                    let time = calendar.dateComponents([.hour, .minute], from: event.start)
                    let start = event.isAllDay ? day : (calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day)
                    let end = start.addingTimeInterval(max(event.end.timeIntervalSince(event.start), 0))
                    if start < range.end && max(end, start.addingTimeInterval(1)) > range.start {
                        result.append(CalomaOccurrence(event: event, start: start, end: end))
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return result.sorted { a, b in
            if a.event.isAllDay != b.event.isAllDay { return a.event.isAllDay }
            return (a.start, a.event.title) < (b.start, b.event.title)
        }
    }

    // MARK: Writing (Caloma's Family service)

    /// A parent marks a chore done for someone: approved straight away, with the kid's points.
    @MainActor
    static func markDoneRecords(_ item: CalomaBoardItem, for memberID: UUID, family: CalomaFamily, in zone: EmberZone) -> [CKRecord] {
        let id = UUID()
        let completion = zone.newRecord(type: "ChoreCompletion", name: id.uuidString)
        completion["choreID"] = item.chore.id.uuidString
        completion["memberID"] = memberID.uuidString
        completion["day"] = item.day
        completion["statusRaw"] = "approved"
        completion["points"] = item.chore.points
        completion["completedAt"] = Date.now
        completion["reviewedAt"] = Date.now
        var records = [completion]
        if family.member(memberID)?.isKid ?? true {
            records.append(pointsRecord(memberID: memberID, points: item.chore.points, refID: id, note: item.chore.title, in: zone))
        }
        return records
    }

    /// Approves a kid's done chore: approved, and the points it earns.
    @MainActor
    static func approveRecords(_ completion: CalomaCompletion, family: CalomaFamily, in zone: EmberZone) -> [CKRecord]? {
        guard completion.status == .pending, let existing = zone.records[completion.id.uuidString] else { return nil }
        let record = existing.copy() as! CKRecord
        record["statusRaw"] = "approved"
        record["reviewedAt"] = Date.now
        var records = [record]
        if let memberID = completion.memberID, family.member(memberID)?.isKid ?? true {
            let title = family.chores.first { $0.id == completion.choreID }?.title ?? "Chore"
            records.append(pointsRecord(memberID: memberID, points: completion.points, refID: completion.id, note: title, in: zone))
        }
        return records
    }

    @MainActor
    private static func pointsRecord(memberID: UUID, points: Int, refID: UUID, note: String, in zone: EmberZone) -> CKRecord {
        let record = zone.newRecord(type: "PointEntry", name: UUID().uuidString)
        record["memberID"] = memberID.uuidString
        record["points"] = points
        record["kindRaw"] = "chore"
        record["refID"] = refID.uuidString
        record["date"] = Date.now
        record["note"] = note
        return record
    }

    /// A new family event, as Caloma's editor saves one.
    @MainActor
    static func newEventRecord(title: String, start: Date, end: Date, isAllDay: Bool, location: String, notes: String,
                               attendeeIDs: [UUID], in zone: EmberZone) -> CKRecord {
        let record = zone.newRecord(type: "FamilyEvent", name: UUID().uuidString)
        record["title"] = title
        record["symbol"] = "calendar"
        record["location"] = location
        record["notes"] = notes
        record["start"] = start
        record["end"] = end
        record["isAllDay"] = isAllDay
        record["attendeeIDsRaw"] = attendeeIDs.map(\.uuidString).joined(separator: ",")
        record["repeatRaw"] = "never"
        record["weekdayMask"] = 0
        record["alertMinutes"] = -1
        record["bringRaw"] = ""
        record["showInKidView"] = true
        record["countsDown"] = false
        record["skippedDaysRaw"] = ""
        record["isArchived"] = false
        record["createdAt"] = Date.now
        return record
    }
}
