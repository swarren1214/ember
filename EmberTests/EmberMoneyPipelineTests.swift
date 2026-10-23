import CloudKit
import Foundation
import Testing
@testable import Ember

// The money pipeline, start to finish without a model: a request (as the understanding stage
// fills it) against a sample household, checked for the right period, the right numbers, and
// honesty about data Ember can't see. "Now" is Thursday, October 22, 2026 at noon in Denver.

struct EmberMoneyPipelineTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        calendar.firstWeekday = 1
        return calendar
    }

    static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!

    let zone = CKRecordZone.ID(zoneName: "Budget")
    let groceries = UUID()
    let dining = UUID()
    let transport = UUID()
    let steve = UUID()
    let kristen = UUID()
    let rent = UUID()

    func day(_ day: Int, _ month: Int = 10) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    func record(_ type: String, _ fields: [String: Any], id: UUID = UUID()) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: "\(type).\(id.uuidString)", zoneID: zone))
        for (key, value) in fields { record.encryptedValues[key] = value as? CKRecordValue }
        return record
    }

    func entry(_ day: Int, _ payee: String, _ cents: Int, _ category: UUID? = nil, month: Int = 10, member: UUID? = nil, income: Bool = false) -> CKRecord {
        var fields: [String: Any] = ["date": self.day(day, month), "payee": payee, "amountCents": cents, "kindRaw": income ? "income" : "expense",
                                     "isReviewed": false]
        if let category { fields["categoryID"] = category.uuidString }
        if let member { fields["memberID"] = member.uuidString }
        return record("LedgerEntry", fields)
    }

    /// A household like the one in testing: Plaid-synced charges ("New", unreviewed, some with no
    /// budget), a paycheck, two people.
    var ledger: SufficeLedger {
        SufficeLedger(records: [
            record("BudgetCategory", ["name": "Groceries", "limitCents": 60000, "sortOrder": 0], id: groceries),
            record("BudgetCategory", ["name": "Eating Out", "limitCents": 20000, "sortOrder": 1], id: dining),
            record("BudgetCategory", ["name": "Transportation", "limitCents": 15000, "sortOrder": 2], id: transport),
            record("BudgetMember", ["name": "Steve"], id: steve),
            record("BudgetMember", ["name": "Kristen"], id: kristen),
            entry(10, "CREDIT CARD 3333 PAYMENT", 2500),
            entry(10, "Uber", 540, transport, member: steve),
            entry(12, "Costco", 13210, groceries, member: kristen),
            entry(14, "Cafe Rio", 4270, dining, member: steve),
            entry(16, "Smith's", 8650, groceries, member: kristen),
            entry(19, "Costco", 9000, groceries, member: kristen),
            entry(21, "Chick-fil-A", 2380, dining, member: steve),
            entry(15, "Paycheck", 300000, income: true),
            entry(28, "Costco", 11000, groceries, month: 9, member: kristen),
            record("Bill", ["name": "Rent", "amountCents": 180000, "dueDay": 1, "frequencyRaw": "monthly", "interval": 1, "isActive": true], id: rent),
            record("Bill", ["name": "Xcel Energy", "amountCents": 9200, "dueDay": 18, "frequencyRaw": "monthly", "interval": 1, "isActive": true,
                            "isVariable": true, "startDate": day(1)]),
            record("Bill", ["name": "Netflix", "amountCents": 1599, "dueDay": 25, "frequencyRaw": "monthly", "interval": 1, "isActive": true,
                            "isAutopay": true, "startDate": day(1)]),
            record("LedgerEntry", ["date": day(1), "payee": "Rent", "amountCents": 180000, "kindRaw": "expense", "billID": rent.uuidString,
                                   "billDueDate": day(1)]),
        ])
    }

    func answer(_ request: EmberRequest, _ question: String, ledger: SufficeLedger? = nil) -> EmberMoneyPipeline.Reply {
        EmberMoneyPipeline.answer(request.checked(against: question), question: question, ledger: ledger ?? self.ledger,
                                  now: Self.now, calendar: Self.calendar)
    }

    // MARK: The failures from testing

    @Test func october10() {
        let reply = answer(EmberRequest(intent: .spending, whenWords: "on October 10"), "How much did we spend on October 10?")
        #expect(reply.text.contains("$30.40"))
        #expect(reply.text.contains("Saturday, October 10"))
        #expect(reply.text.contains("Uber $5.40"))
        #expect(reply.card?.rows.count == 2)
    }

    @Test func october10WithoutTheModelsDate() {
        // The model left the period out: it's found in the question.
        let reply = answer(EmberRequest(intent: .spending), "What did we spend on Saturday, October 10th?")
        #expect(reply.text.contains("$30.40"))
    }

    @Test func lastWeekIsLastWeek() {
        let reply = answer(EmberRequest(intent: .spending), "How much money did we spend last week?")
        // Oct 11–17: Costco 132.10 + Cafe Rio 42.70 + Smith's 86.50.
        #expect(reply.text.contains("$261.30") || reply.text.contains("$261"))
        #expect(reply.text.contains("last week (October 11 to 17)"))
    }

    @Test func purchasesOnADay() {
        let reply = answer(EmberRequest(intent: .transactions, whenWords: "yesterday"), "What did we buy yesterday?")
        #expect(reply.text == "Yesterday: Chick-fil-A $23.80.")
    }

    // MARK: Filters

    @Test func atAStore() {
        let reply = answer(EmberRequest(intent: .spending, whenWords: "this month", placeWords: "Costco"), "How much did we spend at Costco this month?")
        #expect(reply.text.hasPrefix("You spent $222 at Costco this month: Costco $132.10 and Costco $90."))
    }

    @Test func onABudget() {
        let reply = answer(EmberRequest(intent: .spending, whenWords: "this month", budgetWords: "eating out"), "What have we spent on eating out this month?")
        #expect(reply.text.hasPrefix("You spent $66.50 on Eating Out this month"))
    }

    @Test func byAPerson() {
        let reply = answer(EmberRequest(intent: .spending, whenWords: "this month", who: "Kristen"), "How much has Kristen spent this month?")
        #expect(reply.text.hasPrefix("Kristen spent $309 this month"))
    }

    @Test func unknownBudgetSaysWhichExist() {
        let reply = answer(EmberRequest(intent: .spending, budgetWords: "boats"), "How much did we spend on boats?")
        #expect(reply.text.contains("Groceries, Eating Out and Transportation"))
        #expect(reply.asksBack)
    }

    @Test func incomeIsNeverSpending() {
        let reply = answer(EmberRequest(intent: .spending, whenWords: "October 15"), "What did we spend on October 15?")
        #expect(reply.text == "You didn’t spend anything on Thursday, October 15.")
    }

    // MARK: Budgets and bills

    @Test func oneBudget() {
        let reply = answer(EmberRequest(intent: .budgetStatus, budgetWords: "grocery"), "How's the grocery budget?")
        #expect(reply.text == "Groceries has $291 left of $600 this month, with 10 days to go.")
        #expect(reply.card?.fraction != nil)
    }

    @Test func allBudgets() {
        let reply = answer(EmberRequest(intent: .budgetStatus), "How are our budgets doing?")
        #expect(reply.text.hasPrefix("Across your budgets you have $570 left of $950 this month"))
        #expect(reply.text.contains("Nothing is over."))
        #expect(reply.card?.rows.count == 3)
    }

    @Test func billsComingUp() {
        let reply = answer(EmberRequest(intent: .bills), "What bills are coming up?")
        #expect(reply.text.contains("2 bills due in the next 14 days"))
        #expect(reply.text.contains("Netflix $15.99 on Sunday (autopay)"))
        #expect(reply.text.contains("Rent $1,800 on November 1"))
        #expect(reply.text.contains("Xcel Energy was due October 18 and isn’t marked paid."))
    }

    @Test func billsThisWeek() {
        let reply = answer(EmberRequest(intent: .bills, whenWords: "this week"), "What bills are due this week?")
        #expect(reply.text.hasPrefix("No bills due this week (October 22 to 24)."))
        #expect(reply.text.contains("Xcel Energy"))
    }

    @Test func aBillByName() {
        let reply = answer(EmberRequest(intent: .bills, placeWords: "rent", isFollowUp: false), "When is rent due?")
        #expect(reply.text.contains("Rent $1,800 on November 1"))
        #expect(!reply.text.contains("Netflix"))
    }

    // MARK: Honesty about missing data

    @Test func notSyncedIsNotZero() {
        // Ember's copy stops at October 8.
        let old = SufficeLedger(records: [
            record("BudgetCategory", ["name": "Groceries", "limitCents": 60000], id: groceries),
            entry(8, "Costco", 9000, groceries),
        ])
        let reply = answer(EmberRequest(intent: .spending, whenWords: "on October 10"), "How much did we spend on October 10?", ledger: old)
        #expect(reply.text.contains("newest transaction I can see from Suffice is from October 8"))
        #expect(!reply.text.contains("$0"))
    }

    @Test func partlySyncedSaysSo() {
        let old = SufficeLedger(records: [
            record("BudgetCategory", ["name": "Groceries", "limitCents": 60000], id: groceries),
            entry(5, "Costco", 9000, groceries),
            entry(12, "Smith's", 4000, groceries),
        ])
        let reply = answer(EmberRequest(intent: .spending, whenWords: "this month"), "How much did we spend this month?", ledger: old)
        #expect(reply.text.contains("I can only see transactions through October 12"))
    }

    // MARK: The request's copied words

    @Test func wordsNobodySaidAreDropped() {
        let request = EmberRequest(intent: .call, who: "Kristen", townWords: "Santaquin").checked(against: "Call Kristen")
        #expect(request.who == "Kristen")
        #expect(request.townWords.isEmpty)
    }

    @Test func weIsNotAPerson() {
        let request = EmberRequest(intent: .spending, who: "we").checked(against: "How much did we spend?")
        #expect(request.who.isEmpty)
    }

    @Test func followUpsKeepWhatWasSaid() {
        let first = EmberRequest(intent: .spending, whenWords: "this month", placeWords: "Costco")
        let next = EmberRequest(intent: .general, whenWords: "last month", isFollowUp: true).merged(onto: first)
        #expect(next.intent == .spending)
        #expect(next.placeWords == "Costco")
        #expect(next.whenWords == "last month")
    }

    // MARK: Suffice's own copy on the iPhone

    @Test func sufficesCopyRoundTrips() throws {
        let book = ledger.book
        let data = try JSONEncoder().encode(SufficeMoneyPublication(book: book))
        let back = try JSONDecoder().decode(SufficeMoneyPublication.self, from: data).book
        #expect(back.entries.count == book.entries.count)
        let reply = EmberMoneyPipeline.answer(EmberRequest(intent: .spending, whenWords: "on October 10"), question: "How much did we spend on October 10?",
                                              book: back, now: Self.now, calendar: Self.calendar)
        #expect(reply.text.contains("$30.40"))
    }

    @Test func theNewerCopyWins() {
        let mirror = ledger.book
        var local = mirror
        local.entries.removeAll { $0.date > day(15) }
        #expect(SufficeMoney.best(local: local, mirror: mirror)?.source == .iCloud)
        #expect(SufficeMoney.best(local: mirror, mirror: mirror)?.source == .suffice)
        #expect(SufficeMoney.best(local: nil, mirror: mirror)?.source == .iCloud)
    }

    @Test func readsTheCloudsRequest() throws {
        // /v1/ember/understand's reply, with a household name as a token.
        let json = #"{"request":{"intent":"call","whenWords":"","who":"[P2]","placeWords":"","townWords":"","budgetWords":"","items":[],"amountWords":"","isFollowUp":false,"clarify":""}}"#
        struct Reply: Decodable { var request: EmberRequest }
        let request = try JSONDecoder().decode(Reply.self, from: Data(json.utf8)).request
        #expect(request.intent == .call)
        #expect(request.who == "[P2]")
    }

    @Test func aDifferentKindOfQuestionStartsFresh() {
        let first = EmberRequest(intent: .spending, placeWords: "Costco")
        let next = EmberRequest(intent: .call, who: "Mom", isFollowUp: true).merged(onto: first)
        #expect(next.placeWords.isEmpty)
    }
}
