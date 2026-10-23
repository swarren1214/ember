import Contacts
import Foundation

// Finding someone in Contacts the way people say it: "Sarah", "Sarah Lee", "Mom", "my wife".
//
// 1. By name (given, family, middle, organization).
// 2. By nickname: many people save their mother as "Mom".
// 3. By relationship: iOS keeps "mother: Jane Warren" on the person's own card (Contacts ›
//    My Card › add related name), and Siri uses it. "Mom" then means Jane Warren.
//
// Runs off the main thread; nothing leaves the device.

nonisolated enum EmberContactSearch {
    /// Relationship words, and the Contacts labels they mean.
    static let relations: [String: [String]] = {
        var table: [String: [String]] = [:]
        func add(_ words: [String], _ labels: [String]) { for word in words { table[word] = labels } }
        add(["mom", "mother", "mum", "mommy", "mama", "ma"], [CNLabelContactRelationMother])
        add(["dad", "father", "daddy", "papa", "pa"], [CNLabelContactRelationFather])
        add(["wife"], [CNLabelContactRelationWife, CNLabelContactRelationSpouse])
        add(["husband"], [CNLabelContactRelationHusband, CNLabelContactRelationSpouse])
        add(["spouse"], [CNLabelContactRelationSpouse, CNLabelContactRelationWife, CNLabelContactRelationHusband])
        add(["partner", "boyfriend", "girlfriend"], [CNLabelContactRelationPartner, CNLabelContactRelationBoyfriend, CNLabelContactRelationGirlfriend])
        add(["brother"], [CNLabelContactRelationBrother])
        add(["sister"], [CNLabelContactRelationSister])
        add(["son"], [CNLabelContactRelationSon])
        add(["daughter"], [CNLabelContactRelationDaughter])
        add(["grandma", "grandmother", "granny", "nana"], [CNLabelContactRelationGrandmother])
        add(["grandpa", "grandfather", "granddad", "grandad"], [CNLabelContactRelationGrandfather])
        add(["aunt", "auntie"], [CNLabelContactRelationAunt])
        add(["uncle"], [CNLabelContactRelationUncle])
        add(["friend", "best friend"], [CNLabelContactRelationFriend])
        add(["assistant"], [CNLabelContactRelationAssistant])
        add(["boss", "manager"], [CNLabelContactRelationManager])
        return table
    }()

    /// "my mom" → "mom"; "Mom's cell" → "mom".
    static func plain(_ spoken: String) -> String {
        var text = spoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["my ", "our "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        for suffix in ["'s cell", "’s cell", "'s phone", "’s phone", "'s mobile", "’s mobile"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        // "Kristen." or "Kristen?" as the model or the recognizer wrote it.
        text = text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        return text
    }

    /// Whether this is a relationship ("mom", "my wife"), which only Contacts can answer: never
    /// a business to look up on the map.
    static func isRelation(_ spoken: String) -> Bool { relations[plain(spoken)] != nil }

    /// Contacts matching what was said, with `keys` fetched. Call off the main thread, with
    /// Contacts access already granted.
    static func contacts(matching spoken: String, keys: [CNKeyDescriptor]) -> [CNContact] {
        let store = CNContactStore()
        let name = plain(spoken)
        guard !name.isEmpty else { return [] }
        // Each key once (a key asked for twice can make Contacts refuse the fetch).
        var allKeys: [CNKeyDescriptor] = []
        var seenKeys = Set<String>()
        let extra: [CNKeyDescriptor] = [CNContactNicknameKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor,
                                        CNContactFamilyNameKey as CNKeyDescriptor, CNContactMiddleNameKey as CNKeyDescriptor,
                                        CNContactOrganizationNameKey as CNKeyDescriptor, CNContactRelationsKey as CNKeyDescriptor]
        for key in keys + extra {
            if let name = key as? String {
                if seenKeys.insert(name).inserted { allKeys.append(key) }
            } else {
                allKeys.append(key)
            }
        }

        // 1 and 2: the name or nickname as said ("Mom" saved as a name or nickname wins).
        var found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: allKeys)) ?? []
        var everyone: [CNContact] = []
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: allKeys)) { contact, _ in everyone.append(contact) }
        let nicknamed = everyone.filter { $0.nickname.lowercased() == name }
        if !nicknamed.isEmpty { found = nicknamed + found.filter { candidate in !nicknamed.contains { $0.identifier == candidate.identifier } } }
        if found.isEmpty, relations[name] == nil {
            // Contacts' own name search missed (an accent, a middle name, "Kris" for Kristen):
            // look through everyone, first names first.
            let wanted = fold(name)
            let words = wanted.split(separator: " ").map(String.init)
            found = everyone.filter { contact in
                let first = fold(contact.givenName), last = fold(contact.familyName), nick = fold(contact.nickname)
                let full = [first, fold(contact.middleName), last].filter { !$0.isEmpty }.joined(separator: " ")
                let org = fold(contact.organizationName)
                if full == wanted || first == wanted || nick == wanted || org == wanted { return true }
                if words.count >= 2 { return first == words[0] && last.hasPrefix(words.last ?? "") }
                return first.hasPrefix(wanted) && wanted.count >= 3
            }
        }
        if !found.isEmpty, relations[name] == nil { return found }
        if !nicknamed.isEmpty { return nicknamed }

        // 3: a relationship on the person's card ("mother: Jane Warren"), or a custom label
        // that says it ("Mom").
        let labels = relations[name] ?? []
        var relatedNames: [String] = []
        for contact in everyone {
            for relation in contact.contactRelations {
                let label = relation.label ?? ""
                let spokenLabel = CNLabeledValue<CNContactRelation>.localizedString(forLabel: label).lowercased()
                if labels.contains(label) || spokenLabel == name || label.lowercased() == name {
                    relatedNames.append(relation.value.name)
                }
            }
        }
        var related: [CNContact] = []
        for relatedName in relatedNames where !relatedName.isEmpty {
            let matches = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: relatedName), keysToFetch: allKeys)) ?? []
            for match in matches where !related.contains(where: { $0.identifier == match.identifier }) { related.append(match) }
        }
        return related.isEmpty ? found : related
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Asks for Contacts once; false when it's not allowed.
    static func hasAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            return (try? await CNContactStore().requestAccess(for: .contacts)) == true
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }
}
