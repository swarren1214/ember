import SwiftUI

/// The household step of every Hearth app's onboarding. Every app works inside a household
/// (a household of one is fine), so this sets one up, joins the family's, or, when another
/// Hearth app on this device already has one, just says so.
///
/// Put it in the app's onboarding with `onContinue` moving to the next step. It never lets the
/// person continue without a household: "Not Now" starts a household of just them, and says
/// where Household is in this app for when they're ready to add their family or join theirs.
extension View {
    /// Every Hearth app works inside a household: once the app's own onboarding is done
    /// (`isActive`), anyone without one gets the household step over everything until they
    /// have one.
    func hearthHouseholdRequired(isActive: Bool, accent: Color) -> some View {
        modifier(HearthHouseholdRequirement(isActive: isActive, accent: accent))
    }
}

private struct HearthHouseholdRequirement: ViewModifier {
    var isActive: Bool
    var accent: Color
    @State private var store = HearthHouseholdStore.shared
    /// Stays up after the household exists, until the person taps Continue, so they see what
    /// happened (and, after Not Now, where to find Household later).
    @State private var presented = false

    private var needed: Bool { isActive && store.hasLoaded && !store.exists }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $presented) {
                HearthHouseholdOnboarding(accent: accent) { presented = false }
                    .interactiveDismissDisabled()
            }
            .onChange(of: needed, initial: true) { _, needed in
                if needed { presented = true }
            }
    }
}

struct HearthHouseholdOnboarding: View {
    var accent: Color
    var onContinue: () -> Void
    @State private var store = HearthHouseholdStore.shared
    @State private var showsSetup = false
    @State private var waitsForInvite = false
    /// They chose Not Now: a household of just them was started for them.
    @State private var setUpLater = false
    /// They set one up, or joined one, on this screen. Otherwise a household that's here was
    /// made in another Hearth app, and this step just shows it.
    @State private var actedHere = false
    @State private var showsHousehold = false
    /// They tapped Join on an invitation here: the join card stays, showing "You're in".
    @State private var joinedByInvite = false

