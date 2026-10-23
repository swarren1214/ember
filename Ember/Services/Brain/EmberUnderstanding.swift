import Foundation
import FoundationModels
import OSLog

// The first stage of every question (Ember Assistant Architecture › Understanding): Apple's
// on-device model turns the question into an EmberRequest and does nothing else. Guided
// generation holds it to that exact shape, so it can't invent a tool, skip the intent, or wander
// off into an answer. Its copied words are checked against the question before anything uses them.

@Generable
struct EmberRequestDraft {
    @Guide(description: "What they want, one of the listed intents", .anyOf(EmberIntent.allCases.map(\.rawValue)))
    var intent: String
    @Guide(description: "The exact words they used for when, copied from the question (\"on October 10\", \"last week\", \"yesterday\"), or empty")
    var whenWords: String
    @Guide(description: "The person, copied exactly as they said it (\"Kristen\", \"Mom\", \"my wife\"), or empty. Empty for we, us, me or I.")
    var who: String
    @Guide(description: "A store, payee or kind of place, copied exactly (\"Costco\", \"Mexican food\"), or empty")
    var placeWords: String
    @Guide(description: "A town or city, ONLY if they said one, copied exactly, or empty. Never fill in where they are.")
    var townWords: String
    @Guide(description: "A budget name, copied exactly (\"groceries\", \"eating out\"), or empty")
    var budgetWords: String
    @Guide(description: "Grocery items to add, or the words of a message to send; empty otherwise")
    var items: [String]
    @Guide(description: "An amount of money, copied exactly (\"$40\", \"forty dollars\"), or empty")
    var amountWords: String
    @Guide(description: "True only when the question leans on the previous one, like \"what about last week?\" or \"and at Costco?\"")
    var isFollowUp: Bool
    @Guide(description: "One short question to ask back only when it's impossible to tell what they want; otherwise empty")
    var clarify: String

    var request: EmberRequest {
        EmberRequest(intent: EmberIntent(rawValue: intent) ?? .general, whenWords: whenWords, who: who, placeWords: placeWords,
                     townWords: townWords, budgetWords: budgetWords, items: items, amountWords: amountWords,
                     isFollowUp: isFollowUp, clarify: clarify)
    }
}

enum EmberUnderstanding {
    private static let log = Logger(subsystem: "com.stephenwarren.ember", category: "understanding")

    /// The request in `question`: from Claude through hearth-api when Cloud Help allows it (the
    /// question de-identified first; it reads speech far better than the small model), else from
    /// Apple's on-device model. Nil when neither can (the tools path then handles the question).
    static func understand(_ question: String, previous: (question: String, request: EmberRequest)?) async -> EmberRequest? {
        var request: EmberRequest?
        if EmberSettings.shared.cloudHelp?.allowsClaude == true {
            request = await inCloud(question, previous: previous)
            if request != nil { EmberTrace.shared.note("understood in the cloud") }
        }
        if request == nil {
            request = await onDevice(question, previous: previous)
        }
        guard var request else { return nil }
        request = request.checked(against: question)
        if request.isFollowUp, let previous { request = request.merged(onto: previous.request) }
        return request
    }

    /// Claude fills in the request from the de-identified question; names come back as tokens
    /// and are swapped back here. About a second; 2.5 at most, then the device takes over.
    private static func inCloud(_ question: String, previous: (question: String, request: EmberRequest)?) async -> EmberRequest? {
        guard let token = try? await EmberAPI.shared.accessToken() else { return nil }
        var redactor = EmberRedactor(household: EmberContext.shared.redactionPeople)
        let redacted = redactor.redact(question)
        let earlier = previous.map { (question: redactor.redact($0.question), intent: $0.request.intent) }
        let client = EmberCloudClient(baseURL: AppConfig.apiBaseURL)
        do {
            let raw = try await client.understand(redacted, previous: earlier, accessToken: token)
            return raw.restored(with: redactor)
        } catch {
            log.notice("Cloud understanding failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func onDevice(_ question: String, previous: (question: String, request: EmberRequest)?) async -> EmberRequest? {
        guard EmberBrain.onDeviceAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions(previous: previous))
        do {
            return try await session.respond(to: question, generating: EmberRequestDraft.self,
                                             options: GenerationOptions(temperature: 0)).content.request
        } catch {
            log.notice("Understanding failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func instructions(previous: (question: String, request: EmberRequest)?) -> String {
        var text = """
        You read one request to a family's assistant and fill in what it asks for. You never answer it.
        Today is \(Date.now.formatted(date: .complete, time: .omitted)).

        Intents:
        \(EmberIntent.allCases.map { "- \($0.rawValue): \($0.meaning)" }.joined(separator: "\n"))

        Rules:
        - Copy words exactly as they appear in the request. Never rephrase, never add words they didn't say.
        - Leave a field empty when the request doesn't say it.
        - A person's name or a relation like Mom is "who", never a place.
        - Money questions about a specific day or period are "spending", or "transactions" when they want the list.
        - How a budget is doing is "budgetStatus" with the budget in budgetWords. For a bill asked about by name ("is rent paid?"), put the bill's name in placeWords.
        """
        if let previous {
            text += "\n\nThe previous request was: \"\(previous.question)\" (intent \(previous.request.intent.rawValue)). Use it only to decide isFollowUp."
        }
        return text
    }
}

extension EmberIntent {
    /// The tool areas for an intent that still goes through the tools path.
    var domains: Set<EmberDomain> {
        switch self {
        case .spending, .transactions, .budgetStatus, .bills, .logPurchase: [.money]
        case .call, .text: [.phone]
        case .findPlaces, .directions: [.places]
        case .calendar, .addEvent, .chores: [.family]
        case .groceries, .addGroceries, .mealPlan: [.meals]
        case .foodLog: [.food]
        case .reading: [.study]
        case .remember, .openApp, .general, .unsupported: [.general]
        }
    }
}
