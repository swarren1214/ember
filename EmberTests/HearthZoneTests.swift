import CloudKit
import Foundation
import Testing
@testable import Ember

// Ember reads Suffice's, Caloma's and BigTable's iCloud records the way those apps write them.
// These build records with the apps' own field names and check the answers.

struct SufficeLedgerTests {
    let zone = CKRecordZone.ID(zoneName: "Budget")
    let groceries = UUID()
    let dining = UUID()
    let rent = UUID()

    func record(_ type: String, _ id: UUID, _ fields: [String: Any]) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: "\(type).\(id.uuidString)", zoneID: zone))
        for (key, value) in fields {
            record.encryptedValues[key] = value as? CKRecordValue
        }
        return record
    }

    func day(_ day: Int, _ month: Int = 10) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    var ledger: SufficeLedger {
        SufficeLedger(records: [
            record("BudgetCategory", groceries, ["name": "Groceries", "limitCents": 60000, "sortOrder": 0]),
            record("BudgetCategory", dining, ["name": "Eating Out", "limitCents": 20000, "sortOrder": 1]),
            record("LedgerEntry", UUID(), ["date": day(19), "payee": "Costco", "amountCents": 13210, "kindRaw": "expense", "categoryID": groceries.uuidString]),
            record("LedgerEntry", UUID(), ["date": day(20), "payee": "Cafe Rio", "amountCents": 4270, "kindRaw": "expense", "categoryID": dining.uuidString]),
            record("LedgerEntry", UUID(), ["date": day(21), "payee": "Target", "amountCents": 4000, "kindRaw": "expense", "categoryID": groceries.uuidString,
                                           "splitsJSON": "[{\"categoryID\":\"\(groceries.uuidString)\",\"amountCents\":2500},{\"categoryID\":\"\(dining.uuidString)\",\"amountCents\":1500}]"]),
            record("LedgerEntry", UUID(), ["date": day(12), "payee": "Costco", "amountCents": 9000, "kindRaw": "expense", "categoryID": groceries.uuidString]),
            record("LedgerEntry", UUID(), ["date": day(15), "payee": "Paycheck", "amountCents": 300000, "kindRaw": "income"]),
            record("Bill", rent, ["name": "Rent", "amountCents": 180000, "dueDay": 1, "frequencyRaw": "monthly", "interval": 1, "isActive": true]),
            record("PayeeRule", UUID(), ["payeeKey": "costco", "categoryID": groceries.uuidString]),
        ])
    }

    @Test func spendingInARange() {
        let week = EmberRange(start: Calendar.current.startOfDay(for: day(18)), end: Calendar.current.startOfDay(for: day(25)))
        let spent = ledger.spending(in: week)
        #expect(spent.totalCents == 13210 + 4270 + 4000)
        #expect(spent.count == 3)
        // The split counts each part toward its own budget.
        #expect(spent.byBudget.first { $0.0 == "Groceries" }?.1 == 13210 + 2500)
        #expect(spent.byBudget.first { $0.0 == "Eating Out" }?.1 == 4270 + 1500)
        #expect(ledger.spending(in: week, payee: "costco").totalCents == 13210)
        #expect(ledger.spending(in: week, budget: ledger.findCategory("eating out")).totalCents == 4270 + 1500)
    }

    @Test func budgetsForTheMonth() {
        let october = EmberRange(start: day(1).startOfMonth, end: day(1, 11).startOfMonth)
        let statuses = ledger.statuses(in: october)
        let groceries = statuses.first { $0.category.name == "Groceries" }
        #expect(groceries?.spentCents == 13210 + 2500 + 9000)
        #expect(groceries?.leftCents == 60000 - (13210 + 2500 + 9000))
    }

    @Test func findsBudgetsAndRules() {
        #expect(ledger.findCategory("grocery")?.id == groceries)
        #expect(ledger.findCategory("eating out")?.id == dining)
        #expect(ledger.ruleCategory(for: "Costco") == groceries)
    }

    @Test func billsDueAndPaid() {
        let window = EmberRange(start: day(25), end: day(5, 11))
        let dues = ledger.dues(in: window, includeLate: false, now: day(25))
        #expect(dues.count == 1)
        #expect(dues.first?.bill.name == "Rent")
        #expect(dues.first?.isPaid == false)
        #expect(Calendar.current.component(.day, from: dues.first!.date) == 1)
    }

    @Test func skillSaysTheRangeAndComparison() {
        let answer = EmberSkills.spending(ledger, range: "this week", budget: "", place: "", person: "", now: day(22))
        #expect(answer.facts.contains("$215"))
        #expect(answer.facts.contains("days before"))
        let unknown = EmberSkills.spending(ledger, range: "this week", budget: "boats", place: "", person: "", now: day(22))
        #expect(unknown.facts.contains("no budget called"))
    }
}

