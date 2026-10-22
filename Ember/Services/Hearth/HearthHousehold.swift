// HearthHousehold.swift — the one household every Hearth app shares: its people, their photos,
// birthdays, allergies, diets, likes and dislikes.
//
// Canonical copy: ~/Developer/hearthkit/HearthHousehold.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh.
//
// Where it lives (see the "Hearth Household" design doc)
// - In iCloud: the zone "Household" in the shared container iCloud.com.stephenwarren.hearth,
//   owned by the organizer and shared with the family (`HearthHouseholdStore`). Birthdays,
//   allergies, diets, likes and dislikes are encrypted fields.
// - On the device: each app writes its copy to the app group (`<app>.household.json`), so the
//   other apps see a change at once, even before iCloud has it. Readers merge the copies.
// - Never on a server. hearth-api only learns ages and food rules for one AI request at a time
//   (`HearthHouseholdSnapshot.aiContext`), with no names.
//
// Each app keys its own per-person data (points, spending, ratings) to `HearthMember.id`, and
// keeps the id it used before in `HearthMember.appIDs`.

import Foundation
import SwiftUI
import UIKit

// MARK: - People

nonisolated enum HearthRole: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Edits anyone, invites, removes.
    case parent
    /// Edits their own details: a grandparent, an older kid.
    case adult
    /// Parents manage their details.
    case kid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .parent: "Parent"
        case .adult: "Adult"
        case .kid: "Kid"
        }
    }

    var note: String {
        switch self {
        case .parent: "Can add, edit and remove anyone, and invite people."
        case .adult: "Can edit their own details, like a grandparent or an older kid."
        case .kid: "Parents manage their details. With their own Apple Account, they can see the family."
        }
    }
}

nonisolated struct HearthMember: Codable, Hashable, Sendable, Identifiable {
    /// A UUID string; the iCloud record is "member-<id>".
    var id: String
    var name: String
    var role: HearthRole
    /// 0xRRGGBB, usually a `HearthPalette` color.
    var colorHex: UInt32
    /// A JPEG in the shared photos folder (`Hearth.photo(named:)`).
    var photo: String?
    /// "YYYY-MM-DD". Encrypted in iCloud.
    var birthday: String?
    /// Hard rules: never in a suggested meal. Encrypted.
    var allergies: [String] = []
    /// Preferences: vegetarian, no pork. Encrypted.
    var diet: [String] = []
    /// Encrypted.
    var likes: [String] = []
    /// Encrypted.
    var dislikes: [String] = []
    /// Their iCloud user record name, set when they create or join the household on their own
    /// device. Marks who "me" is on each device.
    var appleUserID: String?
    /// The id each app used for this person before the household ("caloma": a member UUID,
    /// "bigtable": a server member id, "suffice": a member UUID).
    var appIDs: [String: String] = [:]
    var isArchived = false
    var sortOrder = 0
    /// When anything about them last changed, for merging copies (newest wins).
    var updatedAt: Date = .now

    init(
        id: String = UUID().uuidString,
        name: String,
        role: HearthRole,
        colorHex: UInt32,
        photo: String? = nil,
        birthday: String? = nil,
        allergies: [String] = [],
        diet: [String] = [],
        likes: [String] = [],
        dislikes: [String] = [],
        appleUserID: String? = nil,
        appIDs: [String: String] = [:],
        isArchived: Bool = false,
        sortOrder: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.colorHex = colorHex
        self.photo = photo
        self.birthday = birthday
        self.allergies = allergies
        self.diet = diet
        self.likes = likes
        self.dislikes = dislikes
        self.appleUserID = appleUserID
        self.appIDs = appIDs
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var firstName: String { String(trimmedName.split(separator: " ").first ?? "") }
    var initial: String { trimmedName.first.map { String($0).uppercased() } ?? "?" }
    var color: Color { hearthPickerColor(colorHex) }
    var isKid: Bool { role == .kid }

    var birthDate: Date? { birthday.flatMap { HearthDay.date(from: $0) } }

    /// Whole years old on `date`, from the birthday.
    func age(on date: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let birthDate else { return nil }
        return calendar.dateComponents([.year], from: birthDate, to: date).year
    }

    /// The id of this person in `app`, if that app had one.
    func appID(_ app: HearthApp) -> String? { appIDs[app.rawValue] }

    /// Whether two copies say the same thing (ignoring when they were saved).
    func sameContent(as other: HearthMember) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

/// The household itself: its name and rules for everyone.
nonisolated struct HearthHouseholdInfo: Codable, Hashable, Sendable {
    /// Made when the household is created. Copies of different households never merge.
    var id: String = UUID().uuidString
    var name: String
    /// Household-wide rules ("No peanuts in the house"). Encrypted.
    var restrictions: [String] = []
    /// The member who created it and owns the iCloud share.
    var organizerID: String?
    var updatedAt: Date = .now
    /// Joins the organizer's Hearth server membership (shared subscription). Only people in
    /// the household can read it. Encrypted.
    var joinCode: String? = nil
    /// Each app's shared zone (BigTable's kitchen, Caloma's family, Suffice's budget), by app:
    /// the household's people are added to it, and their app joins it from this link.
    /// Encrypted.
    var appShareURLs: [String: String] = [:]
    /// When the family eats (set in BigTable or Caloma), so every device and everyone in the
    /// household has the same times, not just the apps on one device. `HearthMealTimes.current`
    /// reads it.
    var mealTimes: HearthMealTimes? = nil
    /// When `mealTimes` last changed. Copies merge it by this, not by `updatedAt`.
    var mealTimesAt: Date? = nil

    /// Takes the other copy's meal times when they changed more recently than these.
    mutating func keepNewerMealTimes(from other: HearthHouseholdInfo?) {
        guard let other, let theirs = other.mealTimes,
              (other.mealTimesAt ?? .distantPast) > (mealTimesAt ?? .distantPast) else { return }
        mealTimes = theirs
        mealTimesAt = other.mealTimesAt
    }
}

extension HearthHouseholdInfo {
    /// Fields added later are optional when reading older copies.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            restrictions: try c.decodeIfPresent([String].self, forKey: .restrictions) ?? [],
            organizerID: try c.decodeIfPresent(String.self, forKey: .organizerID),
            updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast,
            joinCode: try c.decodeIfPresent(String.self, forKey: .joinCode),
            appShareURLs: try c.decodeIfPresent([String: String].self, forKey: .appShareURLs) ?? [:],
            mealTimes: try c.decodeIfPresent(HearthMealTimes.self, forKey: .mealTimes),
            mealTimesAt: try c.decodeIfPresent(Date.self, forKey: .mealTimesAt)
        )
    }
}

