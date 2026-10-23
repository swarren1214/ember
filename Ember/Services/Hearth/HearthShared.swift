// HearthShared.swift — what the Hearth apps (BigTable, Suffice, Sated, Caloma, Hearken, Trove,
// Ember) share
// on the device.
//
// Canonical copy: ~/Developer/hearthkit/HearthShared.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh.
//
// How it works
// - Every app that takes part has the app group `group.com.stephenwarren.hearth`.
// - Each app writes only its own files there, named `<app>.<kind>.json` (`bigtable.meal-plan.json`,
//   `caloma.family.json`), and reads the others'. Two apps never write the same file.
// - A file holds an envelope: which app wrote it, when, the kind and its version, and the value.
// - Writing posts a Darwin notification, so an app that's open can refresh right away.
// - Changes to another app's data go through that app (a link that opens it, or an App Intent),
//   never by writing its file.
// - The app group is on this device only. Other devices get the same data through each app's
//   own sync, and write their own copies.
//
// Compatibility
// - Adding an optional field is fine: older readers ignore it, newer readers see nil.
// - A breaking change bumps the type's `version`; readers skip files whose version they don't
//   know, so an old app never misreads a new file.

import Foundation
import Security

// MARK: - The apps

nonisolated enum HearthApp: String, Codable, CaseIterable, Sendable {
    case bigtable, suffice, sated, caloma, hearken, trove, ember

    var displayName: String {
        switch self {
        case .bigtable: "BigTable"
        case .suffice: "Suffice"
        case .sated: "Sated"
        case .caloma: "Caloma"
        case .hearken: "Hearken"
        case .trove: "Trove"
        case .ember: "Ember"
        }
    }
}

// MARK: - Publications

/// A kind of data an app shares. `kind` names the file; bump `version` only for breaking changes.
nonisolated protocol HearthPublication: Codable, Sendable {
    static var kind: String { get }
    static var version: Int { get }
}

/// One shared file: the value and where it came from.
nonisolated struct HearthEnvelope<Value: HearthPublication>: Codable, Sendable {
    var kind: String
    var version: Int
    var app: HearthApp
    var updatedAt: Date
    var value: Value
}

// MARK: - Reading and writing

nonisolated enum Hearth {
    static let appGroupID = "group.com.stephenwarren.hearth"

    /// Posted (Darwin notification, across apps) whenever any app writes a shared file.
    static let darwinChangeName = "com.stephenwarren.hearth.changed"
    /// Posted on `NotificationCenter.default`, on the main queue, after `startObservingChanges()`.
    static let didChange = Notification.Name("HearthDidChange")

    /// The shared folder, or nil when the app doesn't have the app group (a missing entitlement).
    static var directory: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let folder = base.appending(path: "Shared", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func fileURL(kind: String, app: HearthApp) -> URL? {
        directory?.appending(path: "\(app.rawValue).\(kind).json", directoryHint: .notDirectory)
    }

    /// Writes `value` as `app`'s copy. Unchanged values aren't rewritten, so nothing is
    /// announced for them. Returns whether the file changed.
    @discardableResult
    static func publish<Value: HearthPublication>(_ value: Value, from app: HearthApp, now: Date = .now) -> Bool {
        guard let url = fileURL(kind: Value.kind, app: app) else { return false }
        let encoder = makeEncoder()
        if let existing = read(Value.self, from: app),
           let old = try? encoder.encode(existing.value),
           let new = try? encoder.encode(value),
           old == new {
            return false
        }
        let envelope = HearthEnvelope(kind: Value.kind, version: Value.version, app: app, updatedAt: now, value: value)
        do {
            let data = try encoder.encode(envelope)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return false
        }
        postChange()
        return true
    }

    /// `app`'s copy of this kind, if it has one this app understands. With `maxAge`, older
    /// copies count as missing.
    static func read<Value: HearthPublication>(_ type: Value.Type, from app: HearthApp, maxAge: TimeInterval? = nil, now: Date = .now) -> HearthEnvelope<Value>? {
        guard let url = fileURL(kind: Value.kind, app: app),
              let data = try? Data(contentsOf: url),
              let envelope = try? makeDecoder().decode(HearthEnvelope<Value>.self, from: data),
              envelope.version == Value.version,
              envelope.app == app else { return nil }
        if let maxAge, now.timeIntervalSince(envelope.updatedAt) > maxAge { return nil }
        return envelope
    }

    /// Every app's copy of this kind, newest first.
    static func readAll<Value: HearthPublication>(_ type: Value.Type, maxAge: TimeInterval? = nil, now: Date = .now) -> [HearthEnvelope<Value>] {
        HearthApp.allCases
            .compactMap { read(type, from: $0, maxAge: maxAge, now: now) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Removes `app`'s copy (signing out, erasing app data).
    static func remove<Value: HearthPublication>(_ type: Value.Type, from app: HearthApp) {
        guard let url = fileURL(kind: Value.kind, app: app),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? FileManager.default.removeItem(at: url)
        postChange()
    }

    // MARK: Change notifications

    static func postChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinChangeName as CFString),
            nil, nil, true
        )
    }

    /// Starts relaying other apps' writes as `Hearth.didChange`. Safe to call more than once.
    static func startObservingChanges() {
        HearthObserver.shared.start()
    }

    // MARK: Coding

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Registers once for the cross-app Darwin notification.
nonisolated private final class HearthObserver: @unchecked Sendable {
    static let shared = HearthObserver()
    private let lock = NSLock()
    private var started = false

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Hearth.didChange, object: nil)
                }
            },
            Hearth.darwinChangeName as CFString,
            nil,
            .deliverImmediately
        )
    }
}

