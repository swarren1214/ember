import Testing
@testable import Ember

// Privacy rule 5: a leak test. The redactor must leave nothing that identifies the household.

struct EmberRedactorTests {
    let household = [
        EmberPerson(name: "Steve Warren", role: "parent", age: 41),
        EmberPerson(name: "Ana Warren", role: "parent", age: 39),
        EmberPerson(name: "Mia Warren", role: "kid", age: 8),
    ]

    @Test func householdNamesBecomeTokens() {
        var redactor = EmberRedactor(household: household)
        let out = redactor.redact("Can Mia go to practice? Tell Ana Warren I'm leaving.")
        #expect(!out.contains("Mia"))
        #expect(!out.contains("Ana"))
        #expect(out.contains("[P3]"))
        #expect(out.contains("[P2]"))
        #expect(redactor.restore(out).contains("Mia"))
    }

    @Test func possessivesKeepTheirToken() {
        var redactor = EmberRedactor(household: household)
        #expect(redactor.redact("Mia's birthday dinner") == "[P3]'s birthday dinner")
    }

    @Test func identifiersAreRemoved() {
        var redactor = EmberRedactor(household: household)
        let out = redactor.redact("Email sam@example.com or call 801-555-0134, card 4111 1111 1111 1111.")
        #expect(EmberRedactor.leaks(in: out).isEmpty)
        #expect(!out.contains("example.com"))
        #expect(!out.contains("4111"))
    }

    @Test func rosterCarriesNoNames() {
        let redactor = EmberRedactor(household: household)
        #expect(redactor.roster.map(\.token) == ["[P1]", "[P2]", "[P3]"])
        #expect(redactor.roster[2].ageBand == "5–12")
    }

    @Test func moneyTimesAndDatesStay() {
        var redactor = EmberRedactor(household: household)
        let text = "Dining has $86 left; practice is at 5:40 on 2026-10-24."
        #expect(redactor.redact(text) == text)
    }

    @Test func sentencesSplitWithoutBreakingNumbers() {
        var splitter = EmberSentenceSplitter()
        #expect(splitter.feed("It costs $1.50 at 5:40. Then") == ["It costs $1.50 at 5:40."])
        #expect(splitter.flush() == "Then")
    }
}
