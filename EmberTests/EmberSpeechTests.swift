import Testing
@testable import Ember

// Text made ready to be heard.

struct EmberSpeechTests {
    func say(_ text: String) -> String { EmberSpeech.prepare(text) }

    @Test func money() {
        #expect(say("$86 left") == "eighty-six dollars left")
        #expect(say("$1,240.50 this month") == "twelve hundred forty-one dollars this month")
        #expect(say("$12.50 at Target") == "twelve dollars and fifty cents at Target")
        #expect(say("$1 each") == "one dollar each")
        #expect(say("$0.99") == "ninety-nine cents")
        #expect(say("$2,000") == "two thousand dollars")
        #expect(say("-$40") == "minus forty dollars")
    }

    @Test func times() {
        #expect(say("Dinner at 6:30 PM") == "Dinner at six thirty P M")
        #expect(say("at 7:05 am") == "at seven oh five A M")
        #expect(say("at 5pm") == "at five P M")
        #expect(say("12:00 PM") == "noon")
    }

    @Test func datesAndOrdinals() {
        #expect(say("Oct 22") == "October twenty-second")
        #expect(say("on September 1st") == "on September first")
        #expect(say("the 3rd") == "the third")
        #expect(say("in 2026") == "in twenty twenty-six")
    }

    @Test func unitsAndAbbreviations() {
        #expect(say("1,850 kcal") == "one thousand eight hundred fifty calories")
        #expect(say("40% of it") == "forty percent of it")
        #expect(say("on N Main St") == "on North Main Street")
        #expect(say("Dr. Patel at 3pm") == "Doctor Patel at three P M")
        #expect(say("2.5 mi away") == "two point five miles away")
        #expect(say("salt & pepper") == "salt and pepper")
    }

    @Test func neverReadsNumbersOrLinks() {
        #expect(say("Call (801) 555-0134 now") == "Call the number now")
        #expect(say("See https://hearthapps.com/x") == "See the link")
        #expect(!say("Email me@example.com").contains("@"))
    }

    @Test func ordinalWords() {
        #expect(EmberSpeech.ordinal(1) == "first")
        #expect(EmberSpeech.ordinal(22) == "twenty-second")
        #expect(EmberSpeech.ordinal(30) == "thirtieth")
        #expect(EmberSpeech.ordinal(12) == "twelfth")
    }
}
