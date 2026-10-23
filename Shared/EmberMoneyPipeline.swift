import Foundation

// Money questions, start to finish in plain code (Ember Assistant Architecture › Resolving and
// querying, Answering):
//
//   EmberRequest  →  the period worked out (EmberDates)  →  HearthMoney: the same query, budget
//   and bill math, and the same wording Suffice's own Ask uses
//
// No model runs here: the same request always gives the same answer, every number comes from the
// ledger, the period is always said, and data Ember can't see is never read as $0.

nonisolated enum EmberMoneyPipeline {
    /// What Ember says and shows.
    struct Reply: Sendable {
        var text: String
        var card: EmberAnswer?
        /// Ember asked something back (which day, which budget): listen for the answer.
        var asksBack = false
    }

    /// The intents answered here.
    static func handles(_ intent: EmberIntent) -> Bool {
        switch intent {
        case .spending, .transactions, .budgetStatus, .bills: true
        default: false
        }
    }

    static func answer(_ request: EmberRequest, question: String, ledger: SufficeLedger, coverage: HearthMoney.Coverage? = nil,
                       now: Date = .now, calendar: Calendar = .current) -> Reply {
        let kind: HearthMoney.Ask.Kind
        let lean: EmberDates.Lean
        let fallback: String
        switch request.intent {
        case .transactions: (kind, lean, fallback) = (.transactions, .past, "last 7 days")
        case .budgetStatus: (kind, lean, fallback) = (.budget, .past, "this month")
        case .bills: (kind, lean, fallback) = (.bills, .future, "next 14 days")
        default: (kind, lean, fallback) = (.spending, .past, "this week")
        }

        // When: the model's words if they read as a date, else words in the question, else the
        // default. Words that aren't a date get a question back, never a silent default.
        let when: String
        if !request.whenWords.isEmpty, EmberDates.reads(request.whenWords, lean: lean, now: now, calendar: calendar) {
            when = request.whenWords
        } else if let said = EmberDates.phrase(in: question, now: now, calendar: calendar) {
            when = said
        } else if !request.whenWords.isEmpty {
            return Reply(text: "Which day or dates do you mean?", asksBack: true)
        } else {
            when = ""
        }
        let range = EmberDates.range(when.isEmpty ? fallback : when, lean: lean, fallback: fallback, now: now, calendar: calendar)
        var span = HearthMoney.Span(start: range.start, end: range.end)
        if kind == .bills {
            // Bills look ahead from today (late ones come along); with no period, two weeks.
            let today = calendar.startOfDay(for: now)
            if when.isEmpty { span = HearthMoney.Span(start: today, end: calendar.date(byAdding: .day, value: 14, to: today) ?? today) }
            span.start = max(span.start, today)
        }

        let ask = HearthMoney.Ask(kind: kind, span: span, said: when, person: request.who, budget: request.budgetWords,
                                  place: request.placeWords)
        let book = ledger.book
        let reply = HearthMoney.answer(ask, book: book, coverage: coverage ?? HearthMoney.Coverage(book), now: now, calendar: calendar)
        return Reply(text: reply.text, card: reply.hasCard ? card(reply) : nil, asksBack: reply.asksBack)
    }

    private static func card(_ reply: HearthMoney.Reply) -> EmberAnswer {
        EmberAnswer(facts: "", title: reply.title, value: reply.value, subtitle: reply.subtitle,
                    rows: reply.rows.map { EmberRow(title: $0.title, value: $0.value, detail: $0.detail, done: $0.done) },
                    fraction: reply.fraction)
    }
}
