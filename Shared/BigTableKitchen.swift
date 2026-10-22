import CloudKit
import Foundation

// BigTable's grocery lists as Ember reads them from the "Kitchen" zone. BigTable keeps each list
// as one record whose `content` (encrypted) is JSON: { snapshot: { id, sections: [{ name, icon,
// items: [{ id, name, quantity, meals, bulk }] }], checks: { itemID: Bool }, … }, updatedAt, … }.
// The newest `updatedAt` wins on every device.
//
// Ember edits that JSON in place (JSONSerialization, not a model of its own), so fields Ember
// doesn't know about are kept exactly. Items are added the way BigTable's grocery screen adds
// them ("manual:<millis>:<slug>", about $6 more on the estimate).
//
// Keep in step with BigTable › KitchenStore.swift (KitchenRecords) and GroceryStore.swift.

nonisolated struct GroceryLine: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var quantity: String
    var section: String
    var isChecked: Bool
}

nonisolated struct BigTableGroceries: Sendable {
    /// The record name of the list on the list screen ("grocery-<id>").
    var activeRecordName: String?
    var lines: [GroceryLine] = []
    var estimatedCost: Double?

    static let zoneName = "Kitchen"
    static let aisles = ["Produce", "Meat", "Dairy", "Pantry", "Bakery", "Frozen", "Beverages", "Snacks", "Household", "Other"]

    var remaining: [GroceryLine] { lines.filter { !$0.isChecked } }

    init() {}

    init(records: [CKRecord]) {
        let settings = records.first { $0.recordType == "KitchenSettings" }.flatMap(Self.json)
        let activeID = settings?["activeGroceryID"] as? String
        let lists = records.filter { $0.recordType == "GroceryList" }
        let active = lists.first { $0.recordID.recordName == "grocery-\(activeID ?? "")" }
            ?? lists.max { ($0["updatedAt"] as? Date ?? .distantPast) < ($1["updatedAt"] as? Date ?? .distantPast) }
        guard let active, let content = Self.json(active), let snapshot = content["snapshot"] as? [String: Any] else { return }
        activeRecordName = active.recordID.recordName
        estimatedCost = snapshot["estimatedCost"] as? Double
        let checks = snapshot["checks"] as? [String: Bool] ?? [:]
        for section in snapshot["sections"] as? [[String: Any]] ?? [] {
            let sectionName = section["name"] as? String ?? "Other"
            for item in section["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
                lines.append(GroceryLine(id: id, name: name, quantity: item["quantity"] as? String ?? "",
                                         section: sectionName, isChecked: checks[id] ?? false))
            }
        }
    }

    static func json(_ record: CKRecord) -> [String: Any]? {
        guard let data = record.encryptedValues["content"] as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Lines whose name matches what someone said ("milk" → "Whole milk").
    func matching(_ spoken: String) -> [GroceryLine] {
        let key = Self.fold(spoken)
        guard !key.isEmpty else { return [] }
        let exact = lines.filter { Self.fold($0.name) == key }
        if !exact.isEmpty { return exact }
        return lines.filter { Self.fold($0.name).contains(key) || key.contains(Self.fold($0.name)) }
    }

    // MARK: Changing the list

    /// The active list's record with items added, or nil when there's no list.
    @MainActor
    static func adding(_ items: [(name: String, quantity: String)], in zone: EmberZone, activeRecordName: String?) -> CKRecord? {
        edit(zone: zone, recordName: activeRecordName) { snapshot in
            var sections = snapshot["sections"] as? [[String: Any]] ?? []
            var cost = snapshot["estimatedCost"] as? Double ?? 0
            for (offset, item) in items.enumerated() {
                let name = String(item.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                guard !name.isEmpty else { continue }
                let millis = Int(Date.now.timeIntervalSince1970 * 1000) + offset
                let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                let quantity = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
                let line: [String: Any] = [
                    "id": String("manual:\(millis):\(slug)".prefix(120)),
                    "name": name,
                    "quantity": quantity.isEmpty ? "1" : String(quantity.prefix(240)),
                    "meals": [String](),
                    "bulk": false,
                ]
                let aisle = Self.aisle(for: name)
                if let index = sections.firstIndex(where: { ($0["name"] as? String)?.caseInsensitiveCompare(aisle) == .orderedSame }) {
                    var items = sections[index]["items"] as? [[String: Any]] ?? []
                    items.append(line)
                    sections[index]["items"] = items
                } else {
                    sections.append(["name": aisle, "icon": Self.icon(for: aisle), "items": [line]])
                }
                cost += 6
            }
            snapshot["sections"] = sections
            snapshot["estimatedCost"] = cost
            snapshot["itemCount"] = sections.reduce(0) { $0 + (($1["items"] as? [Any])?.count ?? 0) }
        }
    }

    /// The active list's record with items checked (or unchecked).
    @MainActor
    static func checking(_ ids: [String], checked: Bool, in zone: EmberZone, activeRecordName: String?) -> CKRecord? {
        edit(zone: zone, recordName: activeRecordName) { snapshot in
            var checks = snapshot["checks"] as? [String: Bool] ?? [:]
            for id in ids { checks[id] = checked }
            snapshot["checks"] = checks
        }
    }

    /// The active list's record with items removed (undo of an add).
    @MainActor
    static func removing(_ ids: Set<String>, in zone: EmberZone, activeRecordName: String?) -> CKRecord? {
        edit(zone: zone, recordName: activeRecordName) { snapshot in
            var sections = snapshot["sections"] as? [[String: Any]] ?? []
            for index in sections.indices {
                let items = sections[index]["items"] as? [[String: Any]] ?? []
                sections[index]["items"] = items.filter { !ids.contains($0["id"] as? String ?? "") }
            }
            var checks = snapshot["checks"] as? [String: Bool] ?? [:]
            for id in ids { checks[id] = nil }
            snapshot["sections"] = sections
            snapshot["checks"] = checks
            snapshot["itemCount"] = sections.reduce(0) { $0 + (($1["items"] as? [Any])?.count ?? 0) }
        }
    }

    @MainActor
    private static func edit(zone: EmberZone, recordName: String?, _ change: (inout [String: Any]) -> Void) -> CKRecord? {
        guard let recordName, let existing = zone.records[recordName], var content = json(existing),
              var snapshot = content["snapshot"] as? [String: Any] else { return nil }
        change(&snapshot)
        let now = Date.now
        content["snapshot"] = snapshot
        // BigTable encodes dates as seconds since 2001 (JSONEncoder's default).
        content["updatedAt"] = now.timeIntervalSinceReferenceDate
        guard let data = try? JSONSerialization.data(withJSONObject: content) else { return nil }
        let record = existing.copy() as! CKRecord
        record.encryptedValues["content"] = data as NSData
        record["updatedAt"] = now as NSDate
        return record
    }

    // MARK: Aisles

    /// Which aisle a new item goes in, by its name; Other when unsure.
    static func aisle(for name: String) -> String {
        let n = name.lowercased()
        let map: [(String, [String])] = [
            ("Produce", ["apple", "banana", "lettuce", "spinach", "tomato", "onion", "garlic", "potato", "carrot", "pepper", "lime", "lemon", "avocado", "berr", "grape", "fruit", "vegetable", "celery", "cilantro", "herb", "cucumber", "broccoli", "orange", "mushroom", "zucchini", "kale"]),
            ("Meat", ["chicken", "beef", "pork", "turkey", "bacon", "sausage", "ham", "steak", "fish", "salmon", "shrimp", "ground", "tuna"]),
            ("Dairy", ["milk", "cheese", "yogurt", "butter", "cream", "egg", "sour cream", "cottage"]),
            ("Bakery", ["bread", "bagel", "tortilla", "bun", "roll", "muffin", "croissant"]),
            ("Frozen", ["frozen", "ice cream", "popsicle", "pizza rolls"]),
            ("Beverages", ["juice", "soda", "coffee", "tea", "water", "drink", "sparkling"]),
            ("Snacks", ["chip", "cracker", "cookie", "pretzel", "popcorn", "granola", "candy", "snack"]),
            ("Household", ["paper towel", "toilet paper", "soap", "detergent", "trash bag", "foil", "wrap", "napkin", "tissue", "dish", "sponge", "battery", "batteries", "shampoo", "toothpaste"]),
            ("Pantry", ["rice", "pasta", "flour", "sugar", "oil", "salt", "spice", "sauce", "bean", "cereal", "oat", "peanut butter", "honey", "can", "broth", "vinegar", "syrup", "noodle"]),
        ]
        return map.first { _, words in words.contains { n.contains($0) } }?.0 ?? "Other"
    }

    static func icon(for section: String) -> String {
        let name = section.lowercased()
        if name.contains("produce") { return "🥬" }
        if name.contains("meat") || name.contains("protein") { return "🥩" }
        if name.contains("dairy") || name.contains("egg") { return "🥛" }
        if name.contains("pantry") || name.contains("can") { return "🥫" }
        if name.contains("frozen") { return "❄️" }
        if name.contains("bakery") { return "🥖" }
        if name.contains("beverage") || name.contains("drink") { return "🥤" }
        if name.contains("snack") { return "🍿" }
        if name.contains("household") || name.contains("clean") { return "🧽" }
        return "🛒"
    }

    static func fold(_ text: String) -> String {
        var words = SufficeLedger.fold(text).split(separator: " ").map(String.init)
        words.removeAll { ["the", "a", "an", "some", "of", "our", "my"].contains($0) }
        // Plurals: "eggs" matches "egg".
        return words.map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 }.joined(separator: " ")
    }
}
