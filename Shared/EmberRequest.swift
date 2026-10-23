import Foundation

// What someone asked for, as a typed request (Ember Assistant Architecture › Understanding).
//
// A model fills this in, and nothing else: which intent, and words copied from the question for
// the period, the person, the place, the budget, the amount. Code then turns the words into real
// values (EmberDates, the ledger, Contacts). Copied words are checked against the question here,
// so a town nobody said ("near Santaquin" on "call Kristen") can't survive.

nonisolated enum EmberIntent: String, CaseIterable, Codable, Sendable {
    case spending, transactions, budgetStatus, bills, logPurchase
    case call, text, findPlaces, directions
    case calendar, addEvent, chores
    case groceries, addGroceries, mealPlan
    case foodLog, reading, remember, openApp, general, unsupported

    /// Said to the model that picks one.
    var meaning: String {
        switch self {
        case .spending: "how much was spent: in a period, on a budget, at a store, or by a person (\"how much did we spend last week\", \"what did we spend on October 10\")"
        case .transactions: "which purchases or charges there were, listed (\"what did we buy yesterday\", \"show the Costco charges\")"
        case .budgetStatus: "how a budget stands this month: left, over, on track (\"how's the grocery budget\")"
        case .bills: "bills due or paid (\"what bills are due this week\")"
        case .logPurchase: "record a purchase in the budget (\"log $40 at Costco\")"
        case .call: "phone a person or a business (\"call Mom\", \"call Kristen\")"
        case .text: "send a text or email to someone"
        case .findPlaces: "find restaurants, stores or businesses nearby"
        case .directions: "directions to a place"
        case .calendar: "what's on the family calendar"
        case .addEvent: "add an event to a calendar"
        case .chores: "chores, approvals, allowance"
        case .groceries: "what's on the grocery list"
        case .addGroceries: "add items to the grocery list"
        case .mealPlan: "meals planned, what's for dinner"
        case .foodLog: "calories, protein, logging food"
        case .reading: "scripture reading and study"
        case .remember: "remember or forget a fact"
        case .openApp: "open one of the apps"
        case .general: "general knowledge or small talk"
        case .unsupported: "anything else Ember can't do"
        }
    }

    /// Spending and purchases: the same question asked two ways, so a follow-up can switch
    /// between them and keep its filters.
    var isMoneyQuery: Bool { self == .spending || self == .transactions }
}

nonisolated struct EmberRequest: Codable, Sendable, Equatable {
    var intent: EmberIntent
    /// Words for when, copied from the question: "on October 10", "last week".
    var whenWords = ""
    /// Who, copied: "Kristen", "Mom". Empty for "we", "us", "me".
    var who = ""
    /// A store, payee or kind of place, copied: "Costco", "Mexican food".
    var placeWords = ""
    /// A town, only if one was said: "Orem".
    var townWords = ""
    /// A budget, copied: "groceries", "eating out".
    var budgetWords = ""
    /// Things to add (groceries) or the words of a message.
    var items: [String] = []
    /// An amount, copied: "$40".
    var amountWords = ""
    /// Leans on the last question ("what about last week?").
    var isFollowUp = false
    /// A short question to ask when it truly can't tell.
    var clarify = ""

    /// Words that mean the household itself, never a person to look up.
    static let selfWords: Set<String> = ["we", "us", "our", "i", "me", "my", "myself", "ourselves", "you", "the family", "everyone", "everybody"]

    /// The request with every copied field that isn't in the question emptied.
    func checked(against question: String) -> EmberRequest {
        var copy = self
        func keep(_ words: String) -> String {
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.appears(trimmed, in: question) ? trimmed : ""
        }
        copy.whenWords = keep(whenWords)
        copy.who = keep(who)
        if Self.selfWords.contains(copy.who.lowercased()) { copy.who = "" }
        copy.placeWords = keep(placeWords)
        copy.townWords = keep(townWords)
        copy.budgetWords = keep(budgetWords)
        copy.amountWords = keep(amountWords)
        return copy
    }

    /// A follow-up keeps what the last request said unless this one says otherwise: "what about
    /// last week?" after "how much did we spend at Costco this month?" is spending at Costco,
    /// last week.
    func merged(onto previous: EmberRequest) -> EmberRequest {
        var copy = self
        let sameKind = intent == previous.intent || intent == .general || intent == .unsupported
            || (intent.isMoneyQuery && previous.intent.isMoneyQuery)
        guard sameKind else { return copy }
        if intent == .general || intent == .unsupported { copy.intent = previous.intent }
        if copy.whenWords.isEmpty { copy.whenWords = previous.whenWords }
        if copy.who.isEmpty { copy.who = previous.who }
        if copy.placeWords.isEmpty { copy.placeWords = previous.placeWords }
        if copy.townWords.isEmpty { copy.townWords = previous.townWords }
        if copy.budgetWords.isEmpty { copy.budgetWords = previous.budgetWords }
        return copy
    }

    /// The request with tokens ("[P2]") swapped back for the names they stand for.
    func restored(with redactor: EmberRedactor) -> EmberRequest {
        var copy = self
        copy.whenWords = redactor.restore(whenWords)
        copy.who = redactor.restore(who)
        copy.placeWords = redactor.restore(placeWords)
        copy.townWords = redactor.restore(townWords)
        copy.budgetWords = redactor.restore(budgetWords)
        copy.items = items.map(redactor.restore)
        copy.amountWords = redactor.restore(amountWords)
        copy.clarify = redactor.restore(clarify)
        return copy
    }

    /// Whether `words` were said in `question`, ignoring case, punctuation and accents.
    static func appears(_ words: String, in question: String) -> Bool {
        let wanted = fold(words)
        guard !wanted.isEmpty else { return true }
        let said = " " + fold(question) + " "
        if said.contains(" " + wanted + " ") { return true }
        // "the Costco" said as "Costco", "my mom" said as "mom".
        let trimmed = wanted.split(separator: " ").drop { ["the", "a", "an", "my", "our", "on", "in", "at", "for"].contains(String($0)) }.joined(separator: " ")
        return !trimmed.isEmpty && said.contains(" " + trimmed)
    }

    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "’", with: "'")
        let kept = String(folded.map { (c: Character) -> Character in
            c.isLetter || c.isNumber || c == "'" || c == "$" || c == "." ? c : " "
        })
        return kept.split(separator: " ")
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
