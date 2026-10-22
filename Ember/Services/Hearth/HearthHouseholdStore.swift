// HearthHouseholdStore.swift — keeps the household (`HearthHousehold.swift`) in iCloud and in
// step across the Hearth apps on this device.
//
// Canonical copy: ~/Developer/hearthkit/HearthHouseholdStore.swift (run sync.sh after editing).
//
// - The organizer's household is the zone "Household" in their private database of
//   iCloud.com.stephenwarren.hearth, shared with the family (a zone-wide CKShare). Everyone else
//   syncs it from their shared database. One record per person ("member-<id>") and one for the
//   household ("household"). Birthdays, allergies, diets, likes, dislikes and household rules
//   are encrypted (`encryptedValues`).
// - Every Hearth app runs its own copy of this store with its own CKSyncEngine, and writes what
//   it knows to the app group (`<app>.household.json`). Copies merge person by person, newest
//   change first, so an edit in one app shows in the others at once and every app uploads only
//   its own edits.
// - Without iCloud (signed out), the household still works on this device through the app group.
// - Joining someone's household (an invitation tapped in any Hearth app) switches every app on
//   the device: the others see the shared zone appear and follow.
//
// Each app calls `start(app:)` at launch, passes iCloud invitations for this container to
// `receive(_:)` from its scene delegate, and shows `.hearthHouseholdInvitations()` at its root.

import CloudKit
import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit

@MainActor
@Observable
final class HearthHouseholdStore: NSObject, CKSyncEngineDelegate {
    static let shared = HearthHouseholdStore()
    nonisolated static let containerID = "iCloud.com.stephenwarren.hearth"
    nonisolated static let zoneName = "Household"
    private static let householdRecordName = "household"