    /// Another Hearth app already made the household: show it, nothing to type.
    private var isFound: Bool { store.exists && !actedHere }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if joinedByInvite || store.pendingInvite != nil {
                    // The join sheet can't show over this screen, so the same card is here.
                    HearthJoinView(accent: accent, isInline: true, onJoin: {
                        joinedByInvite = true
                        actedHere = true
                    }, onFinish: {
                        joinedByInvite = false
                    })
                    .padding(20)
                    .background(Color(.secondarySystemBackground).opacity(0.5), in: .rect(cornerRadius: 22))
                } else if isFound {
                    foundCard
                } else if store.exists {
                    if setUpLater { laterCard } else { joinedCard }
                } else if waitsForInvite {
                    HearthJoinWaitingView(accent: accent) { waitsForInvite = false }
                } else {
                    explainer
                    choices
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if isFound {
                VStack(spacing: 6) {
                    Button(action: onContinue) {
                        Text("Looks Right")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(accent)
                    Button("Edit Household") { showsHousehold = true }
                        .font(.body.weight(.medium))
                        .tint(.primary)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 520)
            } else if store.exists {
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(accent)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 520)
            } else if store.pendingInvite == nil && !waitsForInvite && !joinedByInvite {
                Button(action: startJustMe) {
                    Text("Not Now")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glass)
                .disabled(!store.hasLoaded || store.isWorking)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 520)
            }
        }
        .sheet(isPresented: $showsSetup) {
            NavigationStack {
                HearthHouseholdSetupView(accent: accent)
                    .navigationTitle("Your Household")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            SheetCancelButton { showsSetup = false }
                        }
                    }
            }
            .tint(accent)
        }
        .sheet(isPresented: $showsHousehold) {
            NavigationStack {
                HearthHouseholdView(accent: accent)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            SheetDoneButton { showsHousehold = false }
                        }
                    }
            }
            .tint(accent)
        }
        .onChange(of: store.exists) { _, exists in
            if exists { showsSetup = false }
        }
        .onChange(of: showsSetup) { _, shows in
            if shows { actedHere = true }
        }
        .onChange(of: waitsForInvite) { _, waits in
            if waits { actedHere = true }
        }
        .animation(.smooth, value: store.exists)
        .animation(.smooth, value: waitsForInvite)
        .onAppear { HearthJoinPresentation.shared.inlineScreens += 1 }
        .onDisappear { HearthJoinPresentation.shared.inlineScreens -= 1 }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HearthLogo(size: 76)
                .padding(.bottom, 2)
            Text(isFound ? "Your household is already here" : "Your Household")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(isFound
                 ? "You set it up in \(foundSource.map(\.displayName) ?? "another Hearth app"). \(store.app.displayName) uses the same people, so there’s nothing to type."
                 : "\(store.app.displayName) is one of the Hearth apps for family life. Your household is who you share them with, set up once for all of them.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ForEach(HearthAppInfo.order, id: \.self) { app in
                    HearthAppIcon(app: app, size: app == store.app ? 38 : 30)
                        .opacity(app == store.app ? 1 : 0.85)
                }
            }
            .padding(.top, 2)
            .accessibilityHidden(true)
        }
    }

    /// Not Now: a household of just this person, so the app works, set up properly later.
    /// Their name comes from another Hearth app on this device when one knows it.
    private func startJustMe() {
        let mine = HearthHouseholdPlanner.sources().filter { HearthHouseholdPlanner.meSourceIDs().contains($0.id) }
        var me = mine.isEmpty
            ? HearthMember(name: "Me", role: .parent, colorHex: HearthPalette.colors[5].hex)
            : HearthHouseholdPlanner.member(from: mine, sortOrder: 0)
        me.role = .parent
        let first = mine.isEmpty ? "" : me.firstName
        actedHere = true
        setUpLater = true
        store.create(
            name: first.isEmpty ? "My Household" : "\(first)'s Household",
            members: [me],
            organizerID: me.id
        )
    }

    /// Where Household is in each app, for "when you're ready".
    static func householdLocation(in app: HearthApp) -> String {
        // Every app's main screens have the profile photo at the top right (HearthProfile.swift).
        "tap your photo at the top right, then Household"
    }

    private var laterCard: some View {
        VStack(spacing: 16) {
            Image(systemName: HearthHouseholdLabel.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(accent, in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Set Up Later")
                    .font(.title3.bold())
                Text("For now your household is just you, so everything in \(store.app.displayName) works.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("When you’re ready")
                    .font(.headline)
                Text("To add your family or join their household, \(Self.householdLocation(in: store.app)).")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can do it from any Hearth app, and only once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.14), in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    /// What a household is for, before asking for one.
    private var explainer: some View {
        VStack(alignment: .leading, spacing: 16) {
            point(symbol: HearthHouseholdLabel.symbol, title: "In \(store.app.displayName)", detail: Self.purpose(in: store.app))
            point(symbol: "square.stack.3d.up", title: "The same people in every app", detail: "Add someone once and BigTable, Suffice, Sated, Caloma and Hearken all know them. Change them anywhere and it changes everywhere.")
            point(symbol: "envelope", title: "One invitation", detail: "Invite your family once. They join in every Hearth app they use.")
            point(symbol: "lock", title: "Private to your family", detail: "Birthdays, allergies and diets are encrypted in your family’s iCloud, not on Hearth’s servers.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    /// What the household does in this app, from the person's side.
    static func purpose(in app: HearthApp) -> String {
        switch app {
        case .bigtable: "Plan meals around everyone’s tastes and allergies, and share recipes, the plan and the grocery list."
        case .suffice: "Share the budget with your partner and see who made each purchase."
        case .sated: "The coach keeps your household’s allergies and diets, and your own likes, in mind."
        case .caloma: "Chores, rewards and the family calendar, for each person in it."
        case .hearken: "Your reading stays yours, and Caloma can show whose reading is whose on the family calendar."
        case .trove: "Keep each person’s passport, license and birth certificate together, and share the family’s papers with the other adults."
        case .ember: "Ember knows who’s who, so “the kids” and “my wife” mean the right people in every answer."
        }
    }

    private func point(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var joinedCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: -10) {
                ForEach(store.people.prefix(6)) { person in
                    HearthMemberAvatar(member: person, size: 44, ring: true)
                }
            }
            Text(store.info?.name ?? "Your household")
                .font(.title3.bold())
            Text(store.people.count == 1 ? "Just you for now. Add people or invite your family any time in Household." : "\(store.people.count) people. Change anyone any time in Household.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    /// The Hearth app the household most likely came from: the first other app that knows
    /// someone in it, else the first other one installed.
    private var foundSource: HearthApp? {
        let others = HearthApp.allCases.filter { $0 != store.app }
        if let known = others.first(where: { app in store.people.contains { $0.appIDs[app.rawValue] != nil } }) { return known }
        let installed = HearthInstalledApps.current(including: store.app)
        return others.first { installed.contains($0) }
    }

    /// Another Hearth app already made the household: where it came from, and who's in it.
    private var foundCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                if let source = foundSource {
                    HearthAppIcon(app: source, size: 40)
                        .clipShape(.rect(cornerRadius: 9, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(foundSource.map { "From \($0.displayName)" } ?? (store.info?.name ?? "Your household"))
                        .font(.headline)
                    Text("\(store.people.count == 1 ? "1 person" : "\(store.people.count) people"), with birthdays, photos and allergies")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(accent.opacity(0.16), in: .rect(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)

            VStack(spacing: 0) {
                ForEach(store.people.filter { !$0.isArchived }) { person in
                    if person.id != store.people.first(where: { !$0.isArchived })?.id {
                        Divider().padding(.leading, 68)
                    }
                    HStack(spacing: 12) {
                        HearthMemberAvatar(member: person, size: 40, ring: false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.trimmedName).font(.headline)
                            Text(person.id == store.me?.id ? "You · \(person.role.label)" : person.role.label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let allergy = person.allergies.first {
                            Text(person.allergies.count > 1 ? "\(allergy) +\(person.allergies.count - 1)" : allergy)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(red: 1, green: 0.71, blue: 0.67))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.16), in: .capsule)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22, style: .continuous))

            Text(Self.purpose(in: store.app))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get Started")
                .font(.title3.bold())
                .padding(.top, 8)
            choice(symbol: "house.fill", title: "Set Up My Household", detail: "Just you is fine. Add family now or later.") {
                showsSetup = true
            }
            choice(symbol: "envelope.open.fill", title: "Join My Family’s Household", detail: "Someone already set one up in a Hearth app. Join theirs instead of starting another.") {
                waitsForInvite = true
            }
        }
    }

    private func choice(symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(accent, in: .rect(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

/// The Hearth mark (Assets.xcassets/Hearth/hearth, light and dark), with a symbol if the asset
/// is missing.
struct HearthLogo: View {
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let image = UIImage(named: "Hearth/hearth") {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "flame.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Hearth")
    }
}
