import CloudKit
import Foundation
import OSLog

// A Hearth app's iCloud zone, mirrored on this device so Ember can read it and save to it the
// way that app does. Suffice keeps the budget in the Hearth container's "Budget" zone and Caloma
// keeps the family in its "Caloma" zone, both synced by the household's engines. Ember doesn't
// run an engine for them; it fetches what changed since its last look (a change token) and keeps
// the records in a file only it can read (complete file protection).
//
// Where a zone lives: the owner's private database, or, for someone who joined another family's
// household, that family's zone in the shared database. The iPhone knows which from the
// household store; the Watch is told by the iPhone.

nonisolated enum EmberZoneError: Error, LocalizedError {
    case noAccount
    case notShared
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noAccount: "This device isn't signed in to iCloud."
        case .notShared: "That app hasn't synced to iCloud from any of your devices yet."
        case .failed(let reason): reason
        }
    }
}

@MainActor
final class EmberZone {
    static let containerID = "iCloud.com.stephenwarren.hearth"

    let zoneName: String
    /// Records by name ("LedgerEntry.6F1C…" for Suffice, a UUID for Caloma).
    private(set) var records: [String: CKRecord] = [:] {
        didSet { version &+= 1 }
    }
    private(set) var lastFetched: Date?
    private(set) var lastError: EmberZoneError?

    /// Who owns the household when this person joined someone else's; nil when it's theirs.
    private(set) var householdOwnerName: String?

    /// The household changed hands (joined or left a family): the mirror starts over.
    func setHouseholdOwner(_ owner: String?) {
        // Still reading the saved mirror: decide once it's read, so a saved owner isn't mistaken
        // for a change.
        if let pending = loading {
            loading = Task { [weak self] in
                await pending.value
                self?.applyOwner(owner)
            }
            return
        }
        applyOwner(owner)
    }

    private func applyOwner(_ owner: String?) {
        guard owner != householdOwnerName else { return }
        forget()
        householdOwnerName = owner
    }

    private var token: CKServerChangeToken?
    private var fetching: Task<Void, Never>?
    private let log = Logger(subsystem: "com.stephenwarren.ember", category: "zone")

    /// The fields Ember reads and writes in this zone. Fetching only these leaves out Suffice's
    /// receipt images and Caloma's photos, which made a first fetch slow and the mirror large.
    private let fieldList: [CKRecord.FieldKey]?
    /// Set when a fetch came back without the records' values: then every field is asked for.
    private var fetchesEverything: Bool {
        get { UserDefaults.standard.bool(forKey: "ember.zone.allKeys.\(zoneName)") }
        set { UserDefaults.standard.set(newValue, forKey: "ember.zone.allKeys.\(zoneName)") }
    }
    var desiredKeys: [CKRecord.FieldKey]? { fetchesEverything ? nil : fieldList }
    /// Repairs tried this launch (at most two).
    private var repairs = 0
    /// Reading the saved mirror happens off the main thread; fetching waits for it.
    private var loading: Task<Void, Never>?