// MARK: - The copy each app keeps in the app group

extension HearthRole {
    /// A role from a newer app this one doesn't know reads as an adult, instead of making the
    /// whole household unreadable.
    nonisolated init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HearthRole(rawValue: raw) ?? .adult
    }
}

extension HearthMember {
    /// Fields added later are optional when reading older copies.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            role: try c.decodeIfPresent(HearthRole.self, forKey: .role) ?? .adult,
            colorHex: try c.decodeIfPresent(UInt32.self, forKey: .colorHex) ?? 0x0A7AFF,
            photo: try c.decodeIfPresent(String.self, forKey: .photo),
            birthday: try c.decodeIfPresent(String.self, forKey: .birthday),
            allergies: try c.decodeIfPresent([String].self, forKey: .allergies) ?? [],
            diet: try c.decodeIfPresent([String].self, forKey: .diet) ?? [],
            likes: try c.decodeIfPresent([String].self, forKey: .likes) ?? [],
            dislikes: try c.decodeIfPresent([String].self, forKey: .dislikes) ?? [],
            appleUserID: try c.decodeIfPresent(String.self, forKey: .appleUserID),
            appIDs: try c.decodeIfPresent([String: String].self, forKey: .appIDs) ?? [:],
            isArchived: try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            sortOrder: try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0,
            updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        )
    }
}