// MARK: - Days

/// Calendar days as "YYYY-MM-DD" in the device's time zone, as every app stores them.
nonisolated enum HearthDay {
    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static func date(from string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - The family

/// The people in the household, as one app knows them. Caloma knows roles and colors; BigTable
/// knows birthdays, likes and dislikes, and dietary restrictions. Each publishes its own copy;
/// readers combine them by name.
nonisolated struct HearthFamily: HearthPublication, Hashable {
    static let kind = "family"
    static let version = 1

    var name: String?
    var members: [Member]
    /// Household-wide restrictions ("No peanuts", "Vegetarian").
    var dietaryRestrictions: [String]?

    nonisolated struct Member: Codable, Hashable, Sendable, Identifiable {
        /// Stable within the publishing app only.
        var id: String
        var name: String
        /// "parent", "kid" or "adult".
        var role: String?
        /// 0xRRGGBB.
        var colorHex: UInt32?
        /// "YYYY-MM-DD".
        var birthday: String?
        var likes: [String]?
        var dislikes: [String]?
        /// A small JPEG in the shared photos folder (`Hearth.photo(named:)`), when this app has
        /// a photo of them.
        var photo: String?
    }

    /// The member who owns this device's copy of the app ("This is me"), when the app knows.
    var me: String?
}

// MARK: - Meals (BigTable)

/// The household's planned meals by day, from BigTable: from yesterday through the weeks that
/// are loaded (usually this week and next).
nonisolated struct HearthMealPlan: HearthPublication, Hashable {
    static let kind = "meal-plan"
    static let version = 1

    var days: [Day]

    nonisolated struct Day: Codable, Hashable, Sendable, Identifiable {
        /// "YYYY-MM-DD".
        var date: String
        var meals: [Meal]
        var id: String { date }
    }

    nonisolated struct Meal: Codable, Hashable, Sendable, Identifiable {
        /// "breakfast", "lunch" or "dinner".
        var slot: String
        /// "Sheet-Pan Fajitas + Rice", "Leftovers", "Café Rio".
        var title: String
        /// "recipe", "custom" or "dineOut".
        var kind: String
        var recipeIDs: [String]?
        /// The recipe's photo (the main dish's, when there are several), as an https URL.
        var imageURL: String?
        /// The restaurant's logo when eating out (img.logo.dev), as an https URL.
        var logoURL: String?
        /// Where, when eating out.
        var placeName: String?
        /// Names of the people not eating this meal.
        var notEating: [String]?
        /// Opens this meal in BigTable.
        var link: String?
        /// The recipes in this meal with their ingredients, when BigTable has them (today's and
        /// the next few days' meals). Sated estimates nutrition from these.
        var recipes: [Recipe]?
        var id: String { slot }
    }

    nonisolated struct Recipe: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        /// How many people the ingredient amounts feed.
        var servings: Double?
        var ingredients: [Ingredient]
    }

    nonisolated struct Ingredient: Codable, Hashable, Sendable {
        /// "chicken breast", "shredded cheddar".
        var name: String
        /// 2, 0.5; nil when the recipe doesn't say.
        var amount: Double?
        /// BigTable's measurement ("cup", "tbsp", "lb", "g", "whole"…); nil when there isn't one.
        var unit: String?
    }

    func day(_ date: Date, calendar: Calendar = .current) -> Day? {
        let key = HearthDay.string(from: date, calendar: calendar)
        return days.first { $0.date == key }
    }

    func meal(_ slot: String, on date: Date, calendar: Calendar = .current) -> Meal? {
        day(date, calendar: calendar)?.meals.first { $0.slot == slot }
    }
}

// MARK: - Meal times

/// When the family eats, set in BigTable or Caloma and shared both ways: each app saves the
/// times when they're changed there (`save`), and every app uses the newest copy (`current`).
/// They're kept in the Hearth household too, so the family's other devices and everyone in the
/// household get them. BigTable plans meals, not times; Caloma puts them on the calendar at these
/// times.
nonisolated struct HearthMealTimes: HearthPublication, Hashable {
    static let kind = "meal-times"
    static let version = 1

    /// Minutes after midnight.
    var breakfast: Int
    var lunch: Int
    var dinner: Int

    static let standard = HearthMealTimes(breakfast: 8 * 60, lunch: 12 * 60, dinner: 18 * 60)

    /// The newest times any Hearth app saved here or the household brought from iCloud, or 8 AM,
    /// noon and 6 PM.
    static var current: HearthMealTimes {
        let here = Hearth.readAll(HearthMealTimes.self).first
        let household = Hearth.readAll(HearthHouseholdSnapshot.self)
            .compactMap { copy in copy.value.info.flatMap { info in info.mealTimes.map { ($0, info.mealTimesAt ?? .distantPast) } } }
            .max { $0.1 < $1.1 }
        if let household, household.1 > (here?.updatedAt ?? .distantPast) { return household.0 }
        return here?.value ?? .standard
    }

    /// Saves times changed in `app`: for the apps on this device, and in the household for the
    /// family's other devices.
    @MainActor
    static func save(_ times: HearthMealTimes, from app: HearthApp) {
        _ = Hearth.publish(times, from: app)
        HearthHouseholdStore.shared.updateInfo(mealTimes: times)
    }

    /// For "breakfast", "lunch" or "dinner".
    func minutes(for slot: String) -> Int {
        switch slot {
        case "breakfast": breakfast
        case "lunch": lunch
        default: dinner
        }
    }

    /// The meal's time on that day.
    func start(for slot: String, on day: Date, calendar: Calendar = .current) -> Date {
        let minutes = minutes(for: slot)
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }
}

// MARK: - Groceries (BigTable)

/// The household's current grocery list from BigTable: what it should cost and how much is
/// left to buy. Suffice shows the estimate as planned spending on its groceries budget; it
/// never records it as a transaction, so the real charge isn't counted twice.
nonisolated struct HearthGroceries: HearthPublication, Hashable {
    static let kind = "groceries"
    static let version = 1

    /// The active list, or nil when there isn't one.
    var list: List?

    nonisolated struct List: Codable, Hashable, Sendable, Identifiable {
        var id: String
        /// BigTable's estimate for the whole list, in the device's currency; nil when it has none.
        var estimatedCost: Double?
        var itemCount: Int
        /// Items not checked off yet.
        var remainingCount: Int
        var generatedAt: Date?
        /// The meal plan days it was built for, "YYYY-MM-DD", when BigTable knows them.
        var startDate: String?
        var endDate: String?
        /// Opens the list in BigTable.
        var link: String?
    }
}

// MARK: - Grocery budget (Suffice)

/// This month's groceries budget from Suffice: planned, spent and left. BigTable shows it on
/// the grocery list next to the list's estimate.
nonisolated struct HearthGroceryBudget: HearthPublication, Hashable {
    static let kind = "grocery-budget"
    static let version = 1

    /// The budget's name in Suffice ("Groceries").
    var name: String
    /// The first day of the month it's for, "YYYY-MM-DD".
    var month: String
    var limitCents: Int
    var spentCents: Int
    /// ISO 4217, "USD".
    var currencyCode: String
    /// Opens the budget in Suffice.
    var link: String?

    var leftCents: Int { limitCents - spentCents }
}

// MARK: - Allowance (Caloma)

/// Allowance Caloma has paid out on payday, so Suffice can record it. Each payout has a
/// stable id; Suffice imports each one once, as an expense to review.
nonisolated struct HearthAllowance: HearthPublication, Hashable {
    static let kind = "allowance"
    static let version = 1

    /// ISO 4217, "USD".
    var currencyCode: String
    /// The last 90 days of payouts, newest first.
    var payouts: [Payout]

    nonisolated struct Payout: Codable, Hashable, Sendable, Identifiable {
        var id: String
        /// The kid's name, as in Caloma.
        var name: String
        var cents: Int
        var date: Date
    }
}

// MARK: - Food log (Sated)

/// What the person using this device ate: the last seven days, each with its totals and what
/// was logged, and their daily goals. Written by Sated whenever the log changes (alongside its
/// widgets); Ember reads it to answer "how many calories do I have left?" and "what did I eat
/// yesterday?". It stays on this device, in the app group.
nonisolated struct HearthFoodLog: HearthPublication, Hashable {
    static let kind = "foodLog"
    static let version = 1

    var goals: Totals
    /// Oldest first, ending today.
    var days: [Day]
    /// Opens Sated's Add Food.
    var addLink: String? = "sated://add"

    nonisolated struct Totals: Codable, Hashable, Sendable {
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var fiber: Double
    }

    nonisolated struct Day: Codable, Hashable, Sendable, Identifiable {
        /// "YYYY-MM-DD".
        var date: String
        var totals: Totals
        /// At most 40 a day, in the order eaten.
        var entries: [Entry]
        var id: String { date }
    }

    nonisolated struct Entry: Codable, Hashable, Sendable {
        var name: String
        /// "breakfast", "lunch", "dinner", "snack".
        var meal: String
        var calories: Double
        var protein: Double
        var servings: Double
        var place: String?
    }

    func day(_ date: Date, calendar: Calendar = .current) -> Day? {
        let key = HearthDay.string(from: date, calendar: calendar)
        return days.first { $0.date == key }
    }
}

// MARK: - Reading (Hearken)

/// The reading Hearken's plans have scheduled, by day, for the person using this device:
/// yesterday through the next two weeks. Caloma shows each day's reading on the calendar.
nonisolated struct HearthReading: HearthPublication, Hashable {
    static let kind = "reading"
    static let version = 1

    /// When the daily study reminder is set, in minutes after midnight; nil when it's off.
    var reminderMinutes: Int?
    var days: [Day]
    /// Whose reading it is: their id in the Hearth household, when there is one.
    var readerID: String? = nil

    nonisolated struct Day: Codable, Hashable, Sendable, Identifiable {
        /// "YYYY-MM-DD".
        var date: String
        var readings: [Reading]
        var id: String { date }
    }

    nonisolated struct Reading: Codable, Hashable, Sendable, Identifiable {
        /// The plan enrollment (or group) it comes from.
        var id: String
        /// "Alma 5–7".
        var title: String
        /// "Book of Mormon in 90 Days", or the group's name.
        var planName: String
        var isDone: Bool
        /// Opens the reading in Hearken.
        var link: String?
    }

    func day(_ date: Date, calendar: Calendar = .current) -> Day? {
        let key = HearthDay.string(from: date, calendar: calendar)
        return days.first { $0.date == key }
    }
}

// MARK: - Photos

nonisolated extension Hearth {
    /// People's photos, as small JPEGs named `<app>-<member id>.jpg`.
    static var photosDirectory: URL? {
        guard let folder = directory?.appending(path: "photos", directoryHint: .isDirectory) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Saves someone's photo (already a small JPEG, about 512 px; each app scales its own) and
    /// returns the file name for `HearthFamily.Member.photo`. An unchanged photo isn't rewritten.
    @discardableResult
    static func savePhoto(_ jpeg: Data, memberID: String, from app: HearthApp) -> String? {
        let safeID = memberID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safeID.isEmpty, let url = photosDirectory?.appending(path: "\(app.rawValue)-\(safeID).jpg", directoryHint: .notDirectory) else { return nil }
        if (try? Data(contentsOf: url)) != jpeg {
            do {
                try jpeg.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                return nil
            }
        }
        return url.lastPathComponent
    }

    static func photo(named name: String) -> Data? {
        guard !name.contains("/"), let url = photosDirectory?.appending(path: name, directoryHint: .notDirectory) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Deletes `app`'s photos that its family no longer uses. Call after publishing the family.
    static func removePhotos(from app: HearthApp, except keep: Set<String>) {
        guard let folder = photosDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        for name in names where name.hasPrefix("\(app.rawValue)-") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name, directoryHint: .notDirectory))
        }
    }

    /// The photo another Hearth app has for someone with this name, for people who don't have
    /// one in this app. Full names must match; a lone first name matches a full name only when
    /// one person in that app has that first name. Newest family first.
    static func sharedPhoto(forName name: String, excluding app: HearthApp) -> Data? {
        let wanted = HearthNames.normalized(name)
        guard !wanted.isEmpty else { return nil }
        for family in readAll(HearthFamily.self) where family.app != app {
            let withPhotos = family.value.members.filter { $0.photo != nil }
            if let exact = withPhotos.first(where: { HearthNames.normalized($0.name) == wanted }),
               let data = exact.photo.flatMap(photo(named:)) {
                return data
            }
            let first = HearthNames.firstName(wanted)
            let wantedIsFirstOnly = !wanted.contains(" ")
            let sameFirst = family.value.members.filter { HearthNames.firstName(HearthNames.normalized($0.name)) == first }
            if sameFirst.count == 1, let match = sameFirst.first,
               wantedIsFirstOnly || !HearthNames.normalized(match.name).contains(" "),
               let data = match.photo.flatMap(photo(named:)) {
                return data
            }
        }
        return nil
    }
}