    /// Now, to the millisecond: what iCloud keeps, so a record this device saved comes back
    /// from iCloud with exactly the same time.
    nonisolated static var stamp: Date {
        Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    /// `a` is newer than `b` by more than the copies' rounding (app-group copies keep whole
    /// seconds): only then is one copy really later than the other.
    nonisolated static func isNewer(_ a: Date, than b: Date) -> Bool {
        a.timeIntervalSince(b) > 1
    }

    /// Adds the app links `from` has that `into` lacks. Returns whether any were added.
    @discardableResult
    nonisolated static func takeLinks(_ into: inout HearthMember, from other: HearthMember) -> Bool {
        var added = false
        for (app, id) in other.appIDs where into.appIDs[app] == nil {
            into.appIDs[app] = id
            added = true
        }
        return added
    }
    private static let memberPrefix = "member-"

    enum Mode: Equatable {
        /// This account's own household (or none yet), in its private database.
        case owner
        /// Someone else's household this account joined; `ownerName` is their user record.
        case member(ownerName: String)
    }

    enum Account: Equatable {
        case checking, available, noAccount, unavailable
    }

    /// The household as this device knows it: every app's copy merged with iCloud.
    private(set) var snapshot: HearthHouseholdSnapshot = .empty
    private(set) var mode: Mode
    private(set) var account: Account = .checking
    /// The household's share: the organizer's once they've invited someone, or the one a
    /// member joined.
    private(set) var share: CKShare?
    /// This person's iCloud user record name, once known.
    private(set) var myUserID: String?
    /// The person picked as "me" on this device (shared by every Hearth app here). Used
    /// without iCloud, and until the iCloud account is known.
    private(set) var localMeID: String?
    private(set) var isWorking = false
    private(set) var isSyncing = false
    /// iCloud has been asked at least once (or isn't available), so `exists` can be trusted:
    /// a new device doesn't think there's no household before the family's arrives. Per
    /// database: joining or leaving waits for the new one.
    var hasLoaded: Bool {
        account == .unavailable || account == .noAccount || snapshot.exists
            || (isMember ? sharedFetched : privateFetched)
    }
    private var privateFetched = false
    private var sharedFetched = false
    @ObservationIgnored private var fetchFailed = false
    /// iCloud itself has answered for the database this device's household lives in (or there's
    /// no iCloud account at all). Unlike `hasLoaded`, a household already on this device doesn't
    /// count: cleanup that changes everyone's data waits for this.
    var cloudLoaded: Bool {
        account == .noAccount || (isMember ? sharedFetched : privateFetched)
    }
    /// The household's share has been read from iCloud (it may be nil: never shared). Until
    /// then `participants` is unknown, not empty.
    private(set) var shareLoaded = false
    /// The last problem worth showing, in words.
    private(set) var problem: String?
    /// An invitation waiting for a yes (`hearthHouseholdInvitations()`).
    var pendingInvite: CKShare.Metadata?

    @ObservationIgnored private(set) var app: HearthApp = .caloma
    @ObservationIgnored private var started = false
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var privateEngine: CKSyncEngine?
    @ObservationIgnored private var sharedEngine: CKSyncEngine?
    /// An app zone syncing on these engines (BigTable's kitchen).
    @ObservationIgnored private var zoneParticipant: (any HearthZoneParticipant)?
    @ObservationIgnored private var systemFields: [String: Data] = [:]
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var accountRetry: Task<Void, Never>?
    /// A household started before iCloud answered: created once it does, if the family's
    /// household didn't arrive instead.
    @ObservationIgnored private var pendingCreate: (name: String, members: [HearthMember], organizerID: String?, restrictions: [String])?
    @ObservationIgnored private var fieldsSaveTask: Task<Void, Never>?
    @ObservationIgnored private let sharingDelegate = HearthHouseholdSharingDelegate()
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.hearth", category: "household")

    /// Whose household this device's Hearth apps are in (nil: their own). Kept in the app
    /// group, so when one app joins or leaves a household the others follow.
    private static let memberOfKey = "hearth.household.memberOf"
    /// Without iCloud: which person this device belongs to (app group, for every app).
    private static let localMeKey = "hearth.household.me"
    private static let groupDefaults = UserDefaults(suiteName: "group.com.stephenwarren.hearth") ?? .standard

    override init() {
        // Builds before the app group held these kept them per app: move them over once.
        for key in [Self.memberOfKey, Self.localMeKey] where Self.groupDefaults.string(forKey: key) == nil {
            if let value = UserDefaults.standard.string(forKey: key) { Self.groupDefaults.set(value, forKey: key) }
        }
        let owner = Self.groupDefaults.string(forKey: Self.memberOfKey)
        mode = owner.map { .member(ownerName: $0) } ?? .owner
        localMeID = Self.groupDefaults.string(forKey: Self.localMeKey)
        super.init()
    }

    private static var sharedMemberOf: String? { groupDefaults.string(forKey: memberOfKey) }

    private func setMemberOf(_ ownerName: String?) {
        for defaults in [Self.groupDefaults, UserDefaults.standard] {
            if let ownerName { defaults.set(ownerName, forKey: Self.memberOfKey) } else { defaults.removeObject(forKey: Self.memberOfKey) }
        }
    }

    private func setLocalMe(_ id: String?) {
        localMeID = id
        for defaults in [Self.groupDefaults, UserDefaults.standard] {
            if let id { defaults.set(id, forKey: Self.localMeKey) } else { defaults.removeObject(forKey: Self.localMeKey) }
        }
    }

    // MARK: - Reading

    var exists: Bool { snapshot.exists }
    var info: HearthHouseholdInfo? { snapshot.info }
    /// Everyone not archived, in order.
    var people: [HearthMember] { snapshot.people }
    var parents: [HearthMember] { people.filter { $0.role != .kid } }
    var kids: [HearthMember] { people.filter { $0.role == .kid } }
    var isMember: Bool { if case .member = mode { true } else { false } }

    func member(_ id: String?) -> HearthMember? { snapshot.member(id) }
    /// The household person linked to an app's own id for them, in the household or on this
    /// device (see `linkHere`).
    func member(app: HearthApp, appID: String) -> HearthMember? {
        if let linked = snapshot.member(app: app, appID: appID) { return linked }
        guard let personID = Self.localLinks(app).first(where: { $0.value == appID })?.key else { return nil }
        return member(personID)
    }

    /// The person this device belongs to: matched by iCloud account, or picked on this device.
    var me: HearthMember? {
        if let myUserID, let mine = people.first(where: { $0.appleUserID == myUserID }) { return mine }
        return member(localMeID)
    }

    var organizer: HearthMember? { member(info?.organizerID) }

    /// Whether this person can change everyone (a parent, the organizer, or nobody's sharing).
    var canEditEveryone: Bool {
        guard exists else { return true }
        if isMember, share?.currentUserParticipant?.permission == .readOnly { return false }
        guard let me else { return !isMember }
        return me.role == .parent || me.id == info?.organizerID
    }

    /// Whether this person can change `member`: parents anyone, adults themselves.
    func canEdit(_ member: HearthMember) -> Bool {
        if canEditEveryone { return true }
        if isMember, share?.currentUserParticipant?.permission == .readOnly { return false }
        return member.id == me?.id && member.role == .adult
    }

    /// People invited who haven't joined yet, and everyone who has.
    var participants: [CKShare.Participant] {
        share?.participants.filter { $0.role != .owner && $0.acceptanceStatus != .removed } ?? []
    }

    var pendingParticipants: [CKShare.Participant] {
        participants.filter { $0.acceptanceStatus == .pending }
    }

    /// Who shared the household, for a member.
    var ownerName: String? {
        guard isMember, let components = share?.owner.userIdentity.nameComponents else { return nil }
        let name = components.formatted(.name(style: .short))
        return name.isEmpty ? nil : name
    }

    /// The household as an AI request needs it. See `HearthHouseholdSnapshot.aiContext`.
    func aiContext() -> HearthAIContext { snapshot.aiContext() }

    // MARK: - Starting

    /// Call once at launch with the app's identity. Safe to call again.
    func start(app: HearthApp) {
        guard !started else { return }
        started = true
        self.app = app
        snapshot = HearthHouseholdSnapshot.onDevice()
        Hearth.startObservingChanges()
        changeObserver = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HearthHouseholdStore.shared.otherAppChanged() }
        }
        guard Self.isCloudEnabled else {
            account = .unavailable
            return
        }
        let container = CKContainer(identifier: Self.containerID)
        self.container = container
        systemFields = HearthHouseholdFiles.loadFields()
        privateEngine = makeEngine(database: container.privateCloudDatabase, state: HearthHouseholdFiles.loadState(.private))
        sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: HearthHouseholdFiles.loadState(.shared))
        // Another Hearth app may have joined or left a household since this one last ran.
        followOtherApps()
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await HearthHouseholdStore.shared.refreshAccount() } }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HearthHouseholdStore.shared.cameToForeground() }
        }
        Task {
            await refreshAccount()
            await refreshShare()
        }
    }

    /// Off only where the app hasn't got the shared iCloud container yet. Every Hearth app has it.
    static let isCloudEnabled = true

    private func makeEngine(database: CKDatabase, state: CKSyncEngine.State.Serialization?) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: self)
        configuration.automaticallySync = true
        return CKSyncEngine(configuration)
    }

    private var activeEngine: CKSyncEngine? { isMember ? sharedEngine : privateEngine }

    private var zoneID: CKRecordZone.ID {
        switch mode {
        case .owner: CKRecordZone.ID(zoneName: Self.zoneName)
        case .member(let ownerName): CKRecordZone.ID(zoneName: Self.zoneName, ownerName: ownerName)
        }
    }

    func refreshAccount() async {
        guard let container else { return }
        do {
            account = switch try await container.accountStatus() {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .unavailable
            // iCloud is still starting (right after signing in, or on a new device): not an
            // answer. Treating it as "no iCloud" would offer to start a second household.
            default: .checking
            }
        } catch {
            account = .checking
        }
        if account == .available, myUserID == nil {
            myUserID = try? await container.userRecordID().recordName
            if let myUserID { forgetOtherAccountsHousehold(now: myUserID) }
            claimMyRecordIfNeeded()
        }
        if account == .noAccount || account == .unavailable, let pending = pendingCreate {
            // No iCloud after all: the household starts on this device.
            pendingCreate = nil
            if !exists { create(name: pending.name, members: pending.members, organizerID: pending.organizerID, restrictions: pending.restrictions) }
        }
        if account == .checking || (account == .available && myUserID == nil) {
            accountRetry?.cancel()
            accountRetry = Task {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await refreshAccount()
            }
        }
    }

    /// The iCloud account whose household this device holds (app group, for every app). Another
    /// account signing in never gets the previous one's people.
    private static let accountKey = "hearth.household.account"

    private func forgetOtherAccountsHousehold(now userID: String) {
        let previous = Self.groupDefaults.string(forKey: Self.accountKey)
        Self.groupDefaults.set(userID, forKey: Self.accountKey)
        guard let previous, previous != userID, exists else { return }
        log.notice("A different iCloud account: this device's household belonged to the last one")
        snapshot = HearthHouseholdSnapshot(info: nil, members: [], adoptedAt: .now)
        publish()
        setMemberOf(nil)
        setLocalMe(nil)
        mode = .owner
        share = nil
        systemFields = [:]
        HearthHouseholdFiles.removeAll()
        if let container {
            privateEngine = makeEngine(database: container.privateCloudDatabase, state: nil)
            sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: nil)
            privateFetched = false
            sharedFetched = false
            shareLoaded = false
            zoneParticipant?.zoneAccountDidChange()
            zoneParticipant?.zoneEngineReset(isShared: false)
            zoneParticipant?.zoneEngineReset(isShared: true)
        }
    }

    /// Back in the foreground: take in what other Hearth apps changed meanwhile (their
    /// notification may have come while this app was suspended), and ask iCloud again if it
    /// wasn't ready.
    private func cameToForeground() {
        otherAppChanged()
        if account != .available || myUserID == nil { Task { await refreshAccount() } }
        Task { await refresh() }
    }

    /// The latest of every Hearth app's copy on this device, before changing anything, so a
    /// change never goes out on top of an older copy.
    private func catchUpWithOtherApps() {
        let merged = HearthHouseholdSnapshot.merged([snapshot] + Hearth.readAll(HearthHouseholdSnapshot.self).map(\.value))
        if merged != snapshot, merged.info?.id == snapshot.info?.id { snapshot = merged }
    }

    /// Sends what's waiting and fetches the latest. For pull to refresh; never throws.
    func refresh() async {
        guard let engine = activeEngine, account == .available else { return }
        do { try await engine.sendChanges() } catch { note(error) }
        do { try await engine.fetchChanges(.init(scope: .zoneIDs(fetchZones(isShared: isMember)))) } catch { note(error) }
    }

    /// Another Hearth app on this device saved its copy: take in what's newer.
    private func otherAppChanged() {
        followOtherApps()
        let groupMe = Self.groupDefaults.string(forKey: Self.localMeKey)
        if groupMe != localMeID { localMeID = groupMe }
        let merged = HearthHouseholdSnapshot.merged([snapshot] + Hearth.readAll(HearthHouseholdSnapshot.self).map(\.value))
        guard merged != snapshot else { return }
        let joinedElsewhere = merged.info?.id != snapshot.info?.id
        snapshot = merged
        if joinedElsewhere { Task { await refreshShare() } }
    }

    /// Joins or leaves with the other Hearth apps: when another app on this device joined a
    /// household (or left one), this app's sync moves to the same place, keeping the people
    /// the app group already has. Without it, this app would upload one household's people
    /// into another's zone.
    private func followOtherApps() {
        let shared = Self.sharedMemberOf
        let current: String? = if case .member(let ownerName) = mode { ownerName } else { nil }
        guard shared != current, let container else { return }
        log.notice("Following another Hearth app to a different household")
        UserDefaults.standard.set(shared, forKey: Self.memberOfKey)
        mode = shared.map { .member(ownerName: $0) } ?? .owner
        share = nil
        systemFields = [:]
        HearthHouseholdFiles.saveFields(systemFields)
        if shared == nil {
            HearthHouseholdFiles.saveState(nil, .private)
            privateEngine = makeEngine(database: container.privateCloudDatabase, state: nil)
        } else {
            HearthHouseholdFiles.saveState(nil, .shared)
            sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: nil)
        }
        if shared == nil { privateFetched = false } else { sharedFetched = false }
        shareLoaded = false
        zoneParticipant?.zoneEngineReset(isShared: shared != nil)
        Task {
            try? await activeEngine?.fetchChanges()
            await refreshShare()
        }
    }

    // MARK: - An app's own zone

    /// Lets an app sync a zone of its own on the household's engines (an app never runs two
    /// engines on one database). BigTable's kitchen uses it. Call before `start(app:)`.
    func register(_ participant: any HearthZoneParticipant) {
        zoneParticipant = participant
    }

    /// The Hearth iCloud container, once started.
    var cloudContainer: CKContainer? { container }

    /// Queues the participant's changes on the engine for its zone's database.
    func queueZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange], isShared: Bool) {
        guard !changes.isEmpty, let engine = isShared ? sharedEngine : privateEngine else { return }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    /// Makes sure a zone of the participant's exists in this account's private database.
    func ensurePrivateZone(_ zoneID: CKRecordZone.ID) {
        privateEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    /// Sends and fetches the participant's database now (pull to refresh).
    func syncZoneNow(isShared: Bool) async {
        guard let engine = isShared ? sharedEngine : privateEngine, account == .available else { return }
        do { try await engine.sendChanges() } catch { note(error) }
        do { try await engine.fetchChanges(.init(scope: .zoneIDs(fetchZones(isShared: isShared)))) } catch { note(error) }
    }

    // MARK: - Changing

    /// Creates the household (first-time setup): its name and its people. The person creating it
    /// is its organizer; on this device they're `me`.
    func create(name: String, members: [HearthMember], organizerID: String?, restrictions: [String] = []) {
        // Never over a household this account joined (its record is the family's).
        guard !isMember else { return }
        // Never before iCloud has said whether the family's household is already there: two
        // households in one account overwrite each other. It's created once iCloud answers.
        if Self.isCloudEnabled, container != nil, account != .noAccount, account != .unavailable, !privateFetched {
            pendingCreate = (name, members, organizerID, restrictions)
            log.notice("Household setup waits for iCloud")
            return
        }
        pendingCreate = nil
        let now = Self.stamp
        var people = members
        for index in people.indices {
            people[index].sortOrder = index
            people[index].updatedAt = now
            if people[index].id == organizerID, let myUserID { people[index].appleUserID = myUserID }
        }
        let info = HearthHouseholdInfo(name: name, restrictions: restrictions, organizerID: organizerID, updatedAt: now)
        snapshot = HearthHouseholdSnapshot(info: info, members: people, adoptedAt: now)
        if let organizerID, myUserID == nil { setLocalMe(organizerID) }
        publish()
        if !isMember, let privateEngine {
            privateEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        queueSaves([Self.householdRecordName] + people.map { Self.memberPrefix + $0.id })
    }

    /// Saves a new or changed person.
    func save(_ member: HearthMember) {
        catchUpWithOtherApps()
        var updated = member
        // Links other apps made meanwhile stay (the copy being saved may predate them).
        if let latest = snapshot.members.first(where: { $0.id == member.id }) {
            for (app, id) in latest.appIDs where updated.appIDs[app] == nil { updated.appIDs[app] = id }
        }
        updated.updatedAt = Self.stamp
        if let index = snapshot.members.firstIndex(where: { $0.id == member.id }) {
            guard !snapshot.members[index].sameContent(as: updated) else { return }
            snapshot.members[index] = updated
        } else {
            updated.sortOrder = (snapshot.members.map(\.sortOrder).max() ?? -1) + 1
            snapshot.members.append(updated)
        }
        snapshot.deleted[member.id] = nil
        publish()
        queueSaves([Self.memberPrefix + member.id])
    }

    // MARK: Photos (one per person, everywhere)

    /// Someone's photo, the one every Hearth app and device shows for them.
    func photo(for memberID: String?) -> Data? {
        member(memberID)?.photo.flatMap(Hearth.photo(named:))
    }

    /// They chose a new photo (or removed it, with nil): it replaces the old one on every
    /// device and in every app. Returns false when this person can't be changed here.
    @discardableResult
    func setPhoto(_ data: Data?, for memberID: String) -> Bool {
        catchUpWithOtherApps()
        guard var person = member(memberID), canEdit(person) else { return false }
        if let data {
            guard let name = HearthHouseholdPhotos.save(data, memberID: memberID) else { return false }
            person.photo = name
        } else {
            person.photo = nil
        }
        save(person)
        return true
    }

    /// A photo an app already had for someone (an older profile photo, from before photos
    /// lived in the household). Used only when they have none here yet: the first photo
    /// someone gave stays theirs until they choose a new one. Returns true when it was used.
    @discardableResult
    func adoptPhoto(_ data: Data, for memberID: String) -> Bool {
        guard cloudLoaded, let person = member(memberID), person.photo == nil else { return false }
        return setPhoto(data, for: memberID)
    }

    /// Hides someone everywhere; their history stays in each app.
    func archive(_ id: String, archived: Bool = true) {
        catchUpWithOtherApps()
        guard var member = member(id) else { return }
        member.isArchived = archived
        save(member)
    }

    /// Removes someone for good: their details, photo and every app's link to them. Their
    /// iCloud record stays as a marker ("deleted at"), so every device and app learns of the
    /// deletion as ordinary data, and a copy that missed it can't bring them back.
    func delete(_ id: String) {
        catchUpWithOtherApps()
        snapshot.members.removeAll { $0.id == id }
        snapshot.deleted[id] = Self.stamp
        publish()
        queueSaves([Self.memberPrefix + id])
    }

    /// Folds people who are plainly the same person into one: the same full name, both kids or
    /// both grown-ups, and no two different birthdays or Apple Accounts. The one kept is the
    /// organizer, then whoever has joined with their own Apple Account, then the fullest record;
    /// ties go to the lower id, so every device picks the same one. It takes the others'
    /// birthday, photo, food and app links, and becomes "me" here if one of them was. Only for
    /// someone who can change everyone. Returns how many were folded in.
    @discardableResult
    func mergeDuplicates() -> Int {
        // Only once iCloud has answered, and ranked on what every device knows the same way,
        // so every device and app picks the same person to keep.
        guard exists, cloudLoaded, canEditEveryone else { return 0 }
        let groups = Dictionary(grouping: snapshot.members.filter { !$0.isArchived && !$0.trimmedName.isEmpty }) {
            HearthNames.normalized($0.name) + ($0.role == .kid ? "|kid" : "|adult")
        }
        var folded = 0
        for group in groups.values where group.count > 1 {
            guard Set(group.compactMap(\.birthday)).count <= 1,
                  Set(group.compactMap(\.appleUserID)).count <= 1 else { continue }
            let ordered = group.sorted { lhs, rhs in
                let a = mergeRank(lhs), b = mergeRank(rhs)
                return a != b ? a > b : lhs.id < rhs.id
            }
            var keep = ordered[0]
            for other in ordered.dropFirst() { keep = Self.fold(other, into: keep) }
            // The kept person first (with any photo taken from the others), then the others go.
            save(keep)
            for other in ordered.dropFirst() {
                if snapshot.info?.organizerID == other.id {
                    snapshot.info?.organizerID = keep.id
                    snapshot.info?.updatedAt = Self.stamp
                    queueSaves([Self.householdRecordName])
                }
                if localMeID == other.id { setLocalMe(keep.id) }
                delete(other.id)
                folded += 1
            }
        }
        if folded > 0 { log.notice("Folded \(folded) duplicate people") }
        return folded
    }

    private func mergeRank(_ member: HearthMember) -> Int {
        var rank = 0
        if member.id == info?.organizerID { rank += 100 }
        if member.appleUserID != nil { rank += 50 }
        if member.birthday != nil { rank += 4 }
        // Not the photo: a device may not have downloaded it yet, and every device must agree.
        rank += member.appIDs.count
        rank += min(member.allergies.count + member.diet.count + member.likes.count + member.dislikes.count, 3)
        return rank
    }

    private static func fold(_ other: HearthMember, into keep: HearthMember) -> HearthMember {
        func union(_ a: [String], _ b: [String]) -> [String] {
            var seen = Set(a.map { $0.lowercased() })
            return a + b.filter { seen.insert($0.lowercased()).inserted }
        }
        var merged = keep
        merged.birthday = keep.birthday ?? other.birthday
        merged.photo = keep.photo ?? other.photo
        merged.appleUserID = keep.appleUserID ?? other.appleUserID
        merged.allergies = union(keep.allergies, other.allergies)
        merged.diet = union(keep.diet, other.diet)
        merged.likes = union(keep.likes, other.likes)
        merged.dislikes = union(keep.dislikes, other.dislikes)
        for (app, id) in other.appIDs where merged.appIDs[app] == nil { merged.appIDs[app] = id }
        if keep.role == .adult && other.role == .parent { merged.role = .parent }
        if keep.trimmedName.count < other.trimmedName.count { merged.name = other.trimmedName }
        merged.sortOrder = min(keep.sortOrder, other.sortOrder)
        return merged
    }

    /// Records the id an app uses for someone, so the app can find them again.
    func link(_ memberID: String, app: HearthApp, appID: String) {
        catchUpWithOtherApps()
        guard var member = member(memberID), member.appIDs[app.rawValue] != appID else { return }
        member.appIDs[app.rawValue] = appID
        save(member)
    }

    // MARK: Links on this device

    // An app's data may be shared by the whole family (Caloma's family, a shared Suffice budget)
    // or kept per person (two separate budgets). The household's `appIDs` holds the shared
    // link; a phone whose app has its own copy of someone keeps its link here instead, so two
    // phones never take turns overwriting it.

    /// `person`'s id in `app` on this device, among the ids the app has here.
    func localID(of person: HearthMember, app: HearthApp, among ids: Set<String>) -> String? {
        if let id = person.appID(app), ids.contains(id) { return id }
        if let id = Self.localLinks(app)[person.id], ids.contains(id) { return id }
        return nil
    }

    /// Links `person` to the app's id for them: in the household when nobody's linked yet,
    /// otherwise on this device only.
    func linkHere(_ person: HearthMember, app: HearthApp, localID: String) {
        var links = Self.localLinks(app)
        if person.appID(app) == nil {
            link(person.id, app: app, appID: localID)
            links[person.id] = nil
        } else if person.appID(app) != localID {
            links[person.id] = localID
        } else {
            links[person.id] = nil
        }
        UserDefaults.standard.set(links, forKey: Self.localLinksKey(app))
    }

    /// Whether the app's id `localID` belongs to someone in the household, on this device.
    func isLinked(app: HearthApp, localID: String) -> Bool {
        member(app: app, appID: localID) != nil
    }

    private static func localLinksKey(_ app: HearthApp) -> String { "hearth.household.links.\(app.rawValue)" }

    private static func localLinks(_ app: HearthApp) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: localLinksKey(app)) as? [String: String] ?? [:]
    }

    /// `clearAppShares` blanks every app's share link (Stop Sharing). Blank, not removed: links
    /// merge per key, so a removed one would come back from another app's copy.
    func updateInfo(name: String? = nil, restrictions: [String]? = nil, joinCode: String? = nil, appShare: (app: HearthApp, url: String)? = nil, clearAppShares: Bool = false, mealTimes: HearthMealTimes? = nil) {
        catchUpWithOtherApps()
        guard var info = snapshot.info else { return }
        if let name { info.name = name }
        if let mealTimes, mealTimes != info.mealTimes {
            info.mealTimes = mealTimes
            info.mealTimesAt = Self.stamp
        }
        if let restrictions { info.restrictions = restrictions }
        if let joinCode { info.joinCode = joinCode }
        if clearAppShares {
            for key in info.appShareURLs.keys { info.appShareURLs[key] = "" }
        }
        if let appShare { info.appShareURLs[appShare.app.rawValue] = appShare.url }
        guard info != snapshot.info else { return }
        info.updatedAt = Self.stamp
        snapshot.info = info
        publish()
        queueSaves([Self.householdRecordName])
    }

    /// Puts people in this order.
    func reorder(_ ids: [String]) {
        var changed: [String] = []
        for (index, id) in ids.enumerated() {
            guard let at = snapshot.members.firstIndex(where: { $0.id == id }), snapshot.members[at].sortOrder != index else { continue }
            snapshot.members[at].sortOrder = index
            snapshot.members[at].updatedAt = Self.stamp
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        snapshot.members.sort { $0.sortOrder < $1.sortOrder }
        publish()
        queueSaves(changed.map { Self.memberPrefix + $0 })
    }

    /// "This is me": marks someone as the person on this device (and in this iCloud account).
    func claim(_ memberID: String) {
        setLocalMe(memberID)
        guard let myUserID else { return }
        for other in snapshot.members where other.appleUserID == myUserID && other.id != memberID && canEdit(other) {
            var cleared = other
            cleared.appleUserID = nil
            save(cleared)
        }
        // Kids (view only) can't write it; the pick on this device is enough for them.
        guard var member = member(memberID), member.appleUserID != myUserID, canEdit(member) else { return }
        member.appleUserID = myUserID
        save(member)
    }

    /// People (and the household itself) this device has that iCloud doesn't: another Hearth app
    /// on this device added them before it could reach iCloud, or an upload never went through.
    /// Each app uploads only its own edits, so without this they'd stay on this one device and
    /// every other device would see fewer people. Runs after each fetch from the household's
    /// zone; a record iCloud already has is known by its cached system fields. A record that's
    /// there but not cached here just comes back as a conflict, and the newer copy wins.
    private func uploadWhatICloudLacks(isPrivate: Bool) {
        // Only after a fetch that finished, so the account works and the cache is current.
        guard isPrivate != isMember, exists, let engine = activeEngine else { return }
        var missing: [String] = []
        if !isMember, snapshot.info != nil, systemFields[Self.householdRecordName] == nil {
            missing.append(Self.householdRecordName)
        }
        for person in snapshot.members where systemFields[Self.memberPrefix + person.id] == nil && canEdit(person) {
            missing.append(Self.memberPrefix + person.id)
        }
        let pending = pendingSaves()
        missing.removeAll { pending.contains($0) }
        guard !missing.isEmpty else { return }
        log.notice("Uploading \(missing.count) household records iCloud doesn't have yet")
        if !isMember {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        queueSaves(missing)
    }

    /// Once the iCloud account is known: the person picked on this device gets it. Someone who
    /// joined with an invitation made for one person is that person, with nothing to pick.
    private func claimMyRecordIfNeeded() {
        guard exists, let myUserID, !people.contains(where: { $0.appleUserID == myUserID }) else { return }
        if let local = localMeID, member(local) != nil {
            claim(local)
        } else if let invited = invitedMember() {
            log.notice("Joined as the person the invitation was for")
            claim(invited.id)
        }
    }

    private func publish() {
        Hearth.publish(snapshot, from: app)
        if snapshot.exists {
            // Photos any Hearth app here still uses stay (another app may have just saved one).
            let everyCopy = [snapshot] + Hearth.readAll(HearthHouseholdSnapshot.self).map(\.value)
            HearthHouseholdPhotos.clean(keeping: Set(everyCopy.flatMap { $0.members.compactMap(\.photo) }))
        }
    }

    private func queueSaves(_ recordNames: [String]) {
        guard let engine = activeEngine, exists else { return }
        engine.state.add(pendingRecordZoneChanges: recordNames.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === privateEngine || syncEngine === sharedEngine else { return }
        let isPrivate = syncEngine === privateEngine
        switch event {
        case .stateUpdate(let update):
            HearthHouseholdFiles.saveState(update.stateSerialization, isPrivate ? .private : .shared)
        case .accountChange(let change):
            if isPrivate { handleAccountChange(change) }
        case .fetchedDatabaseChanges(let changes):
            handleDatabaseChanges(changes, isPrivate: isPrivate)
        case .fetchedRecordZoneChanges(let changes):
            handleZoneChanges(changes, isPrivate: isPrivate)
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine, isPrivate: isPrivate)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves { note(failure.error) }
        case .willFetchChanges:
            isSyncing = true
            fetchFailed = false
        case .willSendChanges:
            isSyncing = true
        case .didFetchRecordZoneChanges(let fetched):
            // A household zone that doesn't exist yet is an answer ("none"); anything else isn't.
            if fetched.zoneID.zoneName == Self.zoneName, let error = fetched.error, error.code != .zoneNotFound {
                fetchFailed = true
                note(error)
            }
        case .didFetchChanges:
            isSyncing = false
            guard !fetchFailed else { break }
            if isPrivate { privateFetched = true } else { sharedFetched = true }
            if isPrivate, let pending = pendingCreate {
                pendingCreate = nil
                if !exists { create(name: pending.name, members: pending.members, organizerID: pending.organizerID, restrictions: pending.restrictions) }
            }
            uploadWhatICloudLacks(isPrivate: isPrivate)
            mergeDuplicates()
        case .didSendChanges:
            isSyncing = false
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await HearthHouseholdStore.shared.record(for: recordID, engine: syncEngine)
        }
    }

    /// Only the zones this app uses: the household's, and its own app zone. Other apps never
    /// download BigTable's recipes.
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs(fetchZones(isShared: syncEngine === sharedEngine))
        return options
    }

    private func fetchZones(isShared: Bool) -> [CKRecordZone.ID] {
        var zones: [CKRecordZone.ID] = isShared == isMember ? [zoneID] : []
        if let location = zoneParticipant?.zoneLocation, location.isShared == isShared { zones.append(location.zoneID) }
        return zones
    }

    /// The participant's zone, when it's in this engine's database.
    private func participantZone(isShared: Bool) -> CKRecordZone.ID? {
        guard let location = zoneParticipant?.zoneLocation, location.isShared == isShared else { return nil }
        return location.zoneID
    }

    /// The record to upload, built from the household as it is now.
    private func record(for recordID: CKRecord.ID, engine: CKSyncEngine) -> CKRecord? {
        if let zone = participantZone(isShared: engine === sharedEngine), recordID.zoneID == zone {
            guard let record = zoneParticipant?.zoneRecord(for: recordID) else {
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return record
        }
        let name = recordID.recordName
        let record: CKRecord
        if name == Self.householdRecordName, let info = snapshot.info {
            record = cachedRecord(recordID) ?? CKRecord(recordType: "Household", recordID: recordID)
            HearthHouseholdRecords.write(info, to: record)
        } else if name.hasPrefix(Self.memberPrefix), let member = member(String(name.dropFirst(Self.memberPrefix.count))) {
            record = cachedRecord(recordID) ?? CKRecord(recordType: "HouseholdMember", recordID: recordID)
            HearthHouseholdRecords.write(member, to: record)
        } else if name.hasPrefix(Self.memberPrefix), let deletedAt = snapshot.deleted[String(name.dropFirst(Self.memberPrefix.count))] {
            record = cachedRecord(recordID) ?? CKRecord(recordType: "HouseholdMember", recordID: recordID)
            HearthHouseholdRecords.writeDeleted(at: deletedAt, to: record)
        } else {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        return record
    }

    private func handleZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, isPrivate: Bool) {
        if let zone = participantZone(isShared: !isPrivate) {
            let modifications = changes.modifications.map(\.record).filter { $0.recordID.zoneID == zone }
            let deletions = changes.deletions.filter { $0.recordID.zoneID == zone }
            if !modifications.isEmpty || !deletions.isEmpty {
                zoneParticipant?.zoneFetched(modifications: modifications, deletions: deletions)
            }
        }
        guard isPrivate != isMember else { return }
        let zone = zoneID
        let modifications = changes.modifications.map(\.record).filter { $0.recordID.zoneID == zone }
        let deletions = changes.deletions.filter { $0.recordID.zoneID == zone }
        guard !modifications.isEmpty || !deletions.isEmpty else { return }

        var next = snapshot
        let pending = pendingSaves()
        /// This device's copy is newer than iCloud's and isn't on its way: send it (an upload
        /// that was lost when an engine started over, or never made).
        var resend: [String] = []
        var switchedHousehold = false
        for record in modifications {
            cache(record)
            let name = record.recordID.recordName
            if record.recordType == "Household" {
                let info = HearthHouseholdRecords.info(from: record)
                if next.info?.id != info.id {
                    // The household in iCloud is the family's: it replaces whatever this device had.
                    switchedHousehold = next.info != nil
                    next.adoptedAt = .now
                    next.info = info
                } else if let mine = next.info {
                    // The newer one's details, and every app's share link from either.
                    let theirsNewer = info.updatedAt > mine.updatedAt
                    var merged = theirsNewer ? info : mine
                    let other = theirsNewer ? mine : info
                    for (app, url) in other.appShareURLs where merged.appShareURLs[app] == nil { merged.appShareURLs[app] = url }
                    merged.keepNewerMealTimes(from: other)
                    next.info = merged
                    let iCloudLacks = merged.appShareURLs != info.appShareURLs || merged.mealTimes != info.mealTimes
                        || Self.isNewer(mine.updatedAt, than: info.updatedAt)
                    if iCloudLacks, !isMember, !pending.contains(name) { resend.append(name) }
                }
            } else if record.recordType == "HouseholdMember", let deletedAt = HearthHouseholdRecords.deletedAt(record) {
                let id = String(name.dropFirst(Self.memberPrefix.count))
                if let index = next.members.firstIndex(where: { $0.id == id }) {
                    if next.members[index].updatedAt < deletedAt {
                        next.members.remove(at: index)
                    } else if Self.isNewer(next.members[index].updatedAt, than: deletedAt), !pending.contains(name), canEdit(next.members[index]) {
                        // Someone saved them after the deletion: they stay, and iCloud hears so.
                        resend.append(name)
                    }
                }
                if deletedAt > (next.deleted[id] ?? .distantPast) { next.deleted[id] = deletedAt }
            } else if record.recordType == "HouseholdMember", var incoming = HearthHouseholdRecords.member(from: record, existing: next.members) {
                if let index = next.members.firstIndex(where: { $0.id == incoming.id }) {
                    var mine = next.members[index]
                    if incoming.updatedAt > mine.updatedAt {
                        // Theirs is newer; links this device made that iCloud lacks stay.
                        let keptLinks = Self.takeLinks(&incoming, from: mine)
                        next.members[index] = incoming
                        if keptLinks, canEdit(incoming), !pending.contains(name) { resend.append(name) }
                    } else {
                        // This device's is as new or newer: it takes iCloud's extra links, and
                        // goes back up when it has something iCloud lacks.
                        if Self.takeLinks(&mine, from: incoming) { next.members[index] = mine }
                        let iCloudLacks = Self.isNewer(mine.updatedAt, than: incoming.updatedAt)
                            || mine.appIDs.keys.contains { incoming.appIDs[$0] == nil }
                        if iCloudLacks, !pending.contains(name), canEdit(mine) { resend.append(name) }
                    }
                } else if let deletedAt = next.deleted[incoming.id] {
                    if incoming.updatedAt > deletedAt {
                        next.members.append(incoming)
                    } else if Self.isNewer(deletedAt, than: incoming.updatedAt), !pending.contains(name), canEditEveryone {
                        // This device deleted them but iCloud never heard: send the deletion again.
                        resend.append(name)
                    }
                } else {
                    next.members.append(incoming)
                }
            }
        }
        if switchedHousehold {
            // People from the household this device had before aren't the family's: only those
            // iCloud has stay (the rest of the family's arrive with this fetch).
            let before = next.members.count
            next.members.removeAll { systemFields[Self.memberPrefix + $0.id] == nil }
            log.notice("Switched to the household in iCloud; set aside \(before - next.members.count) people from this device's")
        }
        for deletion in deletions {
            systemFields[deletion.recordID.recordName] = nil
            let name = deletion.recordID.recordName
            if name.hasPrefix(Self.memberPrefix) {
                let id = String(name.dropFirst(Self.memberPrefix.count))
                next.members.removeAll { $0.id == id }
                next.deleted[id] = .now
            }
        }
        next.members.sort { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        next.isShared = isMember || share != nil
        if next != snapshot {
            snapshot = next
            publish()
            claimMyRecordIfNeeded()
            mergeDuplicates()
        }
        if !resend.isEmpty { queueSaves(resend) }
        scheduleFieldsSave()
    }

    /// Record names with a save on its way for the household's zone.
    private func pendingSaves() -> Set<String> {
        guard let engine = activeEngine else { return [] }
        let zone = zoneID
        return Set(engine.state.pendingRecordZoneChanges.compactMap { change -> String? in
            if case .saveRecord(let id) = change, id.zoneID == zone { return id.recordName }
            return nil
        })
    }

    private func handleDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges, isPrivate: Bool) {
        if let participant = zoneParticipant {
            let added = changes.modifications.map(\.zoneID).filter { $0.zoneName == participant.zoneName }
            let deleted = changes.deletions.filter { $0.zoneID.zoneName == participant.zoneName }
            if !added.isEmpty || !deleted.isEmpty {
                participant.zoneDatabaseChanged(added: added, deleted: deleted, isShared: !isPrivate)
            }
        }
        if isPrivate {
            for deletion in changes.deletions where deletion.zoneID.zoneName == Self.zoneName && !isMember {
                systemFields = [:]
                HearthHouseholdFiles.saveFields(systemFields)
                share = nil
                if deletion.reason == .purged {
                    // They deleted this app's iCloud data in Settings: it goes here too.
                    log.notice("The household's iCloud data was deleted")
                    snapshot = HearthHouseholdSnapshot(info: nil, members: [], adoptedAt: .now)
                    publish()
                } else if exists {
                    // The iCloud keys were reset, or the zone went missing: put back what's on
                    // this device (no Hearth app deletes the household's zone).
                    privateEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    queueSaves([Self.householdRecordName] + snapshot.members.map { Self.memberPrefix + $0.id })
                }
            }
            return
        }
        for deletion in changes.deletions where deletion.zoneID == zoneID && isMember {
            log.notice("The household was stopped or left")
            returnToOwnHousehold()
        }
        if !isMember, let joined = changes.modifications.first(where: { $0.zoneID.zoneName == Self.zoneName }) {
            // Joined in another app or on another device.
            becomeMember(ownerName: joined.zoneID.ownerName)
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine, isPrivate: Bool) {
        let appZone = participantZone(isShared: !isPrivate)
        if let appZone, let participant = zoneParticipant {
            let retries = participant.zoneSent(
                saved: sent.savedRecords.filter { $0.recordID.zoneID == appZone },
                deleted: sent.deletedRecordIDs.filter { $0.zoneID == appZone },
                failedSaves: sent.failedRecordSaves.filter { $0.record.recordID.zoneID == appZone },
                isShared: !isPrivate
            )
            if !retries.isEmpty { engine.state.add(pendingRecordZoneChanges: retries) }
        }
        for record in sent.savedRecords where record.recordID.zoneID != appZone { cache(record) }
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves where failure.record.recordID.zoneID != appZone {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone saved first. Theirs is newer only if its own clock says so.
                if let server = failure.error.serverRecord {
                    cache(server)
                    if resolveConflict(server) { continue }
                }
                retry.append(.saveRecord(recordID))
            case .zoneNotFound:
                if isPrivate {
                    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
                    systemFields[recordID.recordName] = nil
                    retry.append(.saveRecord(recordID))
                } else {
                    returnToOwnHousehold()
                    return
                }
            case .unknownItem:
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .batchRequestFailed:
                retry.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .notAuthenticated, .operationCancelled, .accountTemporarilyUnavailable:
                break
            case .permissionFailure:
                // Not this person's to change (a read-only member): iCloud's copy stands.
                note(failure.error)
            default:
                // Anything else (quota, a photo that went missing): tried again in a minute,
                // never silently dropped.
                note(failure.error)
                retryLater(recordID, engine: engine)
            }
        }
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry) }
        if sent.failedRecordSaves.isEmpty { problem = nil }
        scheduleFieldsSave()
    }

    private func retryLater(_ recordID: CKRecord.ID, engine: CKSyncEngine) {
        Task { [weak engine] in
            try? await Task.sleep(for: .seconds(60))
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        }
    }

    /// A save lost to a newer copy in iCloud: takes theirs when its clock is later than this
    /// device's (a person, a deleted person, or the household). Returns true when theirs won and
    /// nothing should be retried; false to save this device's copy over it.
    private func resolveConflict(_ server: CKRecord) -> Bool {
        let name = server.recordID.recordName
        if server.recordType == "Household" {
            let theirs = HearthHouseholdRecords.info(from: server)
            guard let mine = snapshot.info else { return false }
            if mine.id != theirs.id {
                // iCloud already holds this account's household: it's the family's; this
                // device's newer one never replaces it.
                log.notice("Joined the household already in iCloud instead of starting another")
                snapshot.info = theirs
                snapshot.adoptedAt = .now
                // This device's people were for its own household: those iCloud lacks never go up.
                let strays = snapshot.members.filter { systemFields[Self.memberPrefix + $0.id] == nil }.map(\.id)
                snapshot.members.removeAll { strays.contains($0.id) }
                if let engine = activeEngine {
                    engine.state.remove(pendingRecordZoneChanges: strays.map { .saveRecord(CKRecord.ID(recordName: Self.memberPrefix + $0, zoneID: zoneID)) })
                }
                publish()
                return true
            }
            guard theirs.updatedAt > mine.updatedAt else { return false }
            var merged = theirs
            for (app, url) in mine.appShareURLs where merged.appShareURLs[app] == nil { merged.appShareURLs[app] = url }
            merged.keepNewerMealTimes(from: mine)
            snapshot.info = merged
            publish()
            if merged != theirs { queueSaves([Self.householdRecordName]) }
            return true
        }
        guard server.recordType == "HouseholdMember", name.hasPrefix(Self.memberPrefix) else { return false }
        let id = String(name.dropFirst(Self.memberPrefix.count))
        let mineDate = member(id)?.updatedAt ?? snapshot.deleted[id] ?? .distantPast
        if let deletedAt = HearthHouseholdRecords.deletedAt(server) {
            guard deletedAt > mineDate else { return false }
            snapshot.members.removeAll { $0.id == id }
            snapshot.deleted[id] = deletedAt
            publish()
            return true
        }
        guard var theirs = HearthHouseholdRecords.member(from: server, existing: snapshot.members) else { return false }
        guard theirs.updatedAt > mineDate else {
            // Mine goes up, with iCloud's links added.
            if let index = snapshot.members.firstIndex(where: { $0.id == id }),
               Self.takeLinks(&snapshot.members[index], from: theirs) { publish() }
            return false
        }
        if let index = snapshot.members.firstIndex(where: { $0.id == id }) {
            let keptLinks = Self.takeLinks(&theirs, from: snapshot.members[index])
            snapshot.members[index] = theirs
            publish()
            // Theirs wins, but links only this device had go back up.
            return !keptLinks
        } else {
            snapshot.members.append(theirs)
            snapshot.deleted[id] = nil
        }
        publish()
        return true
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            Task { await refreshAccount() }
        case .signOut, .switchAccounts:
            // Someone else's household never stays on a device after its account leaves, and a
            // different account never gets this one's people.
            let switched: Bool = if case .switchAccounts = change.changeType { true } else { false }
            if isMember || switched {
                snapshot = HearthHouseholdSnapshot(info: nil, members: [], adoptedAt: .now)
                publish()
            }
            setMemberOf(nil)
            setLocalMe(nil)
            mode = .owner
            share = nil
            myUserID = nil
            systemFields = [:]
            HearthHouseholdFiles.removeAll()
            zoneParticipant?.zoneAccountDidChange()
            if let container {
                privateEngine = makeEngine(database: container.privateCloudDatabase, state: nil)
                sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: nil)
                privateFetched = false
                sharedFetched = false
                shareLoaded = false
                zoneParticipant?.zoneEngineReset(isShared: false)
                zoneParticipant?.zoneEngineReset(isShared: true)
            }
            Task { await refreshAccount() }
        @unknown default:
            break
        }
    }

    // MARK: - Sharing (organizer)

    private func prepareShare() async throws -> CKShare {
        if let share { return share }
        guard let container else { throw CKError(.notAuthenticated) }
        let database = container.privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let newShare = CKShare(recordZoneID: zoneID)
        newShare[CKShare.SystemFieldKey.title] = (info?.name ?? "Hearth Household") as CKRecordValue
        newShare.publicPermission = .none
        let result = try await database.modifyRecords(saving: [newShare], deleting: [])
        guard let saved = try result.saveResults[newShare.recordID]?.get() as? CKShare else {
            throw CKError(.internalError)
        }
        share = saved
        snapshot.isShared = true
        publish()
        return saved
    }

    /// Reads the household's share from iCloud. False when iCloud couldn't be asked.
    @discardableResult
    func refreshShare() async -> Bool {
        guard let container, exists || isMember else { return true }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let database = isMember ? container.sharedCloudDatabase : container.privateCloudDatabase
        do {
            share = try await database.record(for: shareID) as? CKShare
            shareLoaded = true
            claimMyRecordIfNeeded()
            return true
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            share = nil
            shareLoaded = true
            return true
        } catch {
            log.error("Couldn't check the household share: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Invitations, one person each

    /// The keys on a person for their invitation (in `appIDs`, so they sync without a schema
    /// change): a hash of who it went to (never the email or phone itself, which only the
    /// share's participants carry), empty once canceled, and when.
    nonisolated static let inviteKey = "_invite"
    nonisolated static let invitedAtKey = "_invitedAt"

    /// Where someone stands: joined on their own device, invited, or neither.
    func inviteStatus(_ member: HearthMember) -> HearthInviteStatus {
        if member.id == me?.id || member.id == info?.organizerID { return .joined }
        let invitation = participant(for: member)
        if invitation?.acceptanceStatus == .accepted { return .joined }
        // Joined with their own Apple Account (before invitations were by name), and still on
        // the share as far as this device knows.
        // Once the organizer's share is read, not being on it (or there being none: sharing
        // stopped) means they're out.
        if let appleUserID = member.appleUserID, !(shareLoaded && !isMember && (share == nil || !isOnShare(appleUserID))) {
            return .joined
        }
        guard let hash = member.appIDs[Self.inviteKey], !hash.isEmpty, invitation != nil || !shareLoaded else { return .notInvited }
        let at = member.appIDs[Self.invitedAtKey].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        return .invited(at)
    }

    /// The email or phone number someone was invited at, for showing (from the share).
    func invitedContact(_ member: HearthMember) -> String? {
        Self.inviteKey(of: participant(for: member)?.userIdentity.lookupInfo).map(Self.contact(fromKey:))
    }

    /// Only the owner of the household's share can add or remove people on it.
    var canInvite: Bool { !isMember && account == .available && canEditEveryone }

    /// The household's link: it opens only for the people invited to it.
    var invitationURL: URL? { share?.url }

    /// Invites someone as `member`: adds their Apple Account (by email or phone) to the
    /// household's share, with what `role` may do there, and notes the invitation on them.
    /// Returns the link, which only that Apple Account can open, however it's sent.
    @discardableResult
    func invite(_ memberID: String, contact: String, role: HearthRole) async -> URL? {
        problem = nil
        guard account == .available else {
            problem = "Sign in to iCloud in Settings to invite your family."
            return nil
        }
        guard let key = Self.inviteKey(forContact: contact) else {
            problem = "Enter their email address, or their phone number with its country code."
            return nil
        }
        guard canInvite, member(memberID) != nil else { return nil }
        let hash = Self.inviteHash(key)
        if let other = people.first(where: { $0.id != memberID && $0.appIDs[Self.inviteKey] == hash }) {
            problem = "That Apple Account is already invited as \(other.firstName). Cancel that invitation first."
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try? await privateEngine?.sendChanges()
            // The share iCloud has, before making one: never a second.
            guard await refreshShare() else { throw CKError(.networkFailure) }
            if share == nil { _ = try await prepareShare() }
            guard let share else { throw CKError(.internalError) }
            let permission: CKShare.ParticipantPermission = role == .kid ? .readOnly : .readWrite
            if let existing = participant(forKey: key) {
                // Invited before (or already joined): the same invitation, with this role.
                existing.permission = permission
            } else {
                let participant = try await shareParticipant(Self.lookupInfo(forKey: key))
                participant.permission = permission
                share.addParticipant(participant)
            }
            self.share = try await saveShare(share)
            catchUpWithOtherApps()
            guard var member = member(memberID) else { return self.share?.url }
            if canEdit(member) { member.role = role }
            member.appIDs[Self.inviteKey] = hash
            member.appIDs[Self.invitedAtKey] = String(Int(Date.now.timeIntervalSince1970))
            save(member)
            return self.share?.url
        } catch is HearthNoAppleAccount {
            problem = "There's no Apple Account with that \(key.hasPrefix("email:") ? "email address" : "phone number"). Use the one they sign in to iCloud with."
        } catch {
            note(error)
        }
        return nil
    }

    /// Takes back someone's invitation: their link stops working. Their details stay.
    func cancelInvite(_ memberID: String) async {
        guard canInvite, let member = member(memberID), let hash = member.appIDs[Self.inviteKey], !hash.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        problem = nil
        guard await withdraw(matching: hash, appleUserID: nil, includingJoined: false) else { return }
        catchUpWithOtherApps()
        guard var latest = self.member(memberID) else { return }
        latest.appIDs[Self.inviteKey] = ""
        latest.appIDs[Self.invitedAtKey] = ""
        save(latest)
    }

    /// Before archiving or removing someone: takes them off the household's share, so their
    /// invitation stops working and, if they'd joined, the household leaves their devices.
    func withdrawAccess(_ memberID: String) async {
        guard canInvite, let member = member(memberID) else { return }
        let hash = member.appIDs[Self.inviteKey].flatMap { $0.isEmpty ? nil : $0 }
        guard hash != nil || member.appleUserID != nil else { return }
        isWorking = true
        defer { isWorking = false }
        _ = await withdraw(matching: hash, appleUserID: member.appleUserID, includingJoined: true)
    }

    /// Removes the participants for an invitation (and, with `includingJoined`, the Apple
    /// Account that joined). True once iCloud agrees they're off the share.
    private func withdraw(matching hash: String?, appleUserID: String?, includingJoined: Bool) async -> Bool {
        guard await refreshShare() else {
            problem = "Couldn't reach iCloud. Try again in a moment."
            return false
        }
        guard let share else { return true }
        let leaving = share.participants.filter { participant in
            guard participant.role != .owner, participant.acceptanceStatus != .removed else { return false }
            if !includingJoined && participant.acceptanceStatus == .accepted { return false }
            if let hash, Self.inviteKey(of: participant.userIdentity.lookupInfo).map(Self.inviteHash) == hash { return true }
            if let appleUserID, participant.userIdentity.userRecordID?.recordName == appleUserID { return true }
            return false
        }
        guard !leaving.isEmpty else { return true }
        leaving.forEach { share.removeParticipant($0) }
        do {
            self.share = try await saveShare(share)
            return true
        } catch {
            note(error)
            return false
        }
    }

    /// An invitation link someone pasted (or scanned): asks to join, as tapping it would.
    func openInvitation(_ url: URL) async {
        problem = nil
        guard let container else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let metadata = try await shareMetadata(url, container: container)
            if Self.handles(metadata) {
                receive(metadata)
            } else {
                problem = "That link isn't a household invitation."
            }
        } catch {
            log.error("Couldn't open the invitation link: \(error.localizedDescription, privacy: .public)")
            problem = "That invitation couldn't be opened. Ask them for a new one."
        }
    }

    /// The household an invitation is for, before joining.
    var pendingHouseholdName: String? {
        (pendingInvite?.share[CKShare.SystemFieldKey.title] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Who the invitation was sent to (this person's email or phone), before joining.
    var pendingInviteContact: String? {
        Self.inviteKey(of: pendingInvite?.share.currentUserParticipant?.userIdentity.lookupInfo).map(Self.contact(fromKey:))
    }

    /// Whether the invitation lets them change things (parents and adults) or only see (kids).
    var pendingInviteCanEdit: Bool { pendingInvite?.participantPermission == .readWrite }

    /// The person this account's invitation was made for, once it has joined.
    private func invitedMember() -> HearthMember? {
        guard isMember, let myUserID, let share else { return nil }
        let mine = share.participants.first { $0.userIdentity.userRecordID?.recordName == myUserID } ?? share.currentUserParticipant
        guard let key = Self.inviteKey(of: mine?.userIdentity.lookupInfo) else { return nil }
        let hash = Self.inviteHash(key)
        let matches = people.filter { $0.appIDs[Self.inviteKey] == hash }
        // Two people with one invitation can't be told apart: they pick.
        return matches.count == 1 ? matches.first : nil
    }

    private func participant(for member: HearthMember) -> CKShare.Participant? {
        guard let hash = member.appIDs[Self.inviteKey], !hash.isEmpty else { return nil }
        return share?.participants.first { participant in
            participant.role != .owner && participant.acceptanceStatus != .removed
                && Self.inviteKey(of: participant.userIdentity.lookupInfo).map(Self.inviteHash) == hash
        }
    }

    private func participant(forKey key: String) -> CKShare.Participant? {
        share?.participants.first {
            $0.role != .owner && $0.acceptanceStatus != .removed && Self.inviteKey(of: $0.userIdentity.lookupInfo) == key
        }
    }

    private func isOnShare(_ appleUserID: String) -> Bool {
        share?.participants.contains {
            $0.acceptanceStatus == .accepted && $0.userIdentity.userRecordID?.recordName == appleUserID
        } ?? false
    }

    private func saveShare(_ share: CKShare) async throws -> CKShare {
        guard let container else { throw CKError(.notAuthenticated) }
        let result = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
        guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare else { throw CKError(.internalError) }
        return saved
    }

    /// The share participant for an Apple Account, found by email or phone.
    private func shareParticipant(_ info: CKUserIdentity.LookupInfo) async throws -> CKShare.Participant {
        guard let container else { throw CKError(.notAuthenticated) }
        let box = HearthResultBox<CKShare.Participant>()
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [info])
            operation.perShareParticipantResultBlock = { _, result in box.result = result }
            operation.fetchShareParticipantsResultBlock = { result in
                switch result {
                case .failure(let error as CKError) where error.code == .unknownItem || error.code == .partialFailure:
                    continuation.resume(throwing: HearthNoAppleAccount())
                case .failure(let error):
                    continuation.resume(throwing: error)
                case .success:
                    switch box.result {
                    case .success(let participant)?: continuation.resume(returning: participant)
                    case .failure(let error as CKError)? where error.code != .unknownItem && error.code != .partialFailure:
                        continuation.resume(throwing: error)
                    default: continuation.resume(throwing: HearthNoAppleAccount())
                    }
                }
            }
            container.add(operation)
        }
    }

    private func shareMetadata(_ url: URL, container: CKContainer) async throws -> CKShare.Metadata {
        let box = HearthResultBox<CKShare.Metadata>()
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])
            operation.perShareMetadataResultBlock = { _, result in box.result = result }
            operation.fetchShareMetadataResultBlock = { result in
                switch result {
                case .failure(let error): continuation.resume(throwing: error)
                case .success: continuation.resume(with: box.result ?? .failure(CKError(.unknownItem)))
                }
            }
            container.add(operation)
        }
    }

    /// One form for an email or phone number, the same from what someone typed (or picked in
    /// Contacts) and from what iCloud reports: "email:ann@icloud.com" or "phone:15551234567"
    /// (country code first). A number typed without "+" gets this device's country code. Nil
    /// when it's neither.
    nonisolated static func inviteKey(forContact text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            let parts = trimmed.split(separator: "@")
            guard parts.count == 2, parts[1].contains("."), !trimmed.contains(where: \.isWhitespace) else { return nil }
            return "email:" + trimmed.lowercased()
        }
        guard !trimmed.contains(where: \.isLetter) else { return nil }
        var digits = trimmed.filter { $0.isASCII && $0.isNumber }
        if !trimmed.contains("+") {
            // A national number: drop a trunk "0", add this device's country code.
            guard let code = countryCallingCode else { return nil }
            if digits.hasPrefix("0") { digits.removeFirst() }
            if !(code == "1" && digits.count == 11 && digits.hasPrefix("1")) { digits = code + digits }
        }
        guard (8...15).contains(digits.count) else { return nil }
        return "phone:" + digits
    }

    /// The same form, from what iCloud reports for a participant.
    nonisolated static func inviteKey(of info: CKUserIdentity.LookupInfo?) -> String? {
        if let email = info?.emailAddress, !email.isEmpty { return "email:" + email.lowercased() }
        if let phone = info?.phoneNumber, !phone.isEmpty { return inviteKey(forContact: phone.hasPrefix("+") ? phone : "+" + phone) }
        return nil
    }

    /// What's kept on the person: a hash of the key, so the household never stores who
    /// someone's email or phone is.
    nonisolated static func inviteHash(_ key: String) -> String {
        "h:" + SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func lookupInfo(forKey key: String) -> CKUserIdentity.LookupInfo {
        if key.hasPrefix("email:") { return CKUserIdentity.LookupInfo(emailAddress: String(key.dropFirst(6))) }
        return CKUserIdentity.LookupInfo(phoneNumber: "+" + String(key.dropFirst(6)))
    }

    nonisolated static func contact(fromKey key: String) -> String {
        key.hasPrefix("email:") ? String(key.dropFirst(6)) : "+" + String(key.dropFirst(6))
    }

    /// This device's country calling code, for numbers typed without one.
    nonisolated private static var countryCallingCode: String? {
        let codes = ["US": "1", "CA": "1", "GB": "44", "AU": "61", "NZ": "64", "IE": "353", "IN": "91",
                     "DE": "49", "FR": "33", "ES": "34", "IT": "39", "NL": "31", "MX": "52", "BR": "55",
                     "JP": "81", "KR": "82", "PH": "63", "ZA": "27", "SG": "65", "SE": "46", "NO": "47",
                     "DK": "45", "CH": "41", "AT": "43", "BE": "32", "PT": "351", "PL": "48"]
        return Locale.current.region.flatMap { codes[$0.identifier] }
    }

    /// Apple's sheet for inviting someone: `role` decides whether they can edit (parents and
    /// adults) or only see (kids). (The household screens invite one person at a time instead,
    /// with `invite(_:contact:role:)`.)
    func presentInvite(as role: HearthRole) async {
        guard account == .available else {
            problem = "Sign in to iCloud in Settings to invite your family."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try? await privateEngine?.sendChanges()
            let share = try await prepareShare()
            guard let container else { return }
            let controller = UICloudSharingController(share: share, container: container)
            controller.availablePermissions = role == .kid ? [.allowReadOnly, .allowPrivate] : [.allowReadWrite, .allowPrivate]
            controller.delegate = sharingDelegate
            controller.modalPresentationStyle = .formSheet
            UIApplication.shared.hearthTopViewController?.present(controller, animated: true)
        } catch {
            note(error)
        }
    }

    fileprivate func sharingChanged() {
        Task { await refreshShare() }
    }

    // MARK: - Stopping sharing (organizer)

    /// The zone each sharing app keeps in the organizer's private database (`HearthAppSharing`),
    /// and how it's named in Household › Shared in Each App.
    nonisolated static let appZones: [(app: HearthApp, zoneName: String)] = [
        (.bigtable, "Kitchen"),
        (.caloma, "Caloma"),
        (.suffice, "Budget"),
        (.trove, "Trove"),
    ]

    /// The organizer is sharing the household with someone (invited or joined).
    var isSharing: Bool { !isMember && shareLoaded && !participants.isEmpty }

    /// An app's zone is shared with the household (its link is in the household).
    func isAppShared(_ app: HearthApp) -> Bool {
        !(info?.appShareURLs[app.rawValue] ?? "").isEmpty
    }

    /// Stops sharing the household and every app's zone: everyone else loses access on their
    /// devices (their apps go back to their own data) and their invitations stop working. The
    /// people stay in the household, not invited, and can be invited again. True when done.
    @discardableResult
    func stopSharing() async -> Bool {
        guard canInvite, let container else { return false }
        isWorking = true
        defer { isWorking = false }
        problem = nil
        let database = container.privateCloudDatabase
        do {
            // The apps' zones first: if the household's share went first and this failed, its
            // data would stay shared with no way to see who it's shared with.
            for zone in Self.appZones {
                try await deleteZoneWideShare(in: CKRecordZone.ID(zoneName: zone.zoneName), database: database)
            }
            try await deleteZoneWideShare(in: zoneID, database: database)
        } catch {
            note(error)
            await refreshShare()
            return false
        }
        share = nil
        shareLoaded = true
        updateInfo(clearAppShares: true)
        // Their invitations and their Hearth account links (so the organizer's app ends their
        // share of the plan). Blanked, not removed, so other copies can't bring them back.
        for person in people where person.id != me?.id && person.id != info?.organizerID {
            var changed = person
            for key in [Self.inviteKey, Self.invitedAtKey, HearthHouseholdServer.accountKey] where !(changed.appIDs[key] ?? "").isEmpty {
                changed.appIDs[key] = ""
            }
            if changed != person { save(changed) }
        }
        log.notice("Stopped sharing the household")
        return true
    }

    /// Deletes a zone's zone-wide share; no share (or no zone) is fine.
    private func deleteZoneWideShare(in zone: CKRecordZone.ID, database: CKDatabase) async throws {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
        do {
            let result = try await database.modifyRecords(saving: [], deleting: [shareID])
            if case .failure(let error)? = result.deleteResults[shareID] { throw error }
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
        }
    }

    // MARK: - Joining and leaving (member)

    /// Whether an invitation is to the Hearth household (and not an app's own sharing).
    nonisolated static func handles(_ metadata: CKShare.Metadata) -> Bool {
        metadata.containerIdentifier == containerID && metadata.share.recordID.zoneID.zoneName == zoneName
    }

    /// From the app's scene delegate, for invitations to this container.
    func receive(_ metadata: CKShare.Metadata) {
        guard metadata.participantRole != .owner else { return }
        if case .member(let ownerName) = mode, ownerName == metadata.share.recordID.zoneID.ownerName { return }
        pendingInvite = metadata
    }

    var inviterName: String {
        guard let components = pendingInvite?.ownerIdentity.nameComponents else { return "your family" }
        let name = components.formatted(.name(style: .short))
        return name.isEmpty ? "your family" : name
    }

    /// Joins the pending invitation's household. This device's own household stays in this
    /// person's iCloud and comes back if they leave.
    func acceptInvite() async {
        guard let metadata = pendingInvite, let container else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try? await privateEngine?.sendChanges()
            _ = try await container.accept(metadata)
        } catch {
            note(error)
            return
        }
        pendingInvite = nil
        becomeMember(ownerName: metadata.share.recordID.zoneID.ownerName)
    }

    /// Leaves the household this account joined.
    func leave() async {
        guard isMember, let container else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
        } catch {
            note(error)
            return
        }
        returnToOwnHousehold()
    }

    private func becomeMember(ownerName: String) {
        guard mode != .member(ownerName: ownerName), let container else { return }
        log.notice("Joining a shared household")
        setMemberOf(ownerName)
        setLocalMe(nil)
        mode = .member(ownerName: ownerName)
        share = nil
        snapshot = HearthHouseholdSnapshot(info: nil, members: [], isShared: true, adoptedAt: .now)
        publish()
        systemFields = [:]
        HearthHouseholdFiles.saveFields(systemFields)
        HearthHouseholdFiles.saveState(nil, .shared)
        sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: nil)
        sharedFetched = false
        shareLoaded = false
        zoneParticipant?.zoneEngineReset(isShared: true)
        Task {
            try? await sharedEngine?.fetchChanges()
            await refreshShare()
        }
    }

    private func returnToOwnHousehold() {
        guard isMember, let container else { return }
        setMemberOf(nil)
        setLocalMe(nil)
        mode = .owner
        share = nil
        snapshot = HearthHouseholdSnapshot(info: nil, members: [], adoptedAt: .now)
        publish()
        systemFields = [:]
        HearthHouseholdFiles.saveFields(systemFields)
        HearthHouseholdFiles.saveState(nil, .private)
        privateEngine = makeEngine(database: container.privateCloudDatabase, state: nil)
        privateFetched = false
        shareLoaded = false
        zoneParticipant?.zoneEngineReset(isShared: false)
        Task {
            try? await privateEngine?.fetchChanges()
            await refreshShare()
        }
    }

    // MARK: - Helpers

    private func cache(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        systemFields[record.recordID.recordName] = coder.encodedData
    }

    private func cachedRecord(_ recordID: CKRecord.ID) -> CKRecord? {
        guard let data = systemFields[recordID.recordName],
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordID.zoneID == recordID.zoneID else { return nil }
        return record
    }

    private func scheduleFieldsSave() {
        fieldsSaveTask?.cancel()
        fieldsSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            HearthHouseholdFiles.saveFields(systemFields)
        }
    }

    private func note(_ error: Error) {
        log.error("Household sync: \(String(describing: error), privacy: .public)")
        if let error = error as? CKError {
            switch error.code {
            case .networkUnavailable, .networkFailure, .operationCancelled:
                return
            case .notAuthenticated:
                problem = "Sign in to iCloud in Settings to share your household."
            case .quotaExceeded:
                problem = "Your iCloud storage is full."
            case .participantMayNeedVerification:
                problem = "Open the invitation in Messages or Mail on this device to verify it, then try again."
            default:
                problem = Self.isUndeployedSchema(error)
                    ? "Inviting isn't available yet. Your household is safe on this device; try again after the next update."
                    : "Something went wrong with iCloud. Try again in a moment."
            }
        } else {
            problem = "Something went wrong with iCloud. Try again in a moment."
        }
    }

    /// iCloud's Production database was never given a record type this build saves (like the
    /// household's `cloudkit.share`). Only a developer can fix it, by deploying the
    /// `iCloud.com.stephenwarren.hearth` schema to Production in the CloudKit Console; the log
    /// above has the details.
    nonisolated static func isUndeployedSchema(_ error: CKError) -> Bool {
        let errors = [error] + (error.partialErrorsByItemID?.values.compactMap { $0 as? CKError } ?? [])
        return errors.contains { $0.localizedDescription.localizedCaseInsensitiveContains("production schema") }
    }
}

