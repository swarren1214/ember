import Foundation

// One way to read the dates people say, for every tool: "today", "last week", "since the 1st",
// "in September", "the past 30 days", "October 5 to 12", "Saturday". Each tool gets back the
// exact range it used, so the answer can say it ("Sunday to today").

nonisolated struct EmberRange: Sendable, Hashable {
    /// Start of the first day.
    var start: Date
    /// End, exclusive (the start of the day after the last one).
    var end: Date

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// The same range, cut off at the end of today: for questions about what already happened.
    func throughToday(now: Date = .now, calendar: Calendar = .current) -> EmberRange {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return EmberRange(start: start, end: min(end, tomorrow))
    }

    /// The range before this one, the same length: "last week" for "this week".
    func previous(calendar: Calendar = .current) -> EmberRange {
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 7
        let start = calendar.date(byAdding: .day, value: -days, to: self.start) ?? self.start
        return EmberRange(start: start, end: self.start)
    }

    var days: Int { max(1, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1) }

    /// "Oct 19–22", "Oct 22", "September".
    func label(calendar: Calendar = .current) -> String {
        let last = calendar.date(byAdding: .second, value: -1, to: end) ?? end
        if calendar.isDate(start, inSameDayAs: last) {
            return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        let monthStart = calendar.dateInterval(of: .month, for: start)
        if let monthStart, monthStart.start == start, monthStart.end == end {
            return start.formatted(.dateTime.month(.wide).year())
        }
        if calendar.isDate(start, equalTo: last, toGranularity: .month) {
            return "\(start.formatted(.dateTime.month(.abbreviated).day()))–\(last.formatted(.dateTime.day()))"
        }
        return "\(start.formatted(.dateTime.month(.abbreviated).day()))–\(last.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

nonisolated enum EmberDates {
    /// Which way an unqualified day leans: "Saturday" is the next one for plans and the last one
    /// for spending.
    enum Lean: Sendable { case past, future }

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                                 "september", "october", "november", "december"]
    private static let shortMonths = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                      "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fourteen": 14,
                                      "thirty": 30, "sixty": 60, "ninety": 90, "a": 1, "an": 1]

    /// The range a phrase means. Empty or unknown means `fallback` (today by default).
    static func range(_ spoken: String, lean: Lean = .past, fallback: String = "today",
                      now: Date = .now, calendar: Calendar = .current) -> EmberRange {
        let text = normalize(spoken)
        if let range = parse(text, lean: lean, now: now, calendar: calendar) { return range }
        if text != normalize(fallback), let range = parse(normalize(fallback), lean: lean, now: now, calendar: calendar) { return range }
        return day(now, calendar: calendar)
    }

    /// One moment, for an event or a reminder: "tomorrow at 3", "Saturday 9am", "in 20 minutes".
    static func moment(_ spoken: String, lean: Lean = .future, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let text = normalize(spoken)
        if let offset = relativeOffset(text) { return now.addingTimeInterval(offset) }
        let (dayPart, time) = splitTime(text)
        let base: Date
        if dayPart.isEmpty {
            base = calendar.startOfDay(for: now)
        } else if let range = parse(dayPart, lean: lean, now: now, calendar: calendar) {
            base = range.start
        } else {
            return nil
        }
        guard let time else {
            return dayPart.isEmpty ? nil : base
        }
        var result = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: base) ?? base
        // "at 3" with no day, already past: the next 3 o'clock.
        if dayPart.isEmpty, result < now { result = calendar.date(byAdding: .day, value: 1, to: result) ?? result }
        return result
    }

    // MARK: Parsing

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func parse(_ text: String, lean: Lean, now: Date, calendar: Calendar) -> EmberRange? {
        let today = calendar.startOfDay(for: now)
        func days(_ from: Int, _ to: Int) -> EmberRange {
            EmberRange(start: calendar.date(byAdding: .day, value: from, to: today)!, end: calendar.date(byAdding: .day, value: to, to: today)!)
        }
        func interval(_ unit: Calendar.Component, offset: Int) -> EmberRange? {
            guard let base = calendar.date(byAdding: unit, value: offset, to: now),
                  let span = calendar.dateInterval(of: unit, for: base) else { return nil }
            return EmberRange(start: span.start, end: span.end)
        }
        var text = text
        for prefix in ["in the ", "during the ", "for the ", "over the ", "in ", "on ", "for ", "during ", "from ", "the "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        text = text.replacingOccurrences(of: " so far", with: "")

        switch text {
        case "", "today", "tonight", "this morning", "this afternoon", "this evening", "now": return days(0, 1)
        case "yesterday", "last night": return days(-1, 0)
        case "tomorrow", "tomorrow night", "tomorrow morning": return days(1, 2)
        case "day after tomorrow": return days(2, 3)
        case "this week", "week": return interval(.weekOfYear, offset: 0)
        case "last week", "past week", "previous week": return interval(.weekOfYear, offset: -1)
        case "next week", "coming week": return interval(.weekOfYear, offset: 1)
        case "this month", "month": return interval(.month, offset: 0)
        case "last month", "past month", "previous month": return interval(.month, offset: -1)
        case "next month": return interval(.month, offset: 1)
        case "this year", "year", "year to date", "ytd": return interval(.year, offset: 0)
        case "last year": return interval(.year, offset: -1)
        case "this weekend", "weekend": return weekend(offset: 0, now: now, calendar: calendar)
        case "next weekend": return weekend(offset: 1, now: now, calendar: calendar)
        case "last weekend": return weekend(offset: -1, now: now, calendar: calendar)
        case "upcoming", "coming up", "soon": return days(0, 14)
        default: break
        }

        // "last 30 days", "past 2 weeks", "next 3 months"
        let words = text.split(separator: " ").map(String.init)
        if words.count >= 2, ["last", "past", "previous", "next", "coming"].contains(words[0]) {
            let count = Int(words[1]) ?? numberWords[words[1]]
            let unitWord = words.count >= 3 ? words[2] : words[1]
            let n = count ?? 1
            let forward = words[0] == "next" || words[0] == "coming"
            let unit: Int? = switch unitWord.trimmingCharacters(in: CharacterSet(charactersIn: "s")) {
            case "day": 1
            case "week": 7
            case "month": 30
            case "year": 365
            default: nil
            }
            if let unit, count != nil || words.count == 2 {
                return forward ? days(1, 1 + n * unit) : days(1 - n * unit, 1)
            }
            // "last monday", "next friday"
            if let weekday = weekdays.firstIndex(of: words[1]) {
                return weekdayRange(weekday + 1, lean: forward ? .future : .past, strict: true, now: now, calendar: calendar)
            }
            // "last september"
            if let month = monthIndex(words[1]) {
                return monthRange(month, lean: forward ? .future : .past, strict: true, now: now, calendar: calendar)
            }
        }

        // "since the 1st", "since october 5", "since monday"
        if text.hasPrefix("since ") {
            let rest = String(text.dropFirst(6))
            if let start = parse(rest, lean: .past, now: now, calendar: calendar)?.start ?? dayOfMonth(rest, now: now, calendar: calendar) {
                return EmberRange(start: start, end: days(0, 1).end)
            }
        }

        // "october 5 to october 12", "oct 5 - 12", "monday to wednesday"
        for separator in [" to ", " through ", " until ", " - ", "-"] where text.contains(separator) {
            let parts = text.components(separatedBy: separator)
            if parts.count == 2, let from = parse(parts[0], lean: lean, now: now, calendar: calendar) {
                var second = parts[1]
                // "oct 5 - 12": the second half borrows the month.
                if Int(second.trimmingCharacters(in: .whitespaces)) != nil, let month = parts[0].split(separator: " ").first {
                    second = "\(month) \(second)"
                }
                if let to = parse(second, lean: lean, now: now, calendar: calendar), to.end > from.start {
                    return EmberRange(start: from.start, end: to.end)
                }
            }
        }

        // "saturday", "this saturday"
        let bare = text.replacingOccurrences(of: "this ", with: "")
        if let weekday = weekdays.firstIndex(of: bare) {
            return weekdayRange(weekday + 1, lean: lean, strict: false, now: now, calendar: calendar)
        }
        // "september", "september 2025", "october 10", "saturday october 10th 2026", "the 10th of october"
        let dated = calendarWords(bare)
        if let month = monthIndex(dated.split(separator: " ").first.map(String.init) ?? "") {
            let rest = dated.split(separator: " ").dropFirst().map(String.init)
            if rest.count == 2, let dayNumber = ordinal(rest[0]), (1...31).contains(dayNumber), let year = Int(rest[1]), year > 1900 {
                var parts = DateComponents(year: year, month: month, day: dayNumber)
                parts.calendar = calendar
                if let start = calendar.date(from: parts), let end = calendar.date(byAdding: .day, value: 1, to: start) {
                    return EmberRange(start: start, end: end)
                }
            }
            if rest.isEmpty {
                return monthRange(month, lean: lean, strict: false, now: now, calendar: calendar)
            }
            if rest.count == 1, let first = rest.first {
                let token = String(first)
                if let year = Int(token), year > 1900 {
                    var parts = DateComponents(year: year, month: month, day: 1)
                    parts.calendar = calendar
                    if let start = calendar.date(from: parts), let end = calendar.date(byAdding: .month, value: 1, to: start) {
                        return EmberRange(start: start, end: end)
                    }
                }
                if let dayNumber = ordinal(token) {
                    return specificDay(month: month, day: dayNumber, lean: lean, now: now, calendar: calendar)
                }
            }
        }
        // "the 5th", "saturday the 5th"
        if let start = dayOfMonth(text, now: now, calendar: calendar) ?? dayOfMonth(dated, now: now, calendar: calendar) {
            return EmberRange(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        // "2026-10-05", "10/5"
        if let date = numericDate(text, now: now, calendar: calendar) {
            let start = calendar.startOfDay(for: date)
            return EmberRange(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        return nil
    }

    /// A date as people say it, put in one order: "Saturday, October 10th" → "october 10th",
    /// "the 10th of October 2026" → "october 10th 2026", "Oct. 10" → "oct 10". A weekday said
    /// alongside a date only names it; the date decides.
    private static func calendarWords(_ text: String) -> String {
        var words = text.replacingOccurrences(of: ".", with: " ")
            .split(separator: " ").map(String.init)
            .filter { $0 != "of" && $0 != "on" }
        if words.count > 1 { words.removeAll { weekdays.contains($0) } }
        if let index = words.firstIndex(where: { monthIndex($0) != nil }) {
            words.removeAll { $0 == "the" }
            let at = words.firstIndex(where: { monthIndex($0) != nil }) ?? index
            if at > 0 {
                let month = words.remove(at: at)
                words.insert(month, at: 0)
            }
        }
        return words.joined(separator: " ")
    }

    /// The period said somewhere in a question: "how much did we spend last week?" → "last week",
    /// "what did we buy on Saturday, October 10th?" → "saturday october 10th". Longest phrase
    /// first; only phrases with a date word in them, so "$10" or "a coffee" never count.
    static func phrase(in question: String, now: Date = .now, calendar: Calendar = .current) -> String? {
        let words = normalize(question).replacingOccurrences(of: "?", with: " ").split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        let dateWords: Set<String> = Set(months + shortMonths + weekdays).union([
            "today", "tonight", "yesterday", "tomorrow", "week", "weekend", "month", "year", "days", "day", "weeks",
            "months", "ytd", "since"])
        func hasDateWord(_ window: ArraySlice<String>) -> Bool {
            window.contains { word in
                dateWords.contains(word) || monthIndex(word.replacingOccurrences(of: ".", with: "")) != nil
                    || word.contains("/") || (word.split(separator: "-").count == 3 && word.first?.isNumber == true)
            }
        }
        for length in stride(from: min(6, words.count), through: 1, by: -1) {
            for start in 0...(words.count - length) {
                let window = words[start..<(start + length)]
                guard hasDateWord(window) else { continue }
                let text = window.joined(separator: " ")
                if parse(text, lean: .past, now: now, calendar: calendar) != nil { return text }
            }
        }
        return nil
    }

    /// Whether a phrase reads as a date at all (so a tool can say when it fell back).
    static func reads(_ spoken: String, lean: Lean = .past, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let text = normalize(spoken)
        return text.isEmpty || parse(text, lean: lean, now: now, calendar: calendar) != nil
    }

    private static func weekend(offset: Int, now: Date, calendar: Calendar) -> EmberRange? {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today) // 1 Sunday … 7 Saturday
        // This weekend: the coming (or current) Saturday and Sunday.
        let toSaturday = weekday == 1 ? -1 : 7 - weekday
        guard let saturday = calendar.date(byAdding: .day, value: toSaturday + offset * 7, to: today),
              let end = calendar.date(byAdding: .day, value: 2, to: saturday) else { return nil }
        return EmberRange(start: saturday, end: end)
    }

    private static func weekdayRange(_ weekday: Int, lean: Lean, strict: Bool, now: Date, calendar: Calendar) -> EmberRange {
        let today = calendar.startOfDay(for: now)
        let current = calendar.component(.weekday, from: today)
        var offset: Int
        switch lean {
        case .future:
            offset = (weekday - current + 7) % 7
            if strict, offset == 0 { offset = 7 }
        case .past:
            offset = -((current - weekday + 7) % 7)
            if strict, offset == 0 { offset = -7 }
        }
        let start = calendar.date(byAdding: .day, value: offset, to: today)!
        return EmberRange(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    private static func monthRange(_ month: Int, lean: Lean, strict: Bool, now: Date, calendar: Calendar) -> EmberRange? {
        let currentMonth = calendar.component(.month, from: now)
        var year = calendar.component(.year, from: now)
        switch lean {
        case .past: if month > currentMonth || (strict && month == currentMonth) { year -= 1 }
        case .future: if month < currentMonth || (strict && month == currentMonth) { year += 1 }
        }
        var parts = DateComponents(year: year, month: month, day: 1)
        parts.calendar = calendar
        guard let start = calendar.date(from: parts), let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return EmberRange(start: start, end: end)
    }

    private static func specificDay(month: Int, day: Int, lean: Lean, now: Date, calendar: Calendar) -> EmberRange? {
        var year = calendar.component(.year, from: now)
        var parts = DateComponents(year: year, month: month, day: day)
        guard var start = calendar.date(from: parts) else { return nil }
        let today = calendar.startOfDay(for: now)
        // Without a year, the nearest one in the direction asked.
        if lean == .past, start > today { year -= 1 }
        if lean == .future, start < today { year += 1 }
        parts.year = year
        start = calendar.date(from: parts) ?? start
        return EmberRange(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    /// "the 1st", "5th" → that day of this month (or last month, if it hasn't come yet).
    private static func dayOfMonth(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let token = text.replacingOccurrences(of: "the ", with: "").replacingOccurrences(of: " of the month", with: "")
        guard let day = ordinal(token), (1...31).contains(day), token.rangeOfCharacter(from: .letters) != nil || token.count <= 2 else { return nil }
        var parts = calendar.dateComponents([.year, .month], from: now)
        parts.day = day
        guard var date = calendar.date(from: parts) else { return nil }
        if date > now { date = calendar.date(byAdding: .month, value: -1, to: date) ?? date }
        return calendar.startOfDay(for: date)
    }

    private static func numericDate(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let iso = text.split(separator: "-").compactMap { Int($0) }
        if iso.count == 3, iso[0] > 1900 {
            return calendar.date(from: DateComponents(year: iso[0], month: iso[1], day: iso[2]))
        }
        let slash = text.split(separator: "/").compactMap { Int($0) }
        if slash.count >= 2, (1...12).contains(slash[0]), (1...31).contains(slash[1]) {
            var year = slash.count == 3 ? slash[2] : calendar.component(.year, from: now)
            if year < 100 { year += 2000 }
            return calendar.date(from: DateComponents(year: year, month: slash[0], day: slash[1]))
        }
        return nil
    }

    private static func ordinal(_ token: String) -> Int? {
        let digits = token.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        if let value = Int(digits) { return value }
        let words = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
                     "ninth": 9, "tenth": 10, "fifteenth": 15, "twentieth": 20]
        return words[token.trimmingCharacters(in: .whitespaces)]
    }

    private static func monthIndex(_ word: String) -> Int? {
        if let index = months.firstIndex(of: word) { return index + 1 }
        let short = String(word.prefix(3))
        if word.count >= 3, word.count <= 4, let index = shortMonths.firstIndex(of: short) { return index + 1 }
        return nil
    }

    // MARK: Times

    /// "in 20 minutes", "in an hour".
    private static func relativeOffset(_ text: String) -> TimeInterval? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 3, words[0] == "in" else { return nil }
        let count = Double(words[1]) ?? Double(numberWords[words[1]] ?? 0)
        guard count > 0 else { return nil }
        switch words[2].trimmingCharacters(in: CharacterSet(charactersIn: "s")) {
        case "second": return count
        case "minute", "min": return count * 60
        case "hour", "hr": return count * 3600
        case "day": return count * 86_400
        default: return nil
        }
    }

    /// Splits "saturday at 9:30am" into ("saturday", 9:30).
    private static func splitTime(_ text: String) -> (String, (hour: Int, minute: Int)?) {
        let named: [String: (Int, Int)] = ["noon": (12, 0), "midnight": (0, 0), "morning": (9, 0), "afternoon": (14, 0),
                                          "evening": (18, 0), "tonight": (19, 0)]
        var words = text.split(separator: " ").map(String.init)
        var time: (hour: Int, minute: Int)?
        var index = words.count - 1
        while index >= 0 {
            let word = words[index]
            if let named = named[word] {
                time = (named.0, named.1)
                words.remove(at: index)
                break
            }
            if let parsed = clock(word, next: index + 1 < words.count ? words[index + 1] : nil) {
                time = parsed.time
                words.removeSubrange(index..<(index + parsed.consumed))
                break
            }
            index -= 1
        }
        words.removeAll { $0 == "at" || $0 == "by" }
        // "tonight" keeps meaning today.
        if text.contains("tonight") { words.removeAll { $0 == "tonight" }; if words.isEmpty { words = ["today"] } }
        return (words.joined(separator: " "), time)
    }

    private static func clock(_ word: String, next: String?) -> (time: (hour: Int, minute: Int), consumed: Int)? {
        var token = word
        var consumed = 1
        var meridiem: String?
        for suffix in ["am", "pm", "a.m.", "p.m."] where token.hasSuffix(suffix) {
            meridiem = String(suffix.prefix(1))
            token = String(token.dropLast(suffix.count))
        }
        if meridiem == nil, let next, ["am", "pm", "a.m.", "p.m."].contains(next) {
            meridiem = String(next.prefix(1))
            consumed = 2
        }
        let pieces = token.split(separator: ":").compactMap { Int($0) }
        guard let hourValue = pieces.first, pieces.count <= 2, token.allSatisfy({ $0.isNumber || $0 == ":" }), !token.isEmpty else { return nil }
        var hour = hourValue
        let minute = pieces.count == 2 ? pieces[1] : 0
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if meridiem == nil && pieces.count == 1 && hour > 12 { return nil }
        if meridiem == "p", hour < 12 { hour += 12 }
        if meridiem == "a", hour == 12 { hour = 0 }
        // "at 3" with no am/pm: afternoon for 1 to 7.
        if meridiem == nil, (1...7).contains(hour) { hour += 12 }
        return ((hour, minute), consumed)
    }

    private static func day(_ now: Date, calendar: Calendar) -> EmberRange {
        let start = calendar.startOfDay(for: now)
        return EmberRange(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }
}