nonisolated enum HearthNames {
    /// Lowercased, trimmed, single spaces.
    static func normalized(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func firstName(_ normalized: String) -> String {
        String(normalized.split(separator: " ").first ?? "")
    }
}

// MARK: - One sign-in for every app

/// The Hearth account's Supabase session, shared by the apps that use the Hearth API (BigTable,
/// Suffice, Sated). Only signed-in accounts are shared, never anonymous sessions.
///
/// Rules every app follows, so one refresh token is never spent twice:
/// - On launch, an app with no session (or only an anonymous one) adopts the shared one.
/// - Before refreshing, re-read the shared session: if another app already refreshed it for the
///   same user, use that instead.
/// - After signing in or refreshing, save it here.
/// - Signing out in one app signs out of all of them (`HearthAccounts.signOutEverywhere()`).
nonisolated struct HearthSharedSession: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Seconds since 1970.
    var expiresAt: Double
    var userID: String
    var email: String?
    /// Which app wrote it last. Optional, and read leniently: a newer Hearth app this build
    /// doesn't know (Ember, before this build had it) must never make the whole sign-in
    /// unreadable, because an unreadable sign-in used to read as "signed out everywhere".
    var updatedBy: HearthApp?

    init(accessToken: String, refreshToken: String, expiresAt: Double, userID: String, email: String?, updatedBy: HearthApp?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
        self.updatedBy = updatedBy
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        expiresAt = try container.decode(Double.self, forKey: .expiresAt)
        userID = try container.decode(String.self, forKey: .userID)
        email = try? container.decodeIfPresent(String.self, forKey: .email)
        updatedBy = try? container.decodeIfPresent(HearthApp.self, forKey: .updatedBy)
    }
}

