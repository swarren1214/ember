import Foundation
import Testing
@testable import Ember

// The dates people say, read the same way by every tool. "Now" is Thursday, October 22, 2026 at
// noon in Denver, with weeks starting on Sunday.

struct EmberDatesTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        calendar.firstWeekday = 1
        return calendar
    }

    static let now: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
    }()

    func day(_ month: Int, _ day: Int, _ year: Int = 2026) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func range(_ text: String, lean: EmberDates.Lean = .past) -> EmberRange {
        EmberDates.range(text, lean: lean, now: Self.now, calendar: Self.calendar)
    }

    @Test func todayAndYesterday() {
        #expect(range("today") == EmberRange(start: day(10, 22), end: day(10, 23)))
        #expect(range("yesterday") == EmberRange(start: day(10, 21), end: day(10, 22)))
        #expect(range("tonight") == EmberRange(start: day(10, 22), end: day(10, 23)))
    }

    @Test func weeksStartOnSunday() {
        #expect(range("this week") == EmberRange(start: day(10, 18), end: day(10, 25)))
        #expect(range("last week") == EmberRange(start: day(10, 11), end: day(10, 18)))
        #expect(range("next week") == EmberRange(start: day(10, 25), end: day(11, 1)))
        #expect(range("this week so far").throughToday(now: Self.now, calendar: Self.calendar) == EmberRange(start: day(10, 18), end: day(10, 23)))
    }

    @Test func months() {
        #expect(range("this month") == EmberRange(start: day(10, 1), end: day(11, 1)))
        #expect(range("last month") == EmberRange(start: day(9, 1), end: day(10, 1)))
        #expect(range("in September") == EmberRange(start: day(9, 1), end: day(10, 1)))
        // A month that hasn't come yet this year, asked about the past: last year's.
        #expect(range("December") == EmberRange(start: day(12, 1, 2025), end: day(1, 1, 2026)))
        #expect(range("December", lean: .future) == EmberRange(start: day(12, 1), end: day(1, 1, 2027)))
    }

    @Test func spansAndSince() {
        #expect(range("last 7 days") == EmberRange(start: day(10, 16), end: day(10, 23)))
        #expect(range("past 2 weeks") == EmberRange(start: day(10, 9), end: day(10, 23)))
        #expect(range("since the 1st") == EmberRange(start: day(10, 1), end: day(10, 23)))
        #expect(range("since October 5") == EmberRange(start: day(10, 5), end: day(10, 23)))
        #expect(range("October 5 to October 12") == EmberRange(start: day(10, 5), end: day(10, 13)))
        #expect(range("oct 5 - 12") == EmberRange(start: day(10, 5), end: day(10, 13)))
    }

    @Test func weekdaysLeanTheWayAsked() {
        // Thursday the 22nd: "Saturday" is the coming one for plans, the last one for spending.
        #expect(range("Saturday", lean: .future) == EmberRange(start: day(10, 24), end: day(10, 25)))
        #expect(range("Saturday", lean: .past) == EmberRange(start: day(10, 17), end: day(10, 18)))
        #expect(range("last Monday") == EmberRange(start: day(10, 19), end: day(10, 20)))
        #expect(range("this weekend", lean: .future) == EmberRange(start: day(10, 24), end: day(10, 26)))
    }

    @Test func unknownFallsBack() {
        #expect(EmberDates.range("whenever", fallback: "this week", now: Self.now, calendar: Self.calendar) == EmberRange(start: day(10, 18), end: day(10, 25)))
    }

    @Test func moments() {
        let cal = Self.calendar
        func at(_ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))! }
        #expect(EmberDates.moment("tomorrow at 3", now: Self.now, calendar: cal) == at(10, 23, 15))
        #expect(EmberDates.moment("Saturday 9am", now: Self.now, calendar: cal) == at(10, 24, 9))
        #expect(EmberDates.moment("saturday at 9:30 am", now: Self.now, calendar: cal) == at(10, 24, 9, 30))
        #expect(EmberDates.moment("in 20 minutes", now: Self.now, calendar: cal) == Self.now.addingTimeInterval(1200))
        // A time already past today means tomorrow.
        #expect(EmberDates.moment("at 8am", now: Self.now, calendar: cal) == at(10, 23, 8))
        #expect(EmberDates.moment("6:30pm", now: Self.now, calendar: cal) == at(10, 22, 18, 30))
    }
}
