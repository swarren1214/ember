import AlarmKit
import Contacts
import EventKit
import Foundation
import MapKit
import MessageUI
import Observation
import SwiftUI

// Ember's actions on the phone itself: texts and email (filled in, you send), calendar events and
// reminders (EventKit), timers and alarms (AlarmKit, so they ring with Ember closed), and
// directions (Apple Maps). Everything runs on the device; numbers and addresses never go to a
// model. Each permission is asked the first time an action needs it.

// MARK: - Contacts

nonisolated struct EmberContact: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var phones: [String]
    var emails: [String]
    /// "mobile", for telling two numbers apart.
    var phoneLabel: String?
}

nonisolated enum EmberContacts {
    enum Lookup: Sendable {
        case found(EmberContact)
        case several([EmberContact])
        case none
        case denied
    }

    /// People in Contacts matching a name ("Sarah", "Mom"), with what's needed: a phone number
    /// for a text, an email address for an email.
    static func find(_ name: String, needs: KeyPath<EmberContact, [String]>) async -> Lookup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .none }
        guard await EmberContactSearch.hasAccess() else { return .denied }
        let matches = await Task.detached(priority: .userInitiated) { () -> [EmberContact] in
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactIdentifierKey] as [CNKeyDescriptor]
            // By name, nickname ("Mom") or relationship on their card ("mother: Jane").
            let found = EmberContactSearch.contacts(matching: name, keys: keys)
            return found.map { contact in
                let order = [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone, CNLabelPhoneNumberMain]
                let phones = contact.phoneNumbers.sorted {
                    (order.firstIndex(of: $0.label ?? "") ?? 9) < (order.firstIndex(of: $1.label ?? "") ?? 9)
                }
                let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                return EmberContact(id: contact.identifier, name: full.isEmpty ? contact.organizationName : full,
                                    phones: phones.map { $0.value.stringValue },
                                    emails: contact.emailAddresses.map { $0.value as String },
                                    phoneLabel: phones.first?.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) })
            }
        }.value
        let usable = matches.filter { !$0[keyPath: needs].isEmpty }
        switch usable.count {
        case 0: return .none
        case 1: return .found(usable[0])
        default: return .several(Array(usable.prefix(4)))
        }
    }
}

// MARK: - Texts and email

/// A message or email filled in for the person to send, shown once Ember finishes speaking.
struct EmberComposeRequest: Identifiable {
    enum Kind { case message, mail }
    let id = UUID()
    var kind: Kind
    var recipients: [String]
    var subject: String = ""
    var body: String
}

@Observable
final class EmberCompose {
    static let shared = EmberCompose()

    /// Showing now.
    var presented: EmberComposeRequest?
    /// Waiting for Ember to finish speaking.
    @ObservationIgnored private var queued: EmberComposeRequest?

    var canText: Bool { MFMessageComposeViewController.canSendText() }
    var canMail: Bool { MFMailComposeViewController.canSendMail() }

    func queue(_ request: EmberComposeRequest) { queued = request }

    /// Shows what's queued. Mail without a Mail account opens the default mail app instead.
    func presentQueued() {
        guard let request = queued else { return }
        queued = nil
        if request.kind == .mail, !canMail {
            var parts = URLComponents()
            parts.scheme = "mailto"
            parts.path = request.recipients.joined(separator: ",")
            parts.queryItems = [URLQueryItem(name: "subject", value: request.subject), URLQueryItem(name: "body", value: request.body)]
            if let url = parts.url { UIApplication.shared.open(url) }
            return
        }
        if request.kind == .message, !canText {
            let number = request.recipients.first?.filter { $0.isNumber || $0 == "+" } ?? ""
            let body = request.body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "sms:\(number)&body=\(body)") { UIApplication.shared.open(url) }
            return
        }
        presented = request
    }

    var hasQueued: Bool { queued != nil }
}

