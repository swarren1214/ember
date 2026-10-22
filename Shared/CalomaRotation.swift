// Copied from Caloma (Caloma/Models/RotationMath.swift) unchanged, so Ember knows whose turn
// a rotating chore is exactly as Caloma does. Keep the two in step.

import Foundation

// Rotations: who has a chore (or a whole group of chores) on a day when people take turns or
// split the work. One system for both: a group's rotation is copied onto each of its chores,
// so everything that asks "who does this today?" asks `ChoreMath.assignees`, which asks here.

/// How the people in a rotation share it.
nonisolated enum RotationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// One person at a time has it all, then hands it to the next.
    case turns
    /// Everyone gets some of the chores; who does which shifts every turn.
    case split
    /// No rotation: everyone does every chore.
    case everyone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turns: "Take Turns"
        case .split: "Split It Up"
        case .everyone: "Everyone Does It"
        }
    }

    var detail: String {
        switch self {
        case .turns: "One person has it all, then hands it to the next."
        case .split: "Everyone gets some of the chores. Who does which shifts every turn."
        case .everyone: "No rotation: each person does every chore."
        }
    }

    var symbol: String {
        switch self {
        case .turns: "arrow.triangle.2.circlepath"
        case .split: "square.split.2x2"
        case .everyone: "person.3"
        }
    }
}

/// How often a rotation moves on to the next turn.
nonisolated enum RotationPeriod: String, CaseIterable, Identifiable, Codable, Sendable {
    case day, week, twoWeeks, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Daily"
        case .week: "Weekly"
        case .twoWeeks: "2 Weeks"
        case .month: "Monthly"
        }
    }

    /// "week", for "Max's week".
    var noun: String {
        switch self {
        case .day: "day"
        case .week: "week"
        case .twoWeeks: "turn"
        case .month: "month"
        }
    }

    /// Whether a weekday picks when it switches.
    var usesWeekday: Bool { self == .week || self == .twoWeeks }
}

/// Changes to the plain order: skipped turns, swaps and pauses. Each is keyed by the turn's
/// index (`RotationMath.periodIndex`). Stored as "shift:12,swap:13,pause:20".
nonisolated struct RotationAdjustments: Hashable, Sendable {
    /// From this turn on, everyone moves up one (the person whose turn it was is skipped).
    var shifts: Set<Int> = []
    /// This turn and the next trade people.
    var swaps: Set<Int> = []
    /// Nobody has this turn; the line waits and picks up after.
    var pauses: Set<Int> = []

    init() {}

    init(raw: String) {
        for part in raw.split(separator: ",") {
            let pieces = part.split(separator: ":")
            guard pieces.count == 2, let index = Int(pieces[1]) else { continue }
            switch pieces[0] {
            case "shift": shifts.insert(index)
            case "swap": swaps.insert(index)
            case "pause": pauses.insert(index)
            default: break
            }
        }
    }

    var raw: String {
        (shifts.sorted().map { "shift:\($0)" } + swaps.sorted().map { "swap:\($0)" } + pauses.sorted().map { "pause:\($0)" })
            .joined(separator: ",")
    }

    var isEmpty: Bool { shifts.isEmpty && swaps.isEmpty && pauses.isEmpty }

    /// Drops swaps long past, so the stored text doesn't grow forever. Shifts and pauses are
    /// kept: they still count toward who's next.
    func trimmed(before index: Int) -> RotationAdjustments {
        var copy = self
        copy.swaps = swaps.filter { $0 >= index - 1 }
        return copy
    }
}

/// Everything that decides whose turn it is.
nonisolated struct RotationRule: Hashable, Sendable {
    var mode: RotationMode = .turns
    var period: RotationPeriod = .week
    /// The day a weekly rotation switches (1 Sunday … 7 Saturday); 0 is the calendar's first
    /// day of the week.
    var weekday: Int = 0
    /// Turn 0 is the one containing this day.
    var anchor: Date
    var adjustments = RotationAdjustments()
}