    init(zoneName: String) {
        self.zoneName = zoneName
        self.fieldList = Self.fields[zoneName]
        let url = Self.fileURL(for: zoneName)
        loading = Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
            self?.adopt(saved)
        }
    }

    static let fields: [String: [CKRecord.FieldKey]] = [
        "Budget": ["name", "limitCents", "parentID", "startMonth", "repeatsMonthly", "isArchived", "sortOrder", "createdAt",
                   "date", "payee", "amountCents", "kindRaw", "categoryID", "memberID", "billID", "billDueDate", "splitsJSON",
                   "stashCents", "placeName", "note", "isReviewed", "taxTagRaw", "receiptLink", "receiptSourceRaw",
                   "isVariable", "dueDay", "frequencyRaw", "interval", "startDate", "endDate", "isAutopay", "isActive", "payeeKey"],
        "Caloma": ["name", "roleRaw", "isArchived", "symbol", "showInKidView", "createdAt", "title", "points", "assigneeIDsRaw",
                   "rotates", "upForGrabs", "repeatRaw", "weekdayMask", "startDate", "requiresApproval", "sortOrder", "priorityRaw",
                   "rotationModeRaw", "rotationPeriodRaw", "rotationWeekday", "rotationAnchor", "rotationAdjustRaw", "rotationSlot",
                   "choreID", "memberID", "day", "date", "statusRaw", "completedAt", "reviewedAt", "location", "notes", "note",
                   "start", "end", "isAllDay", "attendeeIDsRaw", "driverID", "repeatEnd", "bringRaw", "skippedDaysRaw",
                   "alertMinutes", "countsDown", "kindRaw", "refID"],
        "Kitchen": ["content", "updatedAt"],
    ]

    private var container: CKContainer { CKContainer(identifier: Self.containerID) }

    private var location: (database: CKDatabase, zoneID: CKRecordZone.ID) {
        if let owner = householdOwnerName {
            return (container.sharedCloudDatabase, CKRecordZone.ID(zoneName: zoneName, ownerName: owner))
        }
        return (container.privateCloudDatabase, CKRecordZone.ID(zoneName: zoneName))
    }

    /// Fresh enough to answer from without fetching again.
    var isFresh: Bool { lastFetched.map { Date.now.timeIntervalSince($0) < 60 } ?? false }

    // MARK: Reading the whole zone again

    // Fetching only what changed since the last look is fast, but a mirror that once missed or
    // misread a change (a chore approved on the kiosk, chores added on another device) would keep
    // the old copy for good. So every zone is also read whole: once on every device after this
    // generation is raised, and again whenever the last whole read is six hours old. The whole
    // read is built aside and swapped in only when it's complete.

    /// Raised when mirrors may be holding something iCloud no longer has: each device reads every
    /// zone whole on its next fetch. (1: answers about Caloma's chores were days behind the kiosk.)
    static let wholeReadGeneration = 1
    static let wholeReadInterval: TimeInterval = 6 * 60 * 60

    /// When this zone was last read whole, for Profile › iCloud Data.
    private(set) var lastWholeRead: Date? {
        get { UserDefaults.standard.object(forKey: "ember.zone.wholeRead.\(zoneName)") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "ember.zone.wholeRead.\(zoneName)") }
    }

    private var wholeReadDone: Int {
        get { UserDefaults.standard.integer(forKey: "ember.zone.wholeReadGeneration.\(zoneName)") }
        set { UserDefaults.standard.set(newValue, forKey: "ember.zone.wholeReadGeneration.\(zoneName)") }
    }

    private var needsWholeRead: Bool {
        token == nil || wholeReadDone < Self.wholeReadGeneration
            || lastWholeRead.map { Date.now.timeIntervalSince($0) > Self.wholeReadInterval } ?? true
    }

    /// The last fetch worked: what's mirrored is what iCloud has now (as of `lastFetched`).
    var isCurrent: Bool { lastError == nil && lastFetched != nil }

    /// Bumped whenever the mirror changes, so parsed snapshots know when they're stale.
    private var version = 0
    private var snapshots: [ObjectIdentifier: (version: Int, value: any Sendable)] = [:]

    /// The mirror read into an app's model (a ledger, a family board), built off the main thread
    /// and reused until the mirror changes. Reading thousands of sealed fields on the main thread
    /// for every question is what froze the orb while Ember was thinking.
    func snapshot<T: Sendable>(_ make: @escaping @Sendable ([CKRecord]) -> T) async -> T {
        let key = ObjectIdentifier(T.self)
        if let cached = snapshots[key], cached.version == version, let value = cached.value as? T { return value }
        let records = Array(self.records.values)
        let built = version
        let value = await Task.detached(priority: .userInitiated) { make(records) }.value
        if built == version { snapshots[key] = (built, value) }
        return value
    }

    func records(ofType type: String) -> [CKRecord] {
        records.values.filter { $0.recordType == type }
    }

    // MARK: Fetching

    /// Brings the mirror up to date. Concurrent callers share one fetch. Errors are kept in
    /// `lastError`; what was mirrored before stays usable.
    func refresh(force: Bool = false) async {
        while let pending = loading {
            await pending.value
            if loading == pending { loading = nil }
        }
        if !force, isFresh { return }
        if let fetching { return await fetching.value }
        let task = Task { await self.fetchChanges() }
        fetching = task
        await task.value
        fetching = nil
    }

    private func fetchChanges() async {
        let (database, zoneID) = location
        let whole = needsWholeRead
        // A whole read starts from nothing and replaces the mirror only once it's complete.
        var fetched = whole ? [:] : records
        var cursor = whole ? nil : token
        var changed = whole
        var count = 0
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: cursor, desiredKeys: desiredKeys)
                if !changes.modificationResultsByID.isEmpty || !changes.deletions.isEmpty { changed = true }
                for (id, result) in changes.modificationResultsByID {
                    if case .success(let modification) = result {
                        fetched[id.recordName] = modification.record
                        count += 1
                    }
                }
                for deletion in changes.deletions {
                    fetched[deletion.recordID.recordName] = nil
                    count += 1
                }
                cursor = changes.changeToken
                more = changes.moreComing
            }
            if changed { records = fetched }
            token = cursor
            lastFetched = .now
            lastError = nil
            if whole {
                lastWholeRead = .now
                wholeReadDone = Self.wholeReadGeneration
            }
            log.notice("\(self.zoneName, privacy: .public): \(whole ? "read whole" : "changes", privacy: .public), \(count) records, \(self.records.count) mirrored")
            // Records without their values (a mirror saved before Ember kept Suffice's sealed
            // fields, or a fetch that left them out) read as budgets with no names and
            // transactions with no dates: "nothing spent". Fetch the whole zone again, with
            // every field, once.
            // First a clean fetch; if the values are still missing, the field list is what's
            // leaving them out, so every field from then on.
            if repairs < 2, isMissingValues {
                repairs += 1
                log.notice("\(self.zoneName, privacy: .public): records came without their values; fetching everything again (\(self.repairs))")
                if repairs == 2 { fetchesEverything = true }
                forget()
                await fetchChanges()
                return
            }
            // Nothing new: the file already has it (the token moving on alone isn't worth a write).
            if changed { save() }
        } catch let error as CKError where error.code == .changeTokenExpired {
            log.notice("\(self.zoneName, privacy: .public): token expired, fetching everything")
            forget()
            await fetchChanges()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            lastError = .notShared
        } catch let error as CKError where error.code == .notAuthenticated {
            lastError = .noAccount
        } catch {
            log.error("\(self.zoneName, privacy: .public) fetch failed: \(String(describing: error), privacy: .public)")
            lastError = .failed(error.localizedDescription)
        }
    }

    /// Most records carry none of their fields: they can't be read.
    private var isMissingValues: Bool {
        guard records.count >= 3 else { return false }
        let empty = records.values.filter { $0.encryptedValues.allKeys().isEmpty && $0.allKeys().isEmpty }.count
        return empty * 2 > records.count
    }

    /// Throws the mirror away and fetches the whole zone again (Profile › iCloud Data).
    func refetchEverything() async {
        while let pending = loading {
            await pending.value
            if loading == pending { loading = nil }
        }
        forget()
        await refresh(force: true)
    }

    /// Where this mirror reads from, for Profile › iCloud Data.
    var whereLabel: String {
        householdOwnerName == nil ? "Your iCloud" : "Shared with you"
    }

    // MARK: Saving

    /// A new record in this zone, named as the app names them.
    func newRecord(type: String, name: String) -> CKRecord {
        CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: location.zoneID))
    }

    /// Saves records (changed keys only, so another device's edits to other fields stand) and
    /// deletes others. Returns once iCloud has them, and updates the mirror with the server's
    /// copies, so a read right after sees the change.
    @discardableResult
    func save(_ saving: [CKRecord], deleting: [String] = []) async throws -> [CKRecord] {
        let (database, zoneID) = location
        let ids = deleting.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        do {
            let result = try await database.modifyRecords(saving: saving, deleting: ids, savePolicy: .changedKeys, atomically: true)
            var saved: [CKRecord] = []
            for (id, outcome) in result.saveResults {
                let record = try outcome.get()
                records[id.recordName] = record
                saved.append(record)
            }
            for (id, outcome) in result.deleteResults {
                try outcome.get()
                records[id.recordName] = nil
            }
            save()
            return saved
        } catch let error as CKError where error.code == .notAuthenticated {
            throw EmberZoneError.noAccount
        } catch let error as CKError where error.code == .zoneNotFound {
            throw EmberZoneError.notShared
        } catch {
            throw EmberZoneError.failed(error.localizedDescription)
        }
    }

    // MARK: The file

    nonisolated private static func fileURL(for zoneName: String) -> URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Zones", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(zoneName).zone")
    }

    private var fileURL: URL { Self.fileURL(for: zoneName) }

    private func forget() {
        records = [:]
        token = nil
        lastFetched = nil
        lastWholeRead = nil
        writing?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private var writing: Task<Void, Never>?

    /// Writes the mirror off the main thread (archiving thousands of records took long enough to
    /// stall the orb). Records in the mirror are never changed in place (edits copy them), so the
    /// snapshot can be read on another thread.
    private func save() {
        let snapshot = Array(records.values)
        let token = token
        let owner = householdOwnerName, url = fileURL, previous = writing
        writing = Task.detached(priority: .utility) {
            await previous?.value
            if Task.isCancelled { return }
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            archiver.encode(snapshot as NSArray, forKey: "records")
            // A record's encrypted fields aren't kept when the record itself is archived, so
            // they're written alongside it (the whole file is protected).
            archiver.encode(Self.sealedValues(of: snapshot) as NSDictionary, forKey: "sealed")
            if let token { archiver.encode(token, forKey: "token") }
            archiver.encode(owner, forKey: "owner")
            archiver.finishEncoding()
            if Task.isCancelled { return }
            try? archiver.encodedData.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    nonisolated struct Saved: @unchecked Sendable {
        var records: [CKRecord]
        var token: CKServerChangeToken?
        var owner: String?
    }

    nonisolated private static func read(_ url: URL) -> Saved? {
        guard let data = try? Data(contentsOf: url),
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        let records = unarchiver.decodeObject(of: [NSArray.self, CKRecord.self], forKey: "records") as? [CKRecord] ?? []
        let token = unarchiver.decodeObject(of: CKServerChangeToken.self, forKey: "token")
        let owner = unarchiver.decodeObject(of: NSString.self, forKey: "owner") as String?
        let sealed = unarchiver.decodeObject(of: [NSDictionary.self, NSString.self, NSNumber.self, NSDate.self, NSData.self],
                                             forKey: "sealed") as? [String: [String: Any]] ?? [:]
        for record in records {
            guard let values = sealed[record.recordID.recordName], record.encryptedValues.allKeys().isEmpty else { continue }
            for (key, value) in values { record.encryptedValues[key] = value as? CKRecordValue }
        }
        return Saved(records: records, token: token, owner: owner)
    }

    /// Each record's encrypted fields as plain values, by record name.
    nonisolated private static func sealedValues(of records: [CKRecord]) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for record in records {
            var values: [String: Any] = [:]
            for key in record.encryptedValues.allKeys() {
                switch record.encryptedValues[key] {
                case let value as NSString: values[key] = value
                case let value as NSNumber: values[key] = value
                case let value as NSDate: values[key] = value
                case let value as NSData: values[key] = value
                default: break
                }
            }
            if !values.isEmpty { result[record.recordID.recordName] = values }
        }
        return result
    }

    private func adopt(_ saved: Saved?) {
        // Something already fetched, or the household changed while the file was being read.
        guard let saved, records.isEmpty, token == nil, saved.owner == householdOwnerName || householdOwnerName == nil else { return }
        token = saved.token
        householdOwnerName = saved.owner
        records = Dictionary(saved.records.map { ($0.recordID.recordName, $0) }, uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Field helpers

/// Suffice keeps every field in `encryptedValues`; Caloma keeps plain fields. Each reader asks
/// for the one it needs.
extension CKRecord {
    nonisolated func sealedText(_ key: String) -> String? { encryptedValues[key] }
    nonisolated func sealedInt(_ key: String) -> Int? { encryptedValues[key] }
    nonisolated func sealedBool(_ key: String) -> Bool? { encryptedValues[key] }
    nonisolated func sealedDate(_ key: String) -> Date? { encryptedValues[key] }
    nonisolated func sealedDouble(_ key: String) -> Double? { encryptedValues[key] }
    nonisolated func sealedUUID(_ key: String) -> UUID? { sealedText(key).flatMap(UUID.init(uuidString:)) }

    nonisolated func plainText(_ key: String) -> String? { object(forKey: key) as? String }
    nonisolated func plainInt(_ key: String) -> Int? { (object(forKey: key) as? NSNumber)?.intValue }
    nonisolated func plainBool(_ key: String) -> Bool? { (object(forKey: key) as? NSNumber)?.boolValue }
    nonisolated func plainDate(_ key: String) -> Date? { object(forKey: key) as? Date }
    nonisolated func plainUUID(_ key: String) -> UUID? { plainText(key).flatMap(UUID.init(uuidString:)) }
}
