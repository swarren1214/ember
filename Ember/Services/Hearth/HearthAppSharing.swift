import CloudKit
import Foundation
import os

/// Shares an app's own zone (BigTable's kitchen, Caloma's family, Suffice's budget) with the
/// Hearth household, so a family accepts one invitation (the household's) for every app.
///
/// - The household's owner: the app makes a zone-wide share of its zone in their private
///   database, adds the household's people (parents and adults; kids too when the app wants
///   them), and writes the share's link into the household (`appShareURLs`, encrypted).
/// - Everyone else: the app accepts that share from the link without asking (they already
///   accepted the household), and syncs the zone from their shared database.
///
/// The zone syncs on the household's engines (`HearthZoneParticipant`). Call `update` on
/// launch, coming to the foreground and when the household changes.
@MainActor
enum HearthAppSharing {
    private static let log = Logger(subsystem: "com.stephenwarren.hearth", category: "household")
    private static var running: Set<String> = []

    /// Who the app's zone is shared with.
    enum Audience {
        /// Parents and adults (household participants who can edit it).
        case adults
        /// Everyone in the household, kids included, each able to edit (Caloma's Kid View).
        case everyone
    }

    /// Shares (owner) or joins (everyone else) the app's zone. `joined` is called with the
    /// owner's name once this account is in the family's zone.
    static func update(app: HearthApp, zoneName: String, title: String, audience: Audience, joined: (String) -> Void) async {
        let household = HearthHouseholdStore.shared
        guard !running.contains(zoneName), household.exists, household.account == .available,
              let container = household.cloudContainer else { return }
        running.insert(zoneName)
        defer { running.remove(zoneName) }
        if household.isMember {
            if let owner = await join(app: app, zoneName: zoneName, container: container) { joined(owner) }
        } else {
            await share(app: app, zoneName: zoneName, title: title, audience: audience, container: container)
        }
    }

    // MARK: Owner

    private static func share(app: HearthApp, zoneName: String, title: String, audience: Audience, container: CKContainer) async {
        let household = HearthHouseholdStore.shared
        // Read the household's share fresh every time: the copy loaded at launch still lists
        // someone who has since accepted the invitation as pending, so they'd never be added
        // to the app's zone until the app was quit and opened again.
        await household.refreshShare()
        // Who's in the household is only known once its share has been read; before that an
        // empty list would take everyone out of the app's zone.
        guard household.shareLoaded else { return }
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: zoneName)
        let people = household.participants.filter { participant in
            participant.acceptanceStatus == .accepted
                && (audience == .everyone || participant.permission == .readWrite)
        }
        // Nobody else in the household yet, and never shared: nothing to do.
        // (A blank link: sharing was stopped, so it waits for someone to join again.)
        guard !people.isEmpty || household.isAppShared(app) else { return }
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
            var share: CKShare
            do {
                guard let existing = try await database.record(for: shareID) as? CKShare else { throw CKError(.unknownItem) }
                share = existing
            } catch let error as CKError where error.code == .unknownItem {
                share = CKShare(recordZoneID: zoneID)
                share[CKShare.SystemFieldKey.title] = title as CKRecordValue
                share.publicPermission = .none
            }

            let wanted = Set(people.compactMap { $0.userIdentity.userRecordID })
            var changed = share.recordChangeTag == nil
            for participant in share.participants where participant.role != .owner {
                if let id = participant.userIdentity.userRecordID, !wanted.contains(id) {
                    share.removeParticipant(participant)
                    changed = true
                }
            }
            let present = Set(share.participants.compactMap { $0.userIdentity.userRecordID })
            let missing = wanted.subtracting(present)
            if !missing.isEmpty {
                let found = try await container.shareParticipants(forUserRecordIDs: Array(missing))
                for case .success(let participant) in found.values {
                    participant.permission = .readWrite
                    share.addParticipant(participant)
                    changed = true
                }
            }
            if changed {
                let result = try await database.modifyRecords(saving: [share], deleting: [])
                if let saved = try result.saveResults[share.recordID]?.get() as? CKShare { share = saved }
            }
            if let url = share.url?.absoluteString, household.info?.appShareURLs[app.rawValue] != url {
                household.updateInfo(appShare: (app, url))
            }
        } catch {
            log.error("Couldn't share \(zoneName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Everyone else

    /// Returns the zone owner's name when this account is in the family's zone.
    private static func join(app: HearthApp, zoneName: String, container: CKContainer) async -> String? {
        let household = HearthHouseholdStore.shared
        guard case .member(let ownerName) = household.mode else { return nil }
        // Already in the shared database (accepted on another device)?
        if let zones = try? await container.sharedCloudDatabase.allRecordZones(),
           zones.contains(where: { $0.zoneID.zoneName == zoneName && $0.zoneID.ownerName == ownerName }) {
            return ownerName
        }
        guard let link = household.info?.appShareURLs[app.rawValue], !link.isEmpty, let url = URL(string: link) else { return nil }
        do {
            let metadatas = try await container.shareMetadatas(for: [url])
            guard let metadata = try metadatas[url]?.get(), metadata.participantRole != .owner else { return nil }
            if metadata.participantStatus != .accepted {
                _ = try await container.accept(metadata)
            }
            return ownerName
        } catch {
            // Not added yet: the owner's app adds them next time it opens.
            log.notice("\(zoneName, privacy: .public) isn't shared with this account yet: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
