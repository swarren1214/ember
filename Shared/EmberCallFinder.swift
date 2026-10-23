import Foundation
import Contacts
import CoreLocation
import MapKit

// Finds who to call, on the device, using what the phone knows about the person: their contacts,
// and where they are. "Little Caesars in Springville" means the Springville nearest to them, and
// the Little Caesars there; when there are several, Ember asks which. Numbers, addresses and the
// person's location stay on the device; a model hears names, streets and rough distances only.
// Ember never dials: the system's own call screen asks first.

nonisolated struct EmberCallTarget: Sendable, Hashable, Identifiable {
    var name: String
    /// The town, or the contact's label ("mobile").
    var place: String?
    /// "N Main St", without the house number, to tell branches apart.
    var street: String?
    /// From the person, when Ember knows where they are.
    var miles: Double?
    var number: String
    /// The business's logo (img.logo.dev), or nil for a contact.
    var logo: URL?

    var id: String { number }

    var url: URL? {
        let dialable = number.filter { $0.isNumber || $0 == "+" }
        return dialable.isEmpty ? nil : URL(string: "tel:" + dialable)
    }

    /// "N Main St, Springville · 2.4 mi"
    var detail: String {
        let where_ = [street, place].compactMap { $0 }.joined(separator: ", ")
        let away = miles.map { $0 < 10 ? String(format: "%.1f mi", $0) : "\(Int($0.rounded())) mi" }
        return [where_.isEmpty ? nil : where_, away].compactMap { $0 }.joined(separator: " · ")
    }

    /// How a model names this one when asking which: no house number, no phone.
    var spoken: String {
        var parts = [name]
        if let street { parts.append("on \(street)") }
        if let place { parts.append("in \(place)") }
        if let miles { parts.append(String(format: "(%.1f miles away)", miles)) }
        return parts.joined(separator: " ")
    }
}

