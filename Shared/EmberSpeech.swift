import Foundation

// Text made ready to be heard: money, times, dates, numbers and abbreviations written the way a
// person says them, before either voice reads it (Kokoro on iPhone, the system voice on Watch).
// "$1,240.50 at 6:30 PM on Oct 22" → "twelve hundred forty dollars at six thirty PM on
// October twenty-second". Phone numbers and links are never read out.

nonisolated enum EmberSpeech {
    static func prepare(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
        s = s.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "–", with: " to ")
        s = s.replacingOccurrences(of: "—", with: ", ")
        s = replace(s, #"https?://\S+"#) { _ in "the link" }
        s = replace(s, #"\b[\w.+-]+@[\w-]+\.[\w.]+\b"#) { _ in "the email address" }
        s = replace(s, #"(?:\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b"#) { _ in "the number" }
        s = money(s)
        s = replace(s, #"(\d+(?:\.\d+)?)\s?%"#) { m in "\(number(m[1])) percent" }
        s = times(s)
        s = dates(s)
        s = replace(s, #"\b(\d+)(st|nd|rd|th)\b"#) { m in ordinal(Int(m[1]) ?? 0) }
        s = units(s)
        s = abbreviations(s)
        s = fractions(s)
        s = replace(s, #"\b(1[89]\d\d|20\d\d)\b"#) { m in year(Int(m[1]) ?? 0) }
        s = replace(s, #"(?<![\w.])-?\d[\d,]*(?:\.\d+)?(?![\w.])"#) { m in number(m[0]) }
        s = replace(s, #"\s+"#) { _ in " " }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Money

    private static func money(_ text: String) -> String {
        replace(text, #"(-)?\$(\d[\d,]*)(?:\.(\d{2}))?(\s?[kKmM]\b)?"#) { m in
            let negative = !m[1].isEmpty
            let whole = Int(m[2].replacingOccurrences(of: ",", with: "")) ?? 0
            let cents = Int(m[3]) ?? 0
            var spoken: String
            if !m[4].isEmpty {
                let scale = m[4].trimmingCharacters(in: .whitespaces).lowercased() == "k" ? "thousand" : "million"
                spoken = "\(cardinal(whole)) \(scale) dollars"
            } else if whole == 0 && cents > 0 {
                spoken = "\(cardinal(cents)) cents"
            } else if cents == 0 || whole >= 100 {
                // Cents matter for small amounts, not big ones.
                let rounded = cents >= 50 && whole >= 100 ? whole + 1 : whole
                spoken = "\(dollars(rounded)) \(rounded == 1 ? "dollar" : "dollars")"
            } else {
                spoken = "\(dollars(whole)) \(whole == 1 ? "dollar" : "dollars") and \(cardinal(cents)) \(cents == 1 ? "cent" : "cents")"
            }
            return negative ? "minus \(spoken)" : spoken
        }
    }

    /// 1240 → "twelve hundred forty", the way prices are said.
    private static func dollars(_ value: Int) -> String {
        if value >= 1100, value < 10_000, value % 1000 != 0, value % 100 == 0 || (value / 100) % 10 != 0 {
            let hundreds = value / 100
            let rest = value % 100
            return "\(cardinal(hundreds)) hundred" + (rest > 0 ? " \(cardinal(rest))" : "")
        }
        return cardinal(value)
    }

    // MARK: Times and dates

    private static func times(_ text: String) -> String {
        replace(text, #"\b(\d{1,2}):(\d{2})\s?([AaPp])\.?\s?[Mm]\.?|\b(\d{1,2}):(\d{2})\b|\b(\d{1,2})\s?([AaPp])\.?[Mm]\.?\b"#) { m in
            var hour = 0, minute = 0, meridiem = ""
            if !m[1].isEmpty {
                hour = Int(m[1]) ?? 0; minute = Int(m[2]) ?? 0; meridiem = m[3].uppercased() + "M"
            } else if !m[4].isEmpty {
                hour = Int(m[4]) ?? 0; minute = Int(m[5]) ?? 0
            } else {
                hour = Int(m[6]) ?? 0; meridiem = m[7].uppercased() + "M"
            }
            var spoken: String
            if hour == 12 && minute == 0 && meridiem == "PM" { return "noon" }
            if hour == 0 && minute == 0 && meridiem.isEmpty { return "midnight" }
            spoken = cardinal(hour == 0 ? 12 : hour)
            if minute == 0 {
                spoken += meridiem.isEmpty ? " o'clock" : ""
            } else if minute < 10 {
                spoken += " oh \(cardinal(minute))"
            } else {
                spoken += " \(cardinal(minute))"
            }
            return meridiem.isEmpty ? spoken : "\(spoken) \(meridiem == "AM" ? "A M" : "P M")"
        }
    }

    private static let monthNames = ["jan": "January", "feb": "February", "mar": "March", "apr": "April", "may": "May",
                                     "jun": "June", "jul": "July", "aug": "August", "sep": "September", "sept": "September",
                                     "oct": "October", "nov": "November", "dec": "December"]

    private static func dates(_ text: String) -> String {
        // "Oct 22", "October 22", "Oct. 22nd" → "October twenty-second"
        var s = replace(text, #"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sept?|Oct|Nov|Dec)[a-z]*\.?\s(\d{1,2})(?:st|nd|rd|th)?\b"#) { m in
            let month = monthNames[m[1].lowercased()] ?? m[1]
            return "\(month) \(ordinal(Int(m[2]) ?? 0))"
        }
        // Weekday abbreviations next to a date: "Sat, October …"
        let days = ["Mon": "Monday", "Tue": "Tuesday", "Tues": "Tuesday", "Wed": "Wednesday", "Thu": "Thursday",
                    "Thur": "Thursday", "Thurs": "Thursday", "Fri": "Friday", "Sat": "Saturday", "Sun": "Sunday"]
        s = replace(s, #"\b(Mon|Tues?|Wed|Thu(?:rs?)?|Fri|Sat|Sun)\.?(?=,?\s)"#) { m in days[m[1]] ?? m[0] }
        return s
    }

    // MARK: Units and abbreviations

    private static func units(_ text: String) -> String {
        let units: [(String, String, String)] = [
            ("kcal", "calorie", "calories"), ("cal", "calorie", "calories"), ("g", "gram", "grams"), ("kg", "kilogram", "kilograms"),
            ("oz", "ounce", "ounces"), ("lbs?", "pound", "pounds"), ("mi", "mile", "miles"), ("km", "kilometer", "kilometers"),
            ("mins?", "minute", "minutes"), ("hrs?", "hour", "hours"), ("ml", "milliliter", "milliliters"),
            ("°F", "degree", "degrees"), ("°", "degree", "degrees"),
        ]
        var s = text
        for (pattern, one, many) in units {
            s = replace(s, #"(\d+(?:\.\d+)?)\s?"# + pattern + #"\b"#) { m in "\(m[1]) \(m[1] == "1" ? one : many)" }
        }
        s = s.replacingOccurrences(of: "°", with: " degrees")
        return s
    }

    private static func abbreviations(_ text: String) -> String {
        var s = text
        let streets = ["St": "Street", "Ave": "Avenue", "Rd": "Road", "Blvd": "Boulevard", "Ln": "Lane", "Ct": "Court",
                       "Hwy": "Highway", "Pkwy": "Parkway", "Cir": "Circle", "Pl": "Place"]
        // "N Main St" → "North Main Street"; a direction letter before a capitalized word.
        let directions = ["N": "North", "S": "South", "E": "East", "W": "West"]
        s = replace(s, #"\b([NSEW])\.?\s(?=[A-Z0-9])"#) { m in "\(directions[m[1]] ?? m[1]) " }
        s = replace(s, #"(?<=[A-Za-z0-9] )(St|Ave|Rd|Blvd|Ln|Ct|Hwy|Pkwy|Cir|Pl)\.?\b"#) { m in streets[m[1]] ?? m[0] }
        s = replace(s, #"\bDr\.?\s(?=[A-Z])"#) { _ in "Doctor " }
        s = replace(s, #"(?<=[A-Za-z] )Dr\.?\b"#) { _ in "Drive" }
        let plain: [(String, String)] = [
            (#"\s&\s"#, " and "), (#"\bw/\s?"#, "with "), (#"\bapprox\.?\s"#, "about "), (#"\bvs\.?\s"#, "versus "),
            (#"\betc\.?"#, "and so on"), (#"\be\.g\.,?\s?"#, "for example, "), (#"\bi\.e\.,?\s?"#, "that is, "),
            (#"\bMr\.\s"#, "Mister "), (#"\bMrs\.\s"#, "Missus "), (#"\bMs\.\s"#, "Miz "),
        ]
        for (pattern, replacement) in plain { s = replace(s, pattern) { _ in replacement } }
        return s
    }

    private static func fractions(_ text: String) -> String {
        let named = ["1/2": "one half", "1/3": "one third", "2/3": "two thirds", "1/4": "one quarter", "3/4": "three quarters"]
        return replace(text, #"\b(\d+)\s(1/2|1/3|2/3|1/4|3/4)\b|\b(1/2|1/3|2/3|1/4|3/4)\b"#) { m in
            if !m[1].isEmpty { return "\(cardinal(Int(m[1]) ?? 0)) and \(named[m[2]] ?? m[2])" }
            return named[m[3]] ?? m[3]
        }
    }

    // MARK: Numbers in words

    private static let spell: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    static func cardinal(_ value: Int) -> String {
        spell.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "1,240" → "one thousand two hundred forty", "2.5" → "two point five".
    static func number(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: ",", with: "")
        if let value = Int(clean) { return cardinal(value) }
        guard let value = Double(clean) else { return text }
        let parts = clean.split(separator: ".")
        let whole = cardinal(Int(value.rounded(.towardZero)))
        guard parts.count == 2 else { return whole }
        let digits = parts[1].compactMap { Int(String($0)) }.map(cardinal).joined(separator: " ")
        return "\(clean.hasPrefix("-") && Int(value) == 0 ? "minus " : "")\(whole) point \(digits)"
    }

    /// 22 → "twenty-second".
    static func ordinal(_ value: Int) -> String {
        let words = cardinal(value)
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        let separators = CharacterSet(charactersIn: " -")
        guard let range = words.rangeOfCharacter(from: separators, options: .backwards) else {
            return irregular[words] ?? suffixed(words)
        }
        let head = words[..<range.upperBound]
        let last = String(words[range.upperBound...])
        return head + (irregular[last] ?? suffixed(last))
    }

    private static func suffixed(_ word: String) -> String {
        word.hasSuffix("y") ? String(word.dropLast()) + "ieth" : word + "th"
    }

    /// 2026 → "twenty twenty-six", 2000 → "two thousand", 1999 → "nineteen ninety-nine".
    static func year(_ value: Int) -> String {
        if value >= 2000 && value < 2010 { return cardinal(value) }
        let high = value / 100, low = value % 100
        if low == 0 { return "\(cardinal(high)) hundred" }
        return "\(cardinal(high)) \(low < 10 ? "oh " : "")\(cardinal(low))"
    }

    // MARK: Regex helper

    /// Replaces every match; the closure gets the match and its groups ("" when a group didn't match).
    static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
