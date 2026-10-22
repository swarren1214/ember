import Foundation
import Contacts
import CoreLocation
import MapKit

// Finds who to call, on the device: the person's contacts, then places in Apple Maps. The number
// stays on the device (it's on the card and in the tel: link); a model only hears the name.
// Ember never places the call: the system's own call screen asks first.

nonisolated struct EmberCallTarget: Sendable, Hashable {
    var name: String
    /// "Springville", or the contact's label ("mobile").
    var place: String?
    var number: String

    var url: URL? {
        let dialable = number.filter { $0.isNumber || $0 == "+" }
        return dialable.isEmpty ? nil : URL(string: "tel:" + dialable)
    }

    var detail: String { [place, number].compactMap { $0 }.joined(separator: " · ") }
}

nonisolated enum EmberCallFinder {
    enum Miss: Sendable {
        case nothingFound
        case needsLocation
    }

    /// `who`: a person or a business. `near`: a town they named, or empty for "near me".
    static func find(_ who: String, near: String) async -> Result<EmberCallTarget, Miss> {
        let who = who.trimmingCharacters(in: .whitespacesAndNewlines)
        let near = near.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { return .failure(.nothingFound) }
        // A town means a place; otherwise people they know come first.
        if near.isEmpty, let person = await contact(named: who) { return .success(person) }
        return await place(who, near: near)
    }

    // MARK: Contacts

    private static func contact(named name: String) async -> EmberCallTarget? {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            guard (try? await store.requestAccess(for: .contacts)) == true else { return nil }
        case .authorized, .limited:
            break
        default:
            return nil
        }
        return await Task.detached(priority: .userInitiated) { () -> EmberCallTarget? in
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                        CNContactNicknameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
            for contact in found {
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

    private static func place(_ name: String, near: String) async -> Result<EmberCallTarget, Miss> {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = near.isEmpty ? name : "\(name) \(near)"
        request.resultTypes = .pointOfInterest
        var here: CLLocation?
        if near.isEmpty {
            here = await currentLocation()
            guard let here else { return .failure(.needsLocation) }
            request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return .failure(.nothingFound) }
        var withPhones = items.filter { !($0.phoneNumber ?? "").isEmpty }
        if !near.isEmpty {
            // Prefer the town they said, when Maps also offers others.
            let inTown = withPhones.filter { city(of: $0)?.localizedCaseInsensitiveContains(near) == true }
            if !inTown.isEmpty { withPhones = inTown }
        } else if let here {
            withPhones.sort { $0.location.distance(from: here) < $1.location.distance(from: here) }
        }
        guard let best = withPhones.first, let number = best.phoneNumber else { return .failure(.nothingFound) }
        return .success(EmberCallTarget(name: best.name ?? name, place: city(of: best), number: number))
    }

    private static func city(of item: MKMapItem) -> String? {
        item.addressRepresentations?.cityName
    }

    /// Where the person is, roughly, for "call the pizza place". Asks once; gives up after a few seconds.
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
