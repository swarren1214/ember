import Foundation
import NaturalLanguage

// Privacy rule 2 (implementation plan › Privacy): everything that leaves the device for a cloud
// model goes through here first, on iPhone and on Apple Watch.
//
// - Household members become a token per conversation ([P1], [P2]) and the cloud gets only their
//   role and age band. Other people the text names become [N1], [N2].
// - Emails, phone numbers, street addresses, links and card or account numbers are removed.
// - The token map never leaves the device. Replies come back with tokens and `restore` puts the
//   real names back before Ember shows or speaks them.
//
// hearth-api checks again (its privacy guard) and refuses anything that still looks like an
// email, phone number, address or card number, so a miss here fails closed.

/// Someone in the Hearth household, as the redactor needs them.
nonisolated struct EmberPerson: Sendable, Hashable {
    var name: String
    /// "parent", "adult" or "kid".
    var role: String
    var age: Int?
}

/// A household member as the cloud sees them: a token, a role and an age band. No name.
nonisolated struct EmberRosterEntry: Codable, Sendable, Hashable {
    var token: String
    var role: String
    /// "under 5", "5–12", "13–17", "adult".
    var ageBand: String?
}

nonisolated struct EmberRedactor: Sendable {
    /// Lowercased name → token.
    private var tokenFor: [String: String] = [:]
    /// Token → the name to show.
    private var nameFor: [String: String] = [:]
    /// Household names, longest first, so "Mia Warren" is matched before "Mia".
    private var householdNames: [String] = []
    private var nextOther = 1
    private(set) var roster: [EmberRosterEntry] = []

    init(household: [EmberPerson]) {
        for (index, person) in household.enumerated() {
            let token = "[P\(index + 1)]"
            let full = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !full.isEmpty else { continue }
            let first = full.split(separator: " ").first.map(String.init) ?? full
            nameFor[token] = first
            for name in Set([full, first]) where name.count > 1 {
                let key = name.lowercased()
                // Two people with the same first name: the first name alone stays ambiguous, so
                // it's removed rather than pointed at the wrong person.
                if let existing = tokenFor[key], existing != token {
                    tokenFor[key] = "[person]"
                } else {
                    tokenFor[key] = token
                }
                householdNames.append(name)
            }
            roster.append(EmberRosterEntry(token: token, role: person.role, ageBand: Self.ageBand(person.age)))
        }
        householdNames = Array(Set(householdNames)).sorted { $0.count > $1.count }
    }

    // MARK: Redacting

    /// `text` with names tokenized and identifiers removed. Tokens for other people's names are
    /// remembered so a follow-up uses the same token.
    mutating func redact(_ text: String) -> String {
        var result = text
        // 1. Identifiers first, while the text is still as written.
        result = Self.replaceMatches(of: Self.emailPattern, in: result, with: "[email]")
        result = Self.replaceDetected(in: result)
        result = Self.replaceMatches(of: Self.ssnPattern, in: result, with: "[number]")
        result = Self.replaceMatches(of: Self.longNumberPattern, in: result, with: "[number]")
        // 2. The household, by name.
        for name in householdNames {
            guard let token = tokenFor[name.lowercased()] else { continue }
            result = Self.replaceWord(name, in: result, with: token)
        }
        // 3. Anyone else the text names.
        result = redactOtherNames(in: result)
        return result
    }

    /// Puts the real names back into a reply. Unknown tokens become a neutral word.
    func restore(_ text: String) -> String {
        var result = text
        for (token, name) in nameFor {
            result = result.replacingOccurrences(of: token, with: name)
        }
        result = result.replacingOccurrences(of: "[person]", with: "someone")
        return result
    }

    private mutating func redactOtherNames(in text: String) -> String {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: [(Range<String.Index>, String)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName {
                let name = String(text[range])
                // Leave tokens alone ("P1" inside "[P1]").
                let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : " "
                if before != "[" { found.append((range, name)) }
            }
            return true
        }
        guard !found.isEmpty else { return text }
        var result = text
        for (range, name) in found.reversed() {
            let key = name.lowercased()
            let token: String
            if let existing = tokenFor[key] {
                token = existing
            } else {
                token = "[N\(nextOther)]"
                nextOther += 1
                tokenFor[key] = token
                nameFor[token] = name
            }
            result.replaceSubrange(range, with: token)
        }
        return result
    }

    // MARK: Checking

    /// What in `text` still looks like an identifier (empty when nothing does). The same checks
    /// hearth-api's privacy guard runs.
    static func leaks(in text: String) -> [String] {
        var kinds: [String] = []
        if firstMatch(of: emailPattern, in: text) { kinds.append("email") }
        if firstMatch(of: ssnPattern, in: text) || firstMatch(of: longNumberPattern, in: text) { kinds.append("number") }
        let detected = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if detected.contains(where: { $0.resultType == .phoneNumber }) { kinds.append("phone") }
        if detected.contains(where: { $0.resultType == .address }) { kinds.append("address") }
        if detected.contains(where: { $0.resultType == .link }) { kinds.append("link") }
        return kinds
    }

    // MARK: Helpers

    static func ageBand(_ age: Int?) -> String? {
        guard let age else { return nil }
        switch age {
        case ..<5: return "under 5"
        case 5...12: return "5–12"
        case 13...17: return "13–17"
        default: return "adult"
        }
    }

    private static let emailPattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
    private static let ssnPattern = #"\b\d{3}-\d{2}-\d{4}\b"#
    /// Card and account numbers: 9 to 19 digits, with optional spaces or dashes.
    private static let longNumberPattern = #"\b\d(?:[ \-]?\d){8,18}\b"#

    private static let detector: NSDataDetector = {
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .address, .link]
        // The types are fixed and valid, so this can't fail.
        return try! NSDataDetector(types: types.rawValue)
    }()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func firstMatch(of pattern: String, in text: String) -> Bool {
        regex(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replaceMatches(of pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = regex(pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }

    private static func replaceDetected(in text: String) -> String {
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let replacement: String
            switch match.resultType {
            case .phoneNumber: replacement = "[phone]"
            case .address: replacement = "[address]"
            case .link: replacement = "[link]"
            default: continue
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func replaceWord(_ word: String, in text: String, with replacement: String) -> String {
        let pattern = "(?<![\\p{L}\\[])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\]])"
        guard let regex = regex(pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}