nonisolated enum EmberCallFinder {
    enum Found: Sendable {
        case one(EmberCallTarget)
        /// Closest first, at most four.
        case several([EmberCallTarget])
    }

    enum Miss: Error, Sendable {
        case nothingFound
        case needsLocation
        /// A person ("Mom", "my wife") and Contacts isn't allowed.
        case needsContacts
        /// A person ("Mom") who isn't in Contacts: never looked up on the map.
        case notInContacts
    }

    /// `who`: a person or a business. `near`: a town they named, or empty. `which`: their answer
    /// when Ember asked which one ("Main Street", "the closest"), or empty.
    static func find(_ who: String, near: String, which: String = "") async -> Result<Found, Miss> {
        let who = who.trimmingCharacters(in: .whitespacesAndNewlines)
        let near = near.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { return .failure(.nothingFound) }
        // A town means a place; otherwise people they know come first.
        if near.isEmpty, which.isEmpty {
            let allowed = await EmberContactSearch.hasAccess()
            if allowed, let person = await contact(named: who) { return .success(.one(person)) }
            // "Mom" or "my wife" is someone they know, never a business on the map.
            if EmberContactSearch.isRelation(who) { return .failure(allowed ? .notInContacts : .needsContacts) }
        }
        let here = await currentLocation()
        return await places(who, near: near, which: which, here: here)
    }

    // MARK: Contacts

    private static func contact(named name: String) async -> EmberCallTarget? {
        await Task.detached(priority: .userInitiated) { () -> EmberCallTarget? in
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                        CNContactNicknameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            for contact in EmberContactSearch.contacts(matching: name, keys: keys) {
                // Mobile first, then iPhone, main, anything.
                let order = [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone, CNLabelPhoneNumberMain]
                let numbers = contact.phoneNumbers.sorted { a, b in
                    (order.firstIndex(of: a.label ?? "") ?? order.count) < (order.firstIndex(of: b.label ?? "") ?? order.count)
                }
                guard let phone = numbers.first else { continue }
                let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let label = phone.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) }
                return EmberCallTarget(name: full.isEmpty ? contact.organizationName : full, place: label, number: phone.value.stringValue)
            }
            return nil
        }.value
    }

    // MARK: Apple Maps

    private static func places(_ name: String, near: String, which: String, here: CLLocation?) async -> Result<Found, Miss> {
        // Where to look: the town they named (the one nearest them), or around them.
        var center = here
        var town: String?
        if !near.isEmpty {
            guard let found = await nearestTown(named: near, from: here) else { return .failure(.nothingFound) }
            center = found.location
            town = found.name
        }
        guard let center else { return .failure(.needsLocation) }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.resultTypes = .pointOfInterest
        let radius: CLLocationDistance = town == nil ? 25_000 : 12_000
        request.region = MKCoordinateRegion(center: center.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return .failure(.nothingFound) }

        var candidates = items.filter { !($0.phoneNumber ?? "").isEmpty }
        // "Little Caesars" means Little Caesars, not every pizza place Maps also suggests.
        let named = candidates.filter { matches($0.name ?? "", name) }
        if !named.isEmpty { candidates = named }
        if let town {
            // In the town, or right next to it.
            candidates = candidates.filter { item in
                city(of: item)?.localizedCaseInsensitiveCompare(town) == .orderedSame
                    || item.location.distance(from: center) < 8_000
            }
        }
        candidates.sort { $0.location.distance(from: center) < $1.location.distance(from: center) }

        var seen = Set<String>()
        var targets: [EmberCallTarget] = []
        for item in candidates {
            guard let number = item.phoneNumber, seen.insert(number.filter(\.isNumber)).inserted else { continue }
            targets.append(EmberCallTarget(
                name: item.name ?? name,
                place: city(of: item),
                street: street(of: item),
                miles: here.map { item.location.distance(from: $0) / 1609.344 },
                number: number,
                logo: EmberLogo.url(website: item.url, name: item.name ?? name)
            ))
        }

        // Their answer to "which one?"
        let pick = which.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !pick.isEmpty, targets.count > 1 {
            if ["closest", "nearest", "first", "the closest one", "the nearest one"].contains(pick) {
                targets = [targets[0]]
            } else {
                let chosen = targets.filter { target in
                    let text = [target.street, target.place, target.name].compactMap { $0 }.joined(separator: " ")
                    return matches(text, pick)
                }
                if !chosen.isEmpty { targets = chosen }
            }
        }

        switch targets.count {
        case 0: return .failure(.nothingFound)
        case 1: return .success(.one(targets[0]))
        default: return .success(.several(Array(targets.prefix(4))))
        }
    }

    /// The town with this name closest to the person: "Springville" is Springville, Utah, for
    /// someone in Provo, and Springville, New York, for someone in Buffalo.
    private static func nearestTown(named name: String, from here: CLLocation?) async -> (name: String, location: CLLocation)? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.resultTypes = .address
        if let here {
            request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 400_000, longitudinalMeters: 400_000)
        }
        guard let items = try? await MKLocalSearch(request: request).start().mapItems, !items.isEmpty else { return nil }
        let towns = items.filter { city(of: $0)?.localizedCaseInsensitiveContains(name) == true }
        var pool = towns.isEmpty ? items : towns
        if let here { pool.sort { $0.location.distance(from: here) < $1.location.distance(from: here) } }
        guard let best = pool.first else { return nil }
        return (city(of: best) ?? name, best.location)
    }

    private static func city(of item: MKMapItem) -> String? {
        item.addressRepresentations?.cityName
    }

    /// The street without the house number: "123 N Main St" → "N Main St".
    private static func street(of item: MKMapItem) -> String? {
        guard let line = item.address?.shortAddress?.split(separator: ",").first else { return nil }
        let words = line.split(separator: " ")
        let rest = words.first?.first?.isNumber == true ? words.dropFirst() : words[...]
        let street = rest.joined(separator: " ")
        return street.isEmpty ? nil : street
    }

    /// Loose name match: case, accents and punctuation don't matter, either way round.
    static func matches(_ text: String, _ query: String) -> Bool {
        func fold(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber || $0 == " " }
                .split(separator: " ").joined(separator: " ")
        }
        let a = fold(text), b = fold(query)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    /// Where the person is, for "nearest". Asks once; gives up after a few seconds.
    private static func currentLocation() async -> CLLocation? {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted { return nil }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Business logos from Logo.dev, the same way BigTable shows restaurants: by the website's
/// domain, or by name when Maps has no website. The publishable key is meant for apps.
nonisolated enum EmberLogo {
    static let publishableKey = "pk_M7uaQUcjQq6Zni3X4QMHSA"

    static func url(website: URL?, name: String) -> URL? {
        let query = "?format=png&size=128&token=\(publishableKey)"
        if let host = website?.host()?.lowercased() {
            let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if !domain.isEmpty, let encoded = domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                return URL(string: "https://img.logo.dev/\(encoded)\(query)")
            }
        }
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "https://img.logo.dev/name/\(encoded)\(query)")
    }
}