/// The system's Messages and Mail sheets, filled in.
struct EmberComposeSheet: UIViewControllerRepresentable {
    let request: EmberComposeRequest
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIViewController {
        switch request.kind {
        case .message:
            let controller = MFMessageComposeViewController()
            controller.recipients = request.recipients
            controller.body = request.body
            controller.messageComposeDelegate = context.coordinator
            return controller
        case .mail:
            let controller = MFMailComposeViewController()
            controller.setToRecipients(request.recipients)
            controller.setSubject(request.subject)
            controller.setMessageBody(request.body, isHTML: false)
            controller.mailComposeDelegate = context.coordinator
            return controller
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish()
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}

// MARK: - Calendar and reminders

@MainActor
enum EmberCalendar {
    static let store = EKEventStore()

    static func eventsAllowed() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    static func remindersAllowed() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToReminders()) ?? false
        default: return false
        }
    }

    /// The person's own calendars (not the family's Caloma calendar) in a range.
    static func events(in range: EmberRange) async -> [EKEvent]? {
        guard await eventsAllowed() else { return nil }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    /// Adds an event to the default calendar. Returns its identifier.
    static func addEvent(title: String, start: Date, end: Date, isAllDay: Bool, location: String) async throws -> String {
        guard await eventsAllowed() else { throw EmberActionError("Ember needs Calendar access. Turn it on in Settings › Ember › Calendars.") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        if !location.isEmpty { event.location = location }
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }

    static func removeEvent(_ identifier: String) throws {
        guard let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    static func addReminder(title: String, due: Date?) async throws -> String {
        guard await remindersAllowed() else { throw EmberActionError("Ember needs Reminders access. Turn it on in Settings › Ember › Reminders.") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    static func removeReminder(_ identifier: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    /// Conflicts with a new event, for the confirm card ("you have dentist at 3").
    static func conflicts(start: Date, end: Date) async -> [EKEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay }
    }
}

// MARK: - Timers and alarms

nonisolated struct EmberAlarmData: AlarmMetadata {}

@MainActor
enum EmberAlarms {
    static func allowed() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return true
        case .notDetermined: return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        default: return false
        }
    }

    private static func attributes(_ label: String) -> AlarmAttributes<EmberAlarmData> {
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: label), stopButton: stop)
        return AlarmAttributes(presentation: AlarmPresentation(alert: alert), tintColor: Color(red: 1, green: 0.478, blue: 0.184))
    }

    /// A countdown that rings when it ends. Returns its id.
    static func timer(seconds: TimeInterval, label: String) async throws -> UUID {
        guard await allowed() else { throw EmberActionError("Ember needs permission for alarms. Turn it on in Settings › Ember.") }
        let id = UUID()
        let configuration = AlarmManager.AlarmConfiguration<EmberAlarmData>.timer(duration: seconds, attributes: attributes(label))
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        return id
    }

    /// An alarm at a time.
    static func alarm(at date: Date, label: String) async throws -> UUID {
        guard await allowed() else { throw EmberActionError("Ember needs permission for alarms. Turn it on in Settings › Ember.") }
        let id = UUID()
        let configuration = AlarmManager.AlarmConfiguration<EmberAlarmData>.alarm(schedule: .fixed(date), attributes: attributes(label))
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        return id
    }

    static func cancel(_ id: UUID) throws {
        try AlarmManager.shared.cancel(id: id)
    }
}

// MARK: - Directions

nonisolated enum EmberDirections {
    /// The place nearest the person with that name, as a Maps directions link.
    static func link(to place: String) async -> (name: String, detail: String, url: URL)? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        guard let items = try? await MKLocalSearch(request: request).start().mapItems, let best = items.first else { return nil }
        let coordinate = best.location.coordinate
        let name = best.name ?? place
        var parts = URLComponents(string: "maps://")!
        parts.queryItems = [URLQueryItem(name: "daddr", value: "\(coordinate.latitude),\(coordinate.longitude)"),
                            URLQueryItem(name: "q", value: name)]
        let detail = best.address?.shortAddress ?? ""
        return parts.url.map { (name, detail, $0) }
    }
}