// MARK: - Records

/// Household and member records, field by field. Food and birthdays go in `encryptedValues`.
nonisolated enum HearthHouseholdRecords {
    static func write(_ info: HearthHouseholdInfo, to record: CKRecord) {
        record["householdID"] = info.id as NSString
        record["name"] = info.name as NSString
        record["organizerID"] = info.organizerID.map { $0 as NSString }
        record["updatedAt"] = info.updatedAt as NSDate
        record.encryptedValues["restrictions"] = info.restrictions as NSArray
        record.encryptedValues["joinCode"] = info.joinCode.map { $0 as NSString }
        record.encryptedValues["appShareURLs"] = (try? JSONEncoder().encode(info.appShareURLs)).flatMap { String(data: $0, encoding: .utf8) }.map { $0 as NSString }
        // Only once some app has set them: left unset, iCloud keeps the times it has.
        if let mealTimes = info.mealTimes, let data = try? JSONEncoder().encode(mealTimes) {
            record["mealTimes"] = String(decoding: data, as: UTF8.self) as NSString
            record["mealTimesAt"] = (info.mealTimesAt ?? info.updatedAt) as NSDate
        }
    }

    static func info(from record: CKRecord) -> HearthHouseholdInfo {
        HearthHouseholdInfo(
            id: record["householdID"] as? String ?? record.recordID.zoneID.ownerName,
            name: record["name"] as? String ?? "Household",
            restrictions: record.encryptedValues["restrictions"] as? [String] ?? [],
            organizerID: record["organizerID"] as? String,
            updatedAt: record["updatedAt"] as? Date ?? record.modificationDate ?? .distantPast,
            joinCode: record.encryptedValues["joinCode"] as? String,
            appShareURLs: (record.encryptedValues["appShareURLs"] as? String)
                .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:],
            mealTimes: (record["mealTimes"] as? String)
                .flatMap { try? JSONDecoder().decode(HearthMealTimes.self, from: Data($0.utf8)) },
            mealTimesAt: record["mealTimesAt"] as? Date
        )
    }

    static func write(_ member: HearthMember, to record: CKRecord) {
        record["name"] = member.name as NSString
        record["role"] = member.role.rawValue as NSString
        record["colorHex"] = NSNumber(value: member.colorHex)
        record["sortOrder"] = NSNumber(value: member.sortOrder)
        record["isArchived"] = NSNumber(value: member.isArchived)
        record["appleUserID"] = member.appleUserID.map { $0 as NSString }
        record["appIDs"] = (try? String(data: JSONEncoder().encode(member.appIDs), encoding: .utf8)).map { $0 as NSString }
        record["updatedAt"] = member.updatedAt as NSDate
        record.encryptedValues["birthday"] = member.birthday.map { $0 as NSString }
        record.encryptedValues["allergies"] = member.allergies as NSArray
        record.encryptedValues["diet"] = member.diet as NSArray
        record.encryptedValues["likes"] = member.likes as NSArray
        record.encryptedValues["dislikes"] = member.dislikes as NSArray
        // The photo's file name is derived from its bytes, so every device stores it under
        // the same name and only downloads it once.
        // The record here carries only iCloud's system fields, so a field left unset keeps
        // iCloud's value.
        if let name = member.photo, let data = Hearth.photo(named: name) {
            let url = FileManager.default.temporaryDirectory.appending(path: "hearth-\(member.id).jpg", directoryHint: .notDirectory)
            try? data.write(to: url, options: .atomic)
            record["photoName"] = name as NSString
            record["photo"] = CKAsset(fileURL: url)
        } else if member.photo == nil {
            record["photoName"] = nil
            record["photo"] = nil
        }
        // Otherwise this device doesn't have the file: iCloud keeps the photo it has.
    }

    /// Marks a deleted person in `appIDs` (an existing field, so iCloud's schema doesn't change).
    private static let deletedKey = "_deletedAt"

    /// A deleted person: nothing but when. Archived and nameless, so builds from before markers
    /// existed hide it.
    static func writeDeleted(at date: Date, to record: CKRecord) {
        let marker = [deletedKey: String(date.timeIntervalSince1970)]
        record["appIDs"] = (try? String(data: JSONEncoder().encode(marker), encoding: .utf8)).map { $0 as NSString }
        record["updatedAt"] = date as NSDate
        record["isArchived"] = NSNumber(value: true)
        record["name"] = "" as NSString
        for key in ["appleUserID", "photoName", "photo"] { record[key] = nil }
        for key in ["birthday", "allergies", "diet", "likes", "dislikes"] { record.encryptedValues[key] = nil }
    }

    /// When a person's record says they were deleted, or nil for a live person.
    static func deletedAt(_ record: CKRecord) -> Date? {
        guard let json = record["appIDs"] as? String, json.contains(deletedKey),
              let map = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)),
              let seconds = map[deletedKey].flatMap(Double.init) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A member from iCloud. Its photo is copied into the shared folder unless this device
    /// already has it.
    static func member(from record: CKRecord, existing: [HearthMember]) -> HearthMember? {
        let name = record.recordID.recordName
        guard name.hasPrefix("member-"), deletedAt(record) == nil else { return nil }
        let id = String(name.dropFirst("member-".count))
        var appIDs: [String: String] = [:]
        if let json = record["appIDs"] as? String, let data = json.data(using: .utf8) {
            appIDs = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        var photo: String?
        if let remoteName = record["photoName"] as? String {
            if Hearth.photo(named: remoteName) != nil {
                photo = remoteName
            } else if let asset = record["photo"] as? CKAsset, let url = asset.fileURL,
                      let data = try? Data(contentsOf: url) {
                photo = HearthHouseholdPhotos.store(data, name: remoteName)
            } else {
                photo = existing.first { $0.id == id }?.photo
            }
        }
        return HearthMember(
            id: id,
            name: record["name"] as? String ?? "",
            role: HearthRole(rawValue: record["role"] as? String ?? "") ?? .adult,
            colorHex: (record["colorHex"] as? NSNumber)?.uint32Value ?? 0x0A7AFF,
            photo: photo,
            birthday: record.encryptedValues["birthday"] as? String,
            allergies: record.encryptedValues["allergies"] as? [String] ?? [],
            diet: record.encryptedValues["diet"] as? [String] ?? [],
            likes: record.encryptedValues["likes"] as? [String] ?? [],
            dislikes: record.encryptedValues["dislikes"] as? [String] ?? [],
            appleUserID: record["appleUserID"] as? String,
            appIDs: appIDs,
            isArchived: (record["isArchived"] as? NSNumber)?.boolValue ?? false,
            sortOrder: (record["sortOrder"] as? NSNumber)?.intValue ?? 0,
            updatedAt: record["updatedAt"] as? Date ?? record.modificationDate ?? .distantPast
        )
    }
}