nonisolated enum RotationMath {
    // MARK: Turns in time

    /// Which turn a day falls in: 0 for the anchor's, negative before it.
    static func periodIndex(of day: Date, rule: RotationRule, calendar: Calendar = .current) -> Int {
        switch rule.period {
        case .day:
            return days(from: calendar.startOfDay(for: rule.anchor), to: calendar.startOfDay(for: day), calendar: calendar)
        case .week:
            return weeks(from: rule.anchor, to: day, weekday: rule.weekday, calendar: calendar)
        case .twoWeeks:
            return floorDiv(weeks(from: rule.anchor, to: day, weekday: rule.weekday, calendar: calendar), 2)
        case .month:
            let a = calendar.dateComponents([.year, .month], from: rule.anchor)
            let b = calendar.dateComponents([.year, .month], from: day)
            return ((b.year ?? 0) * 12 + (b.month ?? 0)) - ((a.year ?? 0) * 12 + (a.month ?? 0))
        }
    }

    /// The first day of a turn.
    static func start(ofPeriod index: Int, rule: RotationRule, calendar: Calendar = .current) -> Date {
        switch rule.period {
        case .day:
            return calendar.date(byAdding: .day, value: index, to: calendar.startOfDay(for: rule.anchor)) ?? rule.anchor
        case .week:
            return calendar.date(byAdding: .day, value: index * 7, to: weekStart(of: rule.anchor, weekday: rule.weekday, calendar: calendar)) ?? rule.anchor
        case .twoWeeks:
            return calendar.date(byAdding: .day, value: index * 14, to: weekStart(of: rule.anchor, weekday: rule.weekday, calendar: calendar)) ?? rule.anchor
        case .month:
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: rule.anchor)) ?? rule.anchor
            return calendar.date(byAdding: .month, value: index, to: first) ?? rule.anchor
        }
    }

    /// The last day of a turn.
    static func end(ofPeriod index: Int, rule: RotationRule, calendar: Calendar = .current) -> Date {
        let next = start(ofPeriod: index + 1, rule: rule, calendar: calendar)
        return calendar.date(byAdding: .day, value: -1, to: next) ?? next
    }

    /// The start of the week a day is in, with weeks starting on `weekday` (0: the calendar's).
    static func weekStart(of date: Date, weekday: Int, calendar: Calendar = .current) -> Date {
        let first = weekday == 0 ? calendar.firstWeekday : weekday
        let day = calendar.startOfDay(for: date)
        let current = calendar.component(.weekday, from: day)
        let back = (current - first + 7) % 7
        return calendar.date(byAdding: .day, value: -back, to: day) ?? day
    }

    // MARK: Whose turn

    /// Where in the line a turn lands once skips and pauses are counted, or nil while paused.
    static func position(ofPeriod index: Int, adjustments: RotationAdjustments) -> Int? {
        guard !adjustments.pauses.contains(index) else { return nil }
        let paused = adjustments.pauses.filter { $0 < index }.count
        let shifted = adjustments.shifts.filter { $0 <= index }.count
        let base = index - paused + shifted
        // A swap trades this turn with the next one (or the one before, from the other side).
        if adjustments.swaps.contains(index), !adjustments.pauses.contains(index + 1) {
            return position(ofPeriod: index + 1, adjustments: withoutSwaps(adjustments))
        }
        if adjustments.swaps.contains(index - 1), !adjustments.pauses.contains(index - 1) {
            return position(ofPeriod: index - 1, adjustments: withoutSwaps(adjustments))
        }
        return base
    }

    private static func withoutSwaps(_ adjustments: RotationAdjustments) -> RotationAdjustments {
        var copy = adjustments
        copy.swaps = []
        return copy
    }

    /// The person whose turn it is, for a take-turns rotation (or nil while paused).
    static func person(ofPeriod index: Int, members: [UUID], adjustments: RotationAdjustments) -> UUID? {
        guard !members.isEmpty, let position = position(ofPeriod: index, adjustments: adjustments) else { return nil }
        return members[mod(position, members.count)]
    }

    /// Who does one chore of a rotation in a turn. `slot` is the chore's place in its group,
    /// so split-up chores land on different people and move along together.
    static func assignees(slot: Int, ofPeriod index: Int, members: [UUID], rule: RotationRule) -> [UUID] {
        guard !members.isEmpty else { return [] }
        switch rule.mode {
        case .everyone:
            return members
        case .turns:
            return person(ofPeriod: index, members: members, adjustments: rule.adjustments).map { [$0] } ?? []
        case .split:
            guard let position = position(ofPeriod: index, adjustments: rule.adjustments) else { return [] }
            return [members[mod(position + slot, members.count)]]
        }
    }

    /// Who does one chore of a rotation on a day.
    static func assignees(slot: Int, on day: Date, members: [UUID], rule: RotationRule, calendar: Calendar = .current) -> [UUID] {
        assignees(slot: slot, ofPeriod: periodIndex(of: day, rule: rule, calendar: calendar), members: members, rule: rule)
    }

    // MARK: Changing the line

    /// "Skip Max this week". With make-up on, Max trades with the next person, so he takes
    /// their turn instead. Otherwise everyone after him moves up one and he waits his next turn.
    /// When trading isn't possible (the next turn is paused or already traded) it falls back to
    /// moving everyone up. A turn that's already been traded can't be skipped: undo the trade first.
    static func skipping(_ index: Int, makeUp: Bool, adjustments: RotationAdjustments) -> RotationAdjustments {
        guard !isTraded(index, adjustments: adjustments), !adjustments.pauses.contains(index) else { return adjustments }
        var copy = adjustments
        if makeUp && canSwap(index, adjustments: copy) {
            copy.swaps.insert(index)
        } else {
            copy.shifts.insert(index)
        }
        return copy
    }

    /// Whether a turn is one half of a trade.
    static func isTraded(_ index: Int, adjustments: RotationAdjustments) -> Bool {
        adjustments.swaps.contains(index) || adjustments.swaps.contains(index - 1)
    }

    /// Whether a turn can trade with the next one: neither is paused, and neither is already
    /// part of another trade.
    static func canSwap(_ index: Int, adjustments: RotationAdjustments) -> Bool {
        !adjustments.pauses.contains(index) && !adjustments.pauses.contains(index + 1)
            && !adjustments.swaps.contains(index - 1) && !adjustments.swaps.contains(index + 1)
    }

    /// Trades a turn with the next one, or puts them back.
    static func swapping(_ index: Int, adjustments: RotationAdjustments) -> RotationAdjustments {
        var copy = adjustments
        if copy.swaps.contains(index) {
            copy.swaps.remove(index)
        } else if canSwap(index, adjustments: copy) {
            copy.swaps.insert(index)
        }
        return copy
    }

    /// The same switch day whether it's stored as 0 (the calendar's first day) or by number.
    static func sameWeekday(_ a: Int, _ b: Int, calendar: Calendar = .current) -> Bool {
        (a == 0 ? calendar.firstWeekday : a) == (b == 0 ? calendar.firstWeekday : b)
    }

    /// Pauses a turn (nobody has it), or resumes it.
    static func pausing(_ index: Int, adjustments: RotationAdjustments) -> RotationAdjustments {
        var copy = adjustments
        if copy.pauses.contains(index) { copy.pauses.remove(index) } else { copy.pauses.insert(index) }
        return copy
    }

    // MARK: Fair shares

    /// Turns each person has had, from turn `from` up to and including `through`.
    static func turnCounts(from: Int, through: Int, members: [UUID], adjustments: RotationAdjustments) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for member in members { counts[member] = 0 }
        guard from <= through else { return counts }
        for index in from...through {
            if let person = person(ofPeriod: index, members: members, adjustments: adjustments) {
                counts[person, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: Arithmetic

    private static func days(from a: Date, to b: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    private static func weeks(from anchor: Date, to day: Date, weekday: Int, calendar: Calendar) -> Int {
        let a = weekStart(of: anchor, weekday: weekday, calendar: calendar)
        let b = weekStart(of: day, weekday: weekday, calendar: calendar)
        // Days can be 6 or 8 off by a day across a clock change; rounding keeps whole weeks.
        return Int((Double(days(from: a, to: b, calendar: calendar)) / 7).rounded())
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func mod(_ a: Int, _ n: Int) -> Int {
        ((a % n) + n) % n
    }
}