struct CalomaFamilyTests {
    let zone = CKRecordZone.ID(zoneName: "Caloma")
    let max = UUID(), ella = UUID(), mom = UUID()
    let trash = UUID(), dishes = UUID(), soccer = UUID()

    func record(_ type: String, _ id: UUID, _ fields: [String: Any]) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zone))
        for (key, value) in fields { record[key] = value as? CKRecordValue }
        return record
    }

    func day(_ day: Int, _ hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    var family: CalomaFamily {
        CalomaFamily(records: [
            record("Member", max, ["name": "Max", "roleRaw": "kid"]),
            record("Member", ella, ["name": "Ella", "roleRaw": "kid"]),
            record("Member", mom, ["name": "Ana", "roleRaw": "parent"]),
            record("Chore", trash, ["title": "Take out trash", "points": 5, "assigneeIDsRaw": max.uuidString, "repeatRaw": "daily", "startDate": day(1)]),
            record("Chore", dishes, ["title": "Dishes", "points": 3, "assigneeIDsRaw": ella.uuidString, "repeatRaw": "weekdays", "startDate": day(1)]),
            record("ChoreCompletion", UUID(), ["choreID": trash.uuidString, "memberID": max.uuidString, "day": Calendar.current.startOfDay(for: day(22)),
                                               "statusRaw": "pending", "points": 5, "completedAt": day(22, 9)]),
            record("FamilyEvent", soccer, ["title": "Soccer practice", "start": day(20, 17), "end": day(20, 18), "repeatRaw": "weekly",
                                           "attendeeIDsRaw": ella.uuidString, "driverID": mom.uuidString]),
        ])
    }

    @Test func boardForADay() {
        let board = family.board(on: day(22))
        #expect(board.count == 2)
        #expect(board.first { $0.chore.id == trash }?.status == .pending)
        #expect(board.first { $0.chore.id == dishes }?.status == .open)
        // Saturday: dishes are weekdays only.
        #expect(family.board(on: day(24)).count == 1)
        #expect(family.waitingForApproval.count == 1)
    }

    @Test func weeklyEventsRepeat() {
        let next = EmberRange(start: Calendar.current.startOfDay(for: day(22)), end: Calendar.current.startOfDay(for: day(29)))
        let hits = family.occurrences(in: next)
        #expect(hits.count == 1)
        #expect(Calendar.current.component(.day, from: hits[0].start) == 27)
        #expect(Calendar.current.component(.hour, from: hits[0].start) == 17)
    }

    @Test func findsPeople() {
        #expect(family.findMember("max's")?.id == max)
        #expect(family.findMember("ELLA")?.id == ella)
        #expect(family.findChore("trash")?.id == trash)
    }
}

struct BigTableGroceriesTests {
    func list(checks: [String: Bool] = ["milk": true]) -> [CKRecord] {
        let zone = CKRecordZone.ID(zoneName: "Kitchen")
        let content: [String: Any] = [
            "snapshot": [
                "id": "g1", "generatedAtIso": "2026-10-20", "itemCount": 2, "estimatedCost": 40.0, "source": "manual",
                "sections": [["name": "Dairy", "icon": "🥛", "items": [["id": "milk", "name": "Whole milk", "quantity": "1 gal", "meals": [], "bulk": false]]],
                             ["name": "Produce", "icon": "🥬", "items": [["id": "lime", "name": "Limes", "quantity": "4", "meals": [], "bulk": false]]]],
                "checks": checks,
                "futureField": "kept",
            ],
            "updatedAt": 800_000_000.0,
        ]
        let grocery = CKRecord(recordType: "GroceryList", recordID: CKRecord.ID(recordName: "grocery-g1", zoneID: zone))
        grocery.encryptedValues["content"] = try! JSONSerialization.data(withJSONObject: content) as NSData
        let settings = CKRecord(recordType: "KitchenSettings", recordID: CKRecord.ID(recordName: "settings", zoneID: zone))
        settings.encryptedValues["content"] = try! JSONSerialization.data(withJSONObject: ["activeGroceryID": "g1", "updatedAt": 0.0]) as NSData
        return [grocery, settings]
    }

    @Test func readsTheActiveList() {
        let groceries = BigTableGroceries(records: list())
        #expect(groceries.activeRecordName == "grocery-g1")
        #expect(groceries.lines.count == 2)
        #expect(groceries.remaining.map(\.name) == ["Limes"])
        #expect(groceries.matching("milk").first?.isChecked == true)
        #expect(groceries.matching("lime").count == 1)
    }

    @Test func aislesForNewItems() {
        #expect(BigTableGroceries.aisle(for: "Bananas") == "Produce")
        #expect(BigTableGroceries.aisle(for: "Greek yogurt") == "Dairy")
        #expect(BigTableGroceries.aisle(for: "Paper towels") == "Household")
        #expect(BigTableGroceries.aisle(for: "Birthday candles") == "Other")
    }
}

extension Date {
    var startOfMonth: Date { Calendar.current.dateInterval(of: .month, for: self)!.start }
}