// MARK: - Saved state

/// What the store keeps between launches, in this app's Application Support/HearthHousehold.
nonisolated enum HearthHouseholdFiles {
    nonisolated enum Engine: String { case `private`, shared }

    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "HearthHousehold", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func loadState(_ engine: Engine) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: folder.appending(path: "\(engine.rawValue).state")) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    static func saveState(_ state: CKSyncEngine.State.Serialization?, _ engine: Engine) {
        let url = folder.appending(path: "\(engine.rawValue).state")
        guard let state, let data = try? JSONEncoder().encode(state) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    static func loadFields() -> [String: Data] {
        guard let data = try? Data(contentsOf: folder.appending(path: "systemFields.plist")) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    static func saveFields(_ fields: [String: Data]) {
        guard let data = try? PropertyListEncoder().encode(fields) else { return }
        try? data.write(to: folder.appending(path: "systemFields.plist"), options: .atomic)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}

// MARK: - Sharing controller

private final class HearthHouseholdSharingDelegate: NSObject, UICloudSharingControllerDelegate {
    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        Logger(subsystem: "com.stephenwarren.hearth", category: "household")
            .error("Sharing failed: \(error.localizedDescription, privacy: .public)")
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        HearthHouseholdStore.shared.info?.name ?? "Hearth Household"
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        HearthHouseholdStore.shared.sharingChanged()
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        HearthHouseholdStore.shared.sharingChanged()
    }
}

/// Where someone stands with the household: on their own device, invited, or neither.
nonisolated enum HearthInviteStatus: Equatable, Sendable {
    case joined
    case invited(Date?)
    case notInvited
}

/// No Apple Account has the email or phone number someone was invited at.
nonisolated struct HearthNoAppleAccount: Error {}

/// Carries one result out of a CloudKit operation's callbacks.
nonisolated private final class HearthResultBox<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

/// The scene delegate for apps that share nothing in iCloud of their own (BigTable, Sated):
/// household invitations tapped in Messages or Mail land here.
final class HearthHouseholdSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata, HearthHouseholdStore.handles(metadata) {
            HearthHouseholdStore.shared.receive(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        if HearthHouseholdStore.handles(cloudKitShareMetadata) {
            HearthHouseholdStore.shared.receive(cloudKitShareMetadata)
        }
    }
}

extension UIApplication {
    /// The view controller on top of the foreground window, to present from.
    var hearthTopViewController: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let window = (active + scenes).flatMap(\.windows).first(where: \.isKeyWindow) ?? (active + scenes).first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - App zones

/// A zone of an app's own that syncs on the household's engines. The store fetches only the
/// household's zone and the participant's, and hands over everything for the participant's.
@MainActor
protocol HearthZoneParticipant: AnyObject {
    /// The zone's name ("Kitchen"), to recognise it in database changes.
    var zoneName: String { get }
    /// Where the zone is now: this account's private database, or shared with it. Nil: none.
    var zoneLocation: (zoneID: CKRecordZone.ID, isShared: Bool)? { get }
    /// The record to upload for a pending save, or nil when it no longer exists.
    func zoneRecord(for recordID: CKRecord.ID) -> CKRecord?
    func zoneFetched(modifications: [CKRecord], deletions: [CKDatabase.RecordZoneChange.Deletion])
    /// Returns the changes to try again.
    func zoneSent(saved: [CKRecord], deleted: [CKRecord.ID], failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave], isShared: Bool) -> [CKSyncEngine.PendingRecordZoneChange]
    /// Zones with the participant's name appeared in, or went from, a database.
    func zoneDatabaseChanged(added: [CKRecordZone.ID], deleted: [CKDatabase.DatabaseChange.Deletion], isShared: Bool)
    /// An engine started over (joining or leaving a household, a new account): queue what lives
    /// in that database again.
    func zoneEngineReset(isShared: Bool)
    /// The iCloud account signed out or changed: drop what belonged to the old one.
    func zoneAccountDidChange()
}
