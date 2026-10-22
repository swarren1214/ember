// HearthHouseholdSetup.swift — first-time setup: the household made from the people the Hearth
// apps on this device already have (each app's `HearthFamily` in the app group), with the
// organizer confirming who's who.
//
// Canonical copy: ~/Developer/hearthkit/HearthHouseholdSetup.swift (run sync.sh after editing).

import SwiftUI
import UIKit

// MARK: - Matching

nonisolated enum HearthHouseholdPlanner {
    /// One person as one app knows them.
    nonisolated struct Source: Identifiable, Hashable, Sendable {
        var app: HearthApp
        var member: HearthFamily.Member
        var id: String { app.rawValue + ":" + member.id }
        var key: String { HearthNames.normalized(member.name) }
    }

    /// People the planner thinks are the same person. `together` false keeps them apart.
    nonisolated struct Group: Identifiable, Hashable, Sendable {
        var id: String
        var sources: [Source]
        var together = true
    }

    /// Everyone every app on this device has shared, apps in a fixed order.
    static func sources() -> [Source] {
        let order: [HearthApp] = [.caloma, .bigtable, .suffice, .hearken, .sated]
        let families = Hearth.readAll(HearthFamily.self)
        return order.flatMap { app -> [Source] in
            guard let family = families.first(where: { $0.app == app })?.value else { return [] }
            return family.members
                .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { Source(app: app, member: $0) }
        }
    }

    /// Same full name: the same person, even when one app lists them twice (the account owner
    /// and a family member). A lone first name joins the one full name it starts (when exactly
    /// one does); otherwise each app appears at most once per person.
    static func groups(_ sources: [Source]) -> [Group] {
        var groups: [Group] = []
        func place(_ source: Source, allowSameApp: Bool = false, where matches: (Group) -> Bool) -> Bool {
            let candidates = groups.indices.filter { matches(groups[$0]) && (allowSameApp || !groups[$0].sources.contains { $0.app == source.app }) }
            guard candidates.count == 1, let index = candidates.first else { return false }
            groups[index].sources.append(source)
            return true
        }
        for source in sources {
            if place(source, allowSameApp: true, where: { $0.sources.contains { $0.key == source.key } }) { continue }
            let first = HearthNames.firstName(source.key)
            let isLoneFirstName = !source.key.contains(" ")
            if place(source, where: { group in
                group.sources.contains { other in
                    let otherFirst = HearthNames.firstName(other.key)
                    return otherFirst == first && (isLoneFirstName || !other.key.contains(" "))
                }
            }) { continue }
            groups.append(Group(id: source.id, sources: [source]))
        }
        return groups
    }

    /// The household name an app already uses, if any.
    static func householdName() -> String? {
        Hearth.readAll(HearthFamily.self)
            .compactMap { $0.value.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Household-wide food rules from any app (BigTable's dietary restrictions).
    static func restrictions() -> [String] {
        var seen = Set<String>()
        return Hearth.readAll(HearthFamily.self)
            .flatMap { $0.value.dietaryRestrictions ?? [] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Who "me" is in any app, as a source id.
    static func meSourceIDs() -> Set<String> {
        Set(Hearth.readAll(HearthFamily.self).compactMap { envelope in
            envelope.value.me.map { envelope.app.rawValue + ":" + $0 }
        })
    }

    /// One household member from a group: Caloma's name, role and color first, then BigTable's
    /// birthday, likes and dislikes; the first photo any app has.
    static func member(from sources: [Source], sortOrder: Int, now: Date = .now) -> HearthMember {
        let ordered = sources.sorted { rank($0.app) < rank($1.app) }
        let name = ordered.first?.member.name ?? ""
        let birthday = ordered.compactMap(\.member.birthday).first
        let roleText = ordered.compactMap(\.member.role).first
        var role: HearthRole = switch roleText {
        case "kid": .kid
        case "adult": .adult
        default: .parent
        }
        if roleText == nil, let birthday, let date = HearthDay.date(from: birthday),
           let age = Calendar.current.dateComponents([.year], from: date, to: now).year {
            role = age < 18 ? .kid : .parent
        }
        let color = ordered.compactMap(\.member.colorHex).first.map { HearthPalette.nearest(to: $0).hex }
            ?? HearthPalette.colors[(sortOrder + 5) % HearthPalette.colors.count].hex
        func union(_ lists: [[String]?]) -> [String] {
            var seen = Set<String>()
            return lists.compactMap { $0 }.flatMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        let id = UUID().uuidString
        var photo: String?
        for source in ordered {
            if let file = source.member.photo, let data = Hearth.photo(named: file) {
                photo = HearthHouseholdPhotos.save(data, memberID: id)
                if photo != nil { break }
            }
        }
        var appIDs: [String: String] = [:]
        // One id per app: the first, when an app listed them twice.
        for source in ordered where appIDs[source.app.rawValue] == nil { appIDs[source.app.rawValue] = source.member.id }
        return HearthMember(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role,
            colorHex: color,
            photo: photo,
            birthday: birthday,
            likes: union(ordered.map(\.member.likes)),
            dislikes: union(ordered.map(\.member.dislikes)),
            appIDs: appIDs,
            sortOrder: sortOrder,
            updatedAt: now
        )
    }

    private static func rank(_ app: HearthApp) -> Int {
        switch app {
        case .caloma: 0
        case .bigtable: 1
        case .suffice: 2
        case .hearken: 3
        case .sated: 4
        case .trove: 5
        case .ember: 6
        }
    }
}

// MARK: - The setup screen

/// "One household for every app": shows who the apps on this device already know, suggests who's
/// the same person, and creates the household. With nobody to start from, it starts with you.
struct HearthHouseholdSetupView: View {
    var accent: Color
    @State private var store = HearthHouseholdStore.shared
    @State private var groups: [HearthHouseholdPlanner.Group] = []
    @State private var name = ""
    @State private var myName = ""
    @State private var loaded = false

    private var matches: [Int] { groups.indices.filter { groups[$0].sources.count > 1 } }
    private var singles: [Int] { groups.indices.filter { groups[$0].sources.count == 1 } }

    /// People who'll be created: a split group counts once per app.
    private var peopleCount: Int {
        groups.reduce(0) { $0 + ($1.together ? 1 : $1.sources.count) } + (groups.isEmpty && !myName.isEmpty ? 1 : 0)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(HearthApp.allCases, id: \.self) { app in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Self.color(app))
                                .frame(width: 28, height: 28)
                        }
                    }
                    .accessibilityHidden(true)
                    Text("One household for every app")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(groups.isEmpty
                         ? "Add your family once, and every Hearth app will use the same people, photos and allergies."
                         : "Your Hearth apps each have your family. Check who's who once, and every app will use the same people.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section("Household Name") {
                TextField("The Warrens", text: $name)
                    .textInputAutocapitalization(.words)
            }

            if groups.isEmpty {
                Section("You") {
                    TextField("Your name", text: $myName)
                        .textInputAutocapitalization(.words)
                }
            }

            if !matches.isEmpty {
                Section("These look like the same people") {
                    ForEach(matches, id: \.self) { index in
                        matchRow(index)
                    }
                }
            }

            if !singles.isEmpty {
                Section("Only in one app") {
                    ForEach(singles, id: \.self) { index in
                        let source = groups[index].sources[0]
                        HStack(spacing: 12) {
                            Circle().fill(Self.color(source.app)).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.member.name).font(.body.weight(.semibold))
                                Text("From \(source.app.displayName)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    create()
                } label: {
                    Text("Create Household · \(peopleCount) \(peopleCount == 1 ? "person" : "people")")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(accent)
                .disabled(peopleCount == 0)
                .listRowBackground(Color.clear)
            } footer: {
                Text("Saved to your iCloud, then shared with your family when you invite them. Nothing in your apps changes until you tap Create.")
            }
        }
        .onAppear(perform: load)
    }

    private func matchRow(_ index: Int) -> some View {
        let group = groups[index]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.sources) { source in
                        HStack(spacing: 8) {
                            Circle().fill(Self.color(source.app)).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(source.member.name).font(.body.weight(.semibold))
                            Text(source.app.displayName).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                Toggle("Same person", isOn: $groups[index].together)
                    .labelsHidden()
            }
            Text(group.together ? "One person in every app" : "Kept as \(group.sources.count) different people")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        groups = HearthHouseholdPlanner.groups(HearthHouseholdPlanner.sources())
        name = HearthHouseholdPlanner.householdName() ?? ""
    }

    private func create() {
        var members: [HearthMember] = []
        let meIDs = HearthHouseholdPlanner.meSourceIDs()
        var organizerID: String?
        for group in groups {
            let parts = group.together ? [group.sources] : group.sources.map { [$0] }
            for sources in parts {
                let member = HearthHouseholdPlanner.member(from: sources, sortOrder: members.count)
                if organizerID == nil, sources.contains(where: { meIDs.contains($0.id) }) { organizerID = member.id }
                members.append(member)
            }
        }
        if members.isEmpty {
            let me = HearthMember(name: myName.trimmingCharacters(in: .whitespacesAndNewlines), role: .parent, colorHex: HearthPalette.colors[5].hex)
            members = [me]
            organizerID = me.id
        }
        // Parents first, then kids, keeping each app's order.
        members = members.filter { $0.role != .kid } + members.filter { $0.role == .kid }
        let fallbackName = members.first.map { "\($0.firstName)'s Household" } ?? "Our Household"
        let householdName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.create(
            name: householdName.isEmpty ? fallbackName : householdName,
            members: members,
            organizerID: organizerID ?? members.first(where: { $0.role == .parent })?.id,
            restrictions: HearthHouseholdPlanner.restrictions()
        )
    }

    static func color(_ app: HearthApp) -> Color {
        switch app {
        case .bigtable: Color(red: 0.88, green: 0.31, blue: 0.23)
        case .suffice: Color(red: 0.23, green: 0.49, blue: 0.20)
        case .sated: Color(red: 0.94, green: 0.54, blue: 0.14)
        case .caloma: Color(red: 0.85, green: 0.34, blue: 0.48)
        case .hearken: Color(red: 0.23, green: 0.45, blue: 0.85)
        case .trove: Color(red: 0.12, green: 0.43, blue: 0.38)
        case .ember: Color(red: 0.95, green: 0.42, blue: 0.13)
        }
    }
}