/// Who signed in with Apple on this device. Apple's user ID is the same in every app from the
/// same developer team, so Hearken and Caloma can offer "Continue as Steve" without asking
/// Apple again. Apple only shares the name and email the first time, so later apps rely on this.
nonisolated struct HearthSharedAppleID: Codable, Sendable, Equatable {
    var userID: String
    var fullName: String?
    var email: String?
    /// Read leniently, as in `HearthSharedSession`.
    var updatedBy: HearthApp?

    init(userID: String, fullName: String?, email: String?, updatedBy: HearthApp?) {
        self.userID = userID
        self.fullName = fullName
        self.email = email
        self.updatedBy = updatedBy
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(String.self, forKey: .userID)
        fullName = try? container.decodeIfPresent(String.self, forKey: .fullName)
        email = try? container.decodeIfPresent(String.self, forKey: .email)
        updatedBy = try? container.decodeIfPresent(HearthApp.self, forKey: .updatedBy)
    }
}

/// The shared sign-in, kept in the Keychain under the Hearth app group (so only these apps can
/// read it), readable after the first unlock for background refreshes.
nonisolated enum HearthAccounts {
    private static let service = "com.stephenwarren.hearth.account"

    static func session() -> HearthSharedSession? { load(HearthSharedSession.self, account: "session") }

    static func saveSession(_ session: HearthSharedSession) {
        if self.session() != session { save(session, account: "session") }
    }

    static func appleID() -> HearthSharedAppleID? { load(HearthSharedAppleID.self, account: "apple") }

    /// Keeps a name or email already shared when the new sign-in didn't include one.
    static func saveAppleID(_ identity: HearthSharedAppleID) {
        var merged = identity
        if let existing = appleID(), existing.userID == identity.userID {
            merged.fullName = identity.fullName ?? existing.fullName
            merged.email = identity.email ?? existing.email
        }
        if appleID() != merged { save(merged, account: "apple") }
    }

    /// Supabase rejected this session's refresh token: it's dead in every app. Removes it (only
    /// if it's still the shared one, so a newer sign-in or refresh stays), and every app follows
    /// it out. Call it wherever a refresh is rejected, instead of only dropping the app's copy.
    static func discardSession(ifRefreshToken refreshToken: String) {
        guard let current = session(), current.refreshToken == refreshToken else { return }
        delete(account: "session")
        Hearth.postChange()
    }

    /// The shared access token while it's still good for a minute, without refreshing it (only
    /// apps with their own session refresh, so a token is never spent twice). For apps without
    /// an API client of their own (Caloma, Trove).
    static func currentAccessToken() -> String? {
        guard let current = session(), current.expiresAt > Date.now.timeIntervalSince1970 + 60 else { return nil }
        return current.accessToken
    }

    /// The account an access token belongs to (its `sub`), read without checking the signature:
    /// only to make sure a call goes out as the shared sign-in's account.
    static func userID(ofAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["sub"] as? String
    }

    /// Signs out of every Hearth app on this device. Each app notices on `Hearth.didChange`
    /// (or next launch) and clears its own copy.
    static func signOutEverywhere() {
        delete(account: "session")
        delete(account: "apple")
        Hearth.postChange()
    }

    /// True only when the Keychain says the shared session isn't there: signed out in another
    /// Hearth app. A nil `session()` alone doesn't mean that; the Keychain may be unreadable just
    /// then (locked before the first unlock, a busy securityd) or hold an entry this build can't
    /// read. Only this may sign an app out.
    static var sessionIsGone: Bool { isMissing(account: "session") }

    /// As `sessionIsGone`, for the shared Apple ID.
    static var appleIDIsGone: Bool { isMissing(account: "apple") }

    // MARK: Keychain

    private static func isMissing(account: String) -> Bool {
        var request = query(account: account)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &result) == errSecItemNotFound
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Hearth.appGroupID,
        ]
    }

    private static func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account: account)
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess { Hearth.postChange() }
    }

    private static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