nonisolated struct HearthHouseholdSnapshot: HearthPublication, Hashable {
    static let kind = "household"
    static let version = 1

    var info: HearthHouseholdInfo?
    /// Everyone, archived included, in order.
    var members: [HearthMember]
    /// Members deleted (not archived), with when, so an older copy can't bring them back.
    var deleted: [String: Date] = [:]
    /// Shared with others in iCloud.
    var isShared = false
    /// When this copy's app last switched households (created, joined, left). The copy that
    /// switched last says which household this device is in.
    var adoptedAt: Date = .distantPast

    static let empty = HearthHouseholdSnapshot(info: nil, members: [])

    init(info: HearthHouseholdInfo?, members: [HearthMember], deleted: [String: Date] = [:], isShared: Bool = false, adoptedAt: Date = .distantPast) {
        self.info = info
        self.members = members
        self.deleted = deleted
        self.isShared = isShared
        self.adoptedAt = adoptedAt
    }

    /// Fields added later are optional when reading older copies.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = try c.decodeIfPresent(HearthHouseholdInfo.self, forKey: .info)
        members = try c.decodeIfPresent([HearthMember].self, forKey: .members) ?? []
        deleted = try c.decodeIfPresent([String: Date].self, forKey: .deleted) ?? [:]
        isShared = try c.decodeIfPresent(Bool.self, forKey: .isShared) ?? false
        adoptedAt = try c.decodeIfPresent(Date.self, forKey: .adoptedAt) ?? .distantPast
    }

    var exists: Bool { info != nil }
    var people: [HearthMember] { members.filter { !$0.isArchived } }

    func member(_ id: String?) -> HearthMember? {
        guard let id else { return nil }
        return members.first { $0.id == id }
    }

    /// The person `app` knew as `appID`.
    func member(app: HearthApp, appID: String) -> HearthMember? {
        members.first { $0.appIDs[app.rawValue] == appID }
    }

    /// Every copy of the household this device is in, merged: the newest household info, and
    /// for each person the newest copy. A deletion newer than a person's last change removes
    /// them. Copies of another household (from before joining or leaving) are ignored.
    static func merged(_ all: [HearthHouseholdSnapshot]) -> HearthHouseholdSnapshot {
        guard let reference = all.max(by: { $0.adoptedAt < $1.adoptedAt }) else { return .empty }
        let householdID = reference.info?.id
        let copies = all.filter { $0.info?.id == householdID }
        guard householdID != nil else {
            var none = HearthHouseholdSnapshot.empty
            none.adoptedAt = reference.adoptedAt
            return none
        }
        var info: HearthHouseholdInfo?
        var byID: [String: HearthMember] = [:]
        var deleted: [String: Date] = [:]
        var isShared = false
        for copy in copies {
            if let candidate = copy.info {
                // Newest wins, but each app's share link stays whichever copy has it.
                var newer = candidate.updatedAt > (info?.updatedAt ?? .distantPast) ? candidate : (info ?? candidate)
                let older = newer == candidate ? info : candidate
                for (app, url) in older?.appShareURLs ?? [:] where newer.appShareURLs[app] == nil { newer.appShareURLs[app] = url }
                newer.keepNewerMealTimes(from: older)
                info = newer
            }
            for member in copy.members {
                guard let existing = byID[member.id] else {
                    byID[member.id] = member
                    continue
                }
                // Newest wins, but every app's link to them stays.
                var newer = member.updatedAt > existing.updatedAt ? member : existing
                let older = member.updatedAt > existing.updatedAt ? existing : member
                for (app, id) in older.appIDs where newer.appIDs[app] == nil { newer.appIDs[app] = id }
                byID[member.id] = newer
            }
            for (id, date) in copy.deleted where date > (deleted[id] ?? .distantPast) {
                deleted[id] = date
            }
            isShared = isShared || copy.isShared
        }
        for (id, date) in deleted where (byID[id]?.updatedAt ?? .distantPast) < date {
            byID[id] = nil
        }
        let members = byID.values.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        return HearthHouseholdSnapshot(info: info, members: members, deleted: deleted, isShared: isShared, adoptedAt: reference.adoptedAt)
    }

    /// Every app's copy on this device, merged.
    static func onDevice() -> HearthHouseholdSnapshot {
        merged(Hearth.readAll(HearthHouseholdSnapshot.self).map(\.value))
    }

    /// What an AI request needs and nothing more: ages and roles (no names, no birthdays),
    /// and the food rules. Built on the device; the server uses it once and keeps nothing.
    func aiContext(on date: Date = .now) -> HearthAIContext {
        func clean(_ lists: [[String]]) -> [String] {
            var seen = Set<String>()
            return lists.flatMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        let people = self.people
        return HearthAIContext(
            people: people.map { HearthAIContext.Person(age: $0.age(on: date), role: $0.role.rawValue) },
            allergies: clean(people.map(\.allergies)),
            restrictions: clean([info?.restrictions ?? []] + people.map(\.diet)),
            likes: Array(clean(people.map(\.likes)).prefix(40)),
            dislikes: Array(clean(people.map(\.dislikes)).prefix(40))
        )
    }
}

/// The household as an AI request sees it. See `HearthHouseholdSnapshot.aiContext`.
nonisolated struct HearthAIContext: Codable, Hashable, Sendable {
    nonisolated struct Person: Codable, Hashable, Sendable {
        var age: Int?
        /// "parent", "adult" or "kid".
        var role: String
    }

    var people: [Person]
    /// Hard rules: never in a suggestion.
    var allergies: [String]
    /// Diets and household rules.
    var restrictions: [String]
    var likes: [String]
    var dislikes: [String]
}

// MARK: - Photos

nonisolated enum HearthHouseholdPhotos {
    /// Saves a person's photo (any image data; scaled to a JPEG of at most 512 px) to the shared
    /// photos folder and returns its file name. The name changes with the photo, so every app's
    /// cache sees the new one.
    static func save(_ data: Data, memberID: String) -> String? {
        guard let folder = Hearth.photosDirectory,
              let jpeg = jpeg(from: data) else { return nil }
        let name = "household-\(memberID)-\(fingerprint(jpeg)).jpg"
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            do {
                try jpeg.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                return nil
            }
        } else {
            // Chosen again: it's in use from now, so no app's cleanup takes it.
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path(percentEncoded: false))
        }
        return name
    }

    /// Stores a photo downloaded from iCloud under the name it was uploaded with.
    static func store(_ data: Data, name: String) -> String? {
        guard name.hasPrefix("household-"), !name.contains("/"), let folder = Hearth.photosDirectory else { return nil }
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return nil
        }
        return name
    }

    /// Removes household photos no one uses any more, once they're a day old (one app may have
    /// saved a photo another app hasn't heard about yet).
    static func clean(keeping names: Set<String>, now: Date = .now) {
        guard let folder = Hearth.photosDirectory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        for file in files where file.hasPrefix("household-") && !names.contains(file) {
            let url = folder.appending(path: file, directoryHint: .notDirectory)
            let made = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(made) > 86_400 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func jpeg(from data: Data, maxSide: CGFloat = 512) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.82)
    }

    /// A short, stable fingerprint of the bytes (FNV-1a), for file names.
    private static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
