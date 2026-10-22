import Foundation
import FoundationModels

// Which areas a question is about, so each turn offers only the tools it needs (implementation
// plan › Dependability 1), and whether it's simple or needs the bigger model (2).
//
// Words first: most questions name their area ("spend", "chores", "calories"). When the words
// don't settle it, Apple's on-device model classifies the question in one short call. With no
// on-device model, every area is offered (Claude handles a long tool list well).

@Generable
struct EmberIntentGuess {
    @Guide(description: "The area the request is about", .anyOf(EmberRouter.domainNames))
    var domain: String
    @Guide(description: "A second area it also needs, or none", .anyOf(EmberRouter.domainNames + ["none"]))
    var alsoDomain: String
    @Guide(description: "True when it combines several apps, plans ahead over days, compares, or needs several steps")
    var isComplex: Bool
}

enum EmberRouter {
    nonisolated static let domainNames = EmberDomain.allCases.map(\.rawValue)

    struct Decision {
        var domains: Set<EmberDomain>
        var isComplex: Bool
    }

    private static let words: [EmberDomain: [String]] = [
        .money: ["spend", "spent", "spending", "budget", "money", "afford", "bill", "bills", "paid", "pay ", "purchase", "bought",
                 "cost", "costs", "dollars", "$", "suffice", "income", "expense", "charge", "subscription", "rent", "mortgage", "transaction", "log "],
        .meals: ["dinner", "lunch", "breakfast", "meal", "meals", "recipe", "cook", "grocery", "groceries", "shopping list",
                 "bigtable", "allerg", "eat tonight", "ingredients", "pantry", "add milk", "on the list", "the list"],
        .family: ["chore", "chores", "approve", "calendar", "practice", "game", "recital", "appointment", "event", "schedule",
                  "allowance", "points", "caloma", "family", "driving", "pick up", "pickup", "birthday", "school"],
        .food: ["calorie", "calories", "protein", "carbs", "macros", "ate ", "eaten", "sated", "food log", "log food", "snack", "logged", "log a ", "i ate"],
        .study: ["scripture", "reading", "hearken", "study", "chapter", "verse", "book of mormon", "plan progress"],
        .phone: ["call ", "text ", "message ", "email", "e-mail", "remind", "reminder", "timer", "alarm", "wake me",
                 "my calendar", "my schedule", "meeting", "directions", "navigate", "how do i get to", "phone", "dial"],
    ]

    static func decide(_ question: String, onDevice: Bool) async -> Decision {
        let text = " " + question.lowercased() + " "
        var scores: [EmberDomain: Int] = [:]
        for (domain, list) in words {
            let hits = list.filter { text.contains($0) }.count
            if hits > 0 { scores[domain] = hits }
        }
        let complex = EmberBrain.isPlanning(question) || scores.count >= 2
        if !scores.isEmpty {
            // Every area the words name (a question can span two: "can we afford dinner out?").
            return Decision(domains: Set(scores.keys), isComplex: complex)
        }
        guard onDevice else { return Decision(domains: Set(EmberDomain.allCases), isComplex: complex) }
        do {
            let session = LanguageModelSession(instructions: """
            Classify a request to a family's assistant into the area it's about. The areas:
            \(EmberDomain.allCases.map { "- \($0.rawValue): \($0.meaning)" }.joined(separator: "\n"))
            """)
            let guess = try await session.respond(to: question, generating: EmberIntentGuess.self,
                                                  options: GenerationOptions(temperature: 0)).content
            var domains: Set<EmberDomain> = [EmberDomain(rawValue: guess.domain) ?? .general]
            if let also = EmberDomain(rawValue: guess.alsoDomain) { domains.insert(also) }
            return Decision(domains: domains, isComplex: guess.isComplex || complex)
        } catch {
            return Decision(domains: Set(EmberDomain.allCases), isComplex: complex)
        }
    }
}
