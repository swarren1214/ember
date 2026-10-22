// HearthProfile.swift — the one Profile screen every Hearth app shows, and the profile photo at
// the top right of every main screen that opens it.
//
// Canonical copy: ~/Developer/hearthkit/HearthProfile.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthShared.swift,
// HearthApps.swift, HearthTour.swift, HearthAccount.swift, HearthSync.swift, HearthHouseholdViews.swift and
// HearthPaywall.swift, plus each app's DesignSystem/SheetButtons.swift (`SheetDoneButton`).
// Design: the HearthKit Profile canvas.
//
// The screen, top to bottom
//   Profile (large white title over the app's color header)
//   Hearth account: signed in, a Liquid Glass card (photo, name, how they signed in) that opens
//     the Hearth Account page with the app's own account section; signed out, that section
//     itself (Sign in with Apple)
//   Membership: the billing banner when a renewal failed, and Get / Manage Hearth+
//   Household and iCloud Sync (iCloud Sync opens the shared sync card)
//   Appearance: System, Light or Dark (Hearken's thumbnails), for every Hearth app
//   <the app's own settings sections>
//   Hearth Apps
//   Help & Feedback: Take the Tour, Send Feedback, Support, Rate <App>
//   Legal: Privacy Policy, Terms of Use
//   Your Data: the app's own rows (Export…), then Erase <App> Data with a native alert
//   The app's icon, name and version, and the app's own credits
//
// Using it
// - At the root (on the TabView), once:
//
//       RootTabView()
//           .hearthProfile { SatedProfileView() }
//
// - Appearance is applied by `.hearthProfile { }`. An app that shows Profile some other way
//   puts `.hearthAppearance()` on its root view instead. The choice is stored per device under
//   `HearthAppearance.key` ("settings.appearance"), so it isn't mirrored to iCloud.
//
// - On every main screen, the photo at the top right, always last in the trailing group:
//
//       ToolbarItemGroup(placement: .topBarTrailing) {
//           ...the screen's own buttons...
//           HearthProfileButton()
//       }
//
// - The app's profile view fills in the screen:
//
//       HearthProfileView(
//           app: .sated,
//           profile: account.profile,                         // nil when signed out
//           sync: HearthProfileSync(summary: "Your food log and goals") {
//               SyncMonitor.shared.snapshot
//           } syncNow: {
//               await SyncMonitor.shared.syncNow()
//           },
//           erase: HearthProfileErase(app: .sated, message: "This deletes…") {
//               await SatedDataEraser.eraseAll(in: context)
//           }
//       ) {
//           AccountSection()                                  // the app's Section with HearthAccountSection
//       } settings: {
//           Section("Sated") { ... HearthProfileRow ... }     // the app's own sections
//       } data: {
//           ShareLink(...)                                    // rows above Erase, or nothing
//       } about: {
//           Text("Credits…")                                  // lines under the version, or nothing
//       }
//
// - Rows in the app's sections: `HearthProfileRow` for the label (an icon in the text color,
//   the title, an optional value), inside the app's NavigationLink or Button. Toggles and
//   Pickers are fine as they are; give them `.tint(.primary)` where a menu would turn the app's
//   color.

import StoreKit
import SwiftUI
import UIKit

// MARK: - Presenting

/// Whether the Profile sheet is up. `HearthProfileButton` opens it; `.hearthProfile { }` on the
/// root view shows it.
@MainActor @Observable
final class HearthProfilePresenter {
    static let shared = HearthProfilePresenter()
    var isPresented = false

    func show() { isPresented = true }
    func dismiss() { isPresented = false }

    private init() {}
}

extension View {
    /// Shows the app's Profile as a sheet whenever `HearthProfileButton` is tapped. Put it on the
    /// root view (the TabView), once.
    func hearthProfile<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        modifier(HearthProfileSheet(profile: content))
    }
}

private struct HearthProfileSheet<Profile: View>: ViewModifier {
    let profile: () -> Profile
    @State private var presenter = HearthProfilePresenter.shared

    func body(content: Content) -> some View {
        @Bindable var presenter = presenter
        content
            .sheet(isPresented: $presenter.isPresented) {
                NavigationStack {
                    profile()
                }
            }
            .hearthAppearance()
    }
}

// MARK: - The photo at the top right

/// The person's photo (or initial) at the top right of every main screen, the same in every
/// Hearth app. Opens Profile. It's the household's photo of "me" (one photo per person across
/// the apps), so a new photo shows up here in every app at once.
///
/// Drawn as a live view, not an image: the toolbar repaints images in one flat color, which
/// would turn a photo into a plain white circle.
struct HearthProfileButton: View {
    /// Over the color header (white glyph when there's no one yet), or on a plain bar.
    var overHeader: Bool
    /// What tapping does; by default it opens the Profile sheet.
    var action: (() -> Void)?

    @State private var household = HearthHouseholdStore.shared

    init(overHeader: Bool = true, action: (() -> Void)? = nil) {
        self.overHeader = overHeader
        self.action = action
    }

    var body: some View {
        Button {
            if let action { action() } else { HearthProfilePresenter.shared.show() }
        } label: {
            HearthProfileAvatar(member: household.me, size: 30, glyph: overHeader ? .white : .primary)
        }
        .accessibilityLabel("Profile")
        .accessibilityHint(household.me.map { "Signed in as \($0.trimmedName)" } ?? "")
    }
}

/// The photo the profile button draws: the household photo of "me", their initial in their
/// color, or the person glyph when there's no one yet.
struct HearthProfileAvatar: View {
    var member: HearthMember?
    var size: CGFloat = 30
    var glyph: Color = .white

    var body: some View {
        if let member {
            HearthMemberAvatar(member: member, size: size, ring: false)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size * 0.9))
                .foregroundStyle(glyph)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Appearance

/// Profile › Appearance, the same in every Hearth app: follow the system, or always Light or
/// Dark. It belongs to this device (it isn't mirrored to iCloud).
nonisolated enum HearthAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    /// The UserDefaults key. Hearken and Sated already used it, so their choice carries over.
    static let key = "settings.appearance"

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Moves a choice an app stored under its own key (BigTable's "appearance.mode") to the
    /// shared key, once. Call before the first view reads it.
    static func adopt(legacyKey: String) {
        let defaults = UserDefaults.standard
        guard let old = defaults.string(forKey: legacyKey) else { return }
        if defaults.string(forKey: key) == nil, HearthAppearance(rawValue: old) != nil {
            defaults.set(old, forKey: key)
        }
        defaults.removeObject(forKey: legacyKey)
    }
}

extension View {
    /// Applies Profile › Appearance to every window of the app, so sheets and full-screen covers
    /// follow it too (preferredColorScheme only reaches the presentation it's applied to).
    /// `.hearthProfile { }` already does this; use it only where an app doesn't.
    func hearthAppearance() -> some View {
        modifier(HearthAppearanceApplier())
    }
}

private struct HearthAppearanceApplier: ViewModifier {
    @AppStorage(HearthAppearance.key) private var appearance: HearthAppearance = .system
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: appearance, initial: true) { _, option in
                Self.apply(option)
            }
            .onChange(of: scenePhase) { _, phase in
                // Windows made since (a new scene on iPad) pick it up too.
                if phase == .active { Self.apply(appearance) }
            }
    }

    private static func apply(_ option: HearthAppearance) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = option.interfaceStyle
            }
        }
    }
}

/// Three thumbnails (System, Light, Dark) with radio buttons. The ring and the selected radio
/// button take the tint (Profile gives it the app's color).
struct HearthAppearancePicker: View {
    @Binding var selection: HearthAppearance

    var body: some View {
        HStack(spacing: 12) {
            ForEach(HearthAppearance.allCases) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 8) {
                        HearthAppearanceThumbnail(option: option)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.separator)),
                                                  lineWidth: isSelected ? 3 : 0.5)
                            }
                        Text(option.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiaryLabel)))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A miniature screen: a title bar and two cards, in light, dark, or split for System.
private struct HearthAppearanceThumbnail: View {
    let option: HearthAppearance

    private struct Palette {
        let background: Color
        let card: Color
        let bar: Color
    }

    private static let light = Palette(background: Color(white: 0.95), card: .white, bar: Color(white: 0.82))
    private static let dark = Palette(background: Color(white: 0.11), card: Color(white: 0.23), bar: Color(white: 0.4))

    var body: some View {
        Group {
            switch option {
            case .light:
                screen(Self.light)
            case .dark:
                screen(Self.dark)
            case .system:
                screen(Self.light)
                    .overlay(alignment: .trailing) {
                        GeometryReader { proxy in
                            screen(Self.dark)
                                .mask(alignment: .trailing) {
                                    Rectangle().frame(width: proxy.size.width / 2)
                                }
                        }
                    }
            }
        }
        .frame(height: 120)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    private func screen(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Capsule().fill(palette.bar).frame(width: 46, height: 10)
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.card).frame(height: 32)
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.card).frame(height: 32)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background)
    }
}

// MARK: - Notices above everything

extension View {
    /// An OK-only notice raised by app-wide state (a sync notice, a finished import, joining a
    /// family), shown above whatever is on screen. A SwiftUI `.alert` only appears while the view
    /// it's on is frontmost, so one on the root waits, unseen, behind any open sheet (Profile
    /// included), full-screen cover or alert. This presents a native alert on the topmost screen.
    /// Use `.alert` as usual for confirmations the screen itself asks for.
    func hearthNotice(_ title: String, isPresented: Binding<Bool>, message: String? = nil) -> some View {
        modifier(HearthNoticeModifier(title: title, message: message, isPresented: isPresented))
    }
}

private struct HearthNoticeModifier: ViewModifier {
    let title: String
    let message: String?
    @Binding var isPresented: Bool
    @State private var shown: UIAlertController?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, show in
                if show {
                    present(attempt: 0)
                } else if let alert = shown {
                    shown = nil
                    alert.dismiss(animated: true)
                }
            }
    }

    private func present(attempt: Int) {
        guard isPresented, shown == nil else { return }
        // Something is mid-transition, or another alert is up: try again shortly.
        guard let top = HearthTopScreen.find(), !(top is UIAlertController),
              !top.isBeingPresented, !top.isBeingDismissed else {
            if attempt < 20 {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    present(attempt: attempt + 1)
                }
            }
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in
            shown = nil
            isPresented = false
        })
        shown = alert
        top.present(alert, animated: true)
    }
}

/// The screen on top of everything in the active window: the last sheet, cover or alert.
@MainActor
enum HearthTopScreen {
    static func find() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.keyWindow ?? scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}

// MARK: - What the app passes in

/// The iCloud Sync row and the page it opens. Leave it nil where the app doesn't sync with
/// iCloud.
struct HearthProfileSync {
    /// What syncs, as the start of a sentence: "Your food log and goals".
    var summary: String
    var sharing: HearthSyncSharing?
    /// Reads the app's current snapshot (from its observable sync monitor, so the row and the
    /// page follow it live).
    var snapshot: @MainActor () -> HearthSyncSnapshot
    var syncNow: () async -> Void

    init(
        summary: String,
        sharing: HearthSyncSharing? = nil,
        snapshot: @escaping @MainActor () -> HearthSyncSnapshot,
        syncNow: @escaping () async -> Void
    ) {
        self.summary = summary
        self.sharing = sharing
        self.snapshot = snapshot
        self.syncNow = syncNow
    }
}

/// The destructive row at the bottom: Erase <App> Data, or Leave Household where that's what
/// erasing means (a member's copy of shared data). Always confirmed with a native alert.
struct HearthProfileErase {
    var title: String
    /// The alert's title.
    var question: String
    /// The alert's message: what goes, and what stays.
    var message: String
    /// The alert's destructive button.
    var confirm: String
    /// Under the row.
    var footer: String?
    var symbol: String
    var action: () async -> Void

    init(
        app: HearthApp,
        title: String? = nil,
        question: String? = nil,
        message: String,
        confirm: String = "Erase",
        footer: String? = nil,
        symbol: String = "trash",
        action: @escaping () async -> Void
    ) {
        self.title = title ?? "Erase \(app.displayName) Data"
        self.question = question ?? "Erase \(app.displayName) Data?"
        self.message = message
        self.confirm = confirm
        self.footer = footer
        self.symbol = symbol
        // Erasing starts the app over: so does onboarding, here and on their other devices.
        // (An app that only leaves a shared household keeps its onboarding on this device, and
        // says so in iCloud again at its next launch.)
        self.action = {
            await action()
            await HearthOnboarding.forgetInCloud(app)
        }
    }
}

// MARK: - A row

/// A row's label in the app's own Profile sections: the icon in the text color (never the app's
/// color), the title, and an optional value on the right. Put it in a NavigationLink or Button.
struct HearthProfileRow: View {
    var title: String
    var systemImage: String
    var value: String?

    init(_ title: String, systemImage: String, value: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
    }

    var body: some View {
        LabeledContent {
            if let value, !value.isEmpty {
                Text(value)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - The screen

struct HearthProfileView<Account: View, Settings: View, DataRows: View, About: View>: View {
    let app: HearthApp
    /// Who's signed in; nil shows the app's account section (Sign in with Apple) at the top.
    let profile: HearthAccountProfile?
    var sync: HearthProfileSync?
    /// Starts an app's own tour. Leave it nil for the shared tour (HearthTour.swift), which
    /// Take the Tour runs on its own once the app has set it up.
    var tour: (() -> Void)?
    var erase: HearthProfileErase?
    let account: Account
    let settings: Settings
    let data: DataRows
    let about: About

    init(
        app: HearthApp,
        profile: HearthAccountProfile?,
        sync: HearthProfileSync? = nil,
        tour: (() -> Void)? = nil,
        erase: HearthProfileErase? = nil,
        @ViewBuilder account: () -> Account,
        @ViewBuilder settings: () -> Settings,
        @ViewBuilder data: () -> DataRows,
        @ViewBuilder about: () -> About
    ) {
        self.app = app
        self.profile = profile
        self.sync = sync
        self.tour = tour
        self.erase = erase
        self.account = account()
        self.settings = settings()
        self.data = data()
        self.about = about()
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @State private var showsAccount = false
    @State private var confirmsErase = false
    @State private var isErasing = false
    @AppStorage(HearthAppearance.key) private var appearance: HearthAppearance = .system

    private var info: HearthAppInfo { app.info }

    var body: some View {
        Form {
            Section {
                Text("Profile")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white.opacity(colorScheme == .light ? 0.88 : 1))
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            .listSectionSpacing(8)

            if let profile {
                Section {
                    accountCard(profile)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            } else {
                account
            }

            Section {
                HearthBillingBanner()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                HearthMembershipRow()
            }

            Section {
                NavigationLink {
                    HearthHouseholdView(accent: info.color)
                } label: {
                    HearthHouseholdLabel()
                }
                if let sync {
                    NavigationLink {
                        HearthProfileSyncPage(app: app, sync: sync)
                    } label: {
                        HearthProfileSyncLabel(sync: sync)
                    }
                }
            }
            .tint(.primary)

            Section {
                HearthAppearancePicker(selection: $appearance)
                    .tint(info.color)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows your \(UIDevice.current.localizedModel)'s Light and Dark setting, including scheduled switching.")
            }

            settings

            Section {
                NavigationLink {
                    HearthAppsView(current: app)
                } label: {
                    HearthAppsRowLabel(current: app)
                }
            }

            Section("Help & Feedback") {
                if let tour {
                    Button {
                        tour()
                    } label: {
                        HearthProfileRow("Take the Tour", systemImage: "play.circle")
                    }
                } else if !HearthTour.shared.steps.isEmpty {
                    // The shared tour (HearthTour.swift): close Profile, then show the app around.
                    Button {
                        dismiss()
                        HearthTour.shared.start(skippingWelcome: true, after: .milliseconds(600))
                    } label: {
                        HearthProfileRow("Take the Tour", systemImage: "play.circle")
                    }
                }
                Link(destination: feedbackURL) {
                    HearthProfileRow("Send Feedback", systemImage: "envelope")
                }
                Link(destination: HearthProfileLinks.support) {
                    HearthProfileRow("Support", systemImage: "questionmark.circle")
                }
                Button {
                    rate()
                } label: {
                    HearthProfileRow("Rate \(app.displayName)", systemImage: "star")
                }
            }
            .tint(.primary)

            Section("Legal") {
                Link(destination: HearthProfileLinks.privacy) {
                    HearthProfileRow("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: HearthProfileLinks.terms) {
                    HearthProfileRow("Terms of Use", systemImage: "doc.text")
                }
            }
            .tint(.primary)

            dataSection

            Section {
                footer
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(alignment: .top) { HearthProfileHeader(color: info.color) }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // The title is drawn large in the content, as on every color-header screen.
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            ToolbarItem(placement: .confirmationAction) {
                SheetDoneButton { dismiss() }
            }
        }
        .navigationDestination(isPresented: $showsAccount) {
            HearthProfileAccountPage(app: app) { account }
        }
        .alert(erase?.question ?? "", isPresented: $confirmsErase) {
            if let erase {
                Button(erase.confirm, role: .destructive) {
                    isErasing = true
                    Task {
                        await erase.action()
                        isErasing = false
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(erase?.message ?? "")
        }
    }

    // MARK: The account card

    /// Signed in: a Liquid Glass card over the color header, laid out top to bottom. It opens the
    /// Hearth Account page (the app's account section: its apps, Sign Out, Delete Account).
    private func accountCard(_ profile: HearthAccountProfile) -> some View {
        Button {
            showsAccount = true
        } label: {
            VStack(spacing: 4) {
                HearthAccountAvatar(app: app, profile: profile, size: 76)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 3))
                    .padding(.bottom, 8)
                Text(HearthAccountIdentity.name(profile) ?? "Your Hearth Account")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(profile.method)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HearthMemberBadge()
                    .padding(.top, 4)
                HStack(spacing: 6) {
                    Text("Hearth Account")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .padding(.bottom, 16)
            .padding(.horizontal, 16)
            .contentShape(.rect(cornerRadius: 28))
            .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hearth Account, \(HearthAccountIdentity.name(profile) ?? ""), \(profile.method)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Your Data

    @ViewBuilder
    private var dataSection: some View {
        if let erase {
            Section {
                data
                    .tint(.primary)
                Button(role: .destructive) {
                    confirmsErase = true
                } label: {
                    HStack {
                        // Red icon and text together: a destructive row's icon otherwise takes
                        // the app's tint instead of the red its title gets.
                        Label(erase.title, systemImage: erase.symbol)
                            .foregroundStyle(.red)
                        if isErasing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .tint(.red)
                .disabled(isErasing)
            } footer: {
                if let footer = erase.footer {
                    Text(footer)
                }
            }
        } else if DataRows.self != EmptyView.self {
            Section {
                data
                    .tint(.primary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            HearthAppIcon(app: app, size: 60)
                .clipShape(.rect(cornerRadius: 60 * 0.225, style: .continuous))
            Text(app.displayName)
                .font(.headline)
                .padding(.top, 4)
            Text("Version \(HearthProfileLinks.version)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("A Hearth app · Hearth Software LLC")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                about
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private var feedbackURL: URL {
        let subject = "\(app.displayName) \(HearthProfileLinks.version) Feedback"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(HearthProfileLinks.supportEmail)?subject=\(encoded)") ?? HearthProfileLinks.support
    }

    /// On the App Store, the review page; in a TestFlight beta, the system rating prompt (which
    /// TestFlight doesn't show, so nothing happens there).
    private func rate() {
        if case .appStore(let url) = info.availability,
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "action", value: "write-review")]
            if let review = parts.url {
                openURL(review)
                return
            }
        }
        requestReview()
    }
}

// MARK: - Pushed pages

/// Profile › Hearth Account: the app's own account section (its apps, account rows, Sign Out and
/// Delete Account). Signing out here brings back Sign in with Apple in place.
private struct HearthProfileAccountPage<Account: View>: View {
    let app: HearthApp
    let account: Account

    init(app: HearthApp, @ViewBuilder account: () -> Account) {
        self.app = app
        self.account = account()
    }

    var body: some View {
        Form {
            account
        }
        .navigationTitle("Hearth Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Profile › iCloud Sync: the shared sync card, live.
private struct HearthProfileSyncPage: View {
    let app: HearthApp
    let sync: HearthProfileSync

    var body: some View {
        Form {
            Section {
                HearthSyncCard(app: app, snapshot: sync.snapshot(), summary: sync.summary, sharing: sync.sharing) {
                    await sync.syncNow()
                }
                .hearthSyncCardRow()
            } footer: {
                Text("\(app.displayName) syncs on its own. Pull down on any screen to check for changes. Hearth’s servers never hold this data.")
            }
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The iCloud Sync row: a status dot and a word.
private struct HearthProfileSyncLabel: View {
    let sync: HearthProfileSync

    private var network: HearthNetworkStatus { .shared }

    var body: some View {
        let snapshot = sync.snapshot()
        let status = Self.status(snapshot, online: network.isOnline)
        LabeledContent {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(status.text)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label {
                Text("iCloud Sync").foregroundStyle(.primary)
            } icon: {
                Image(systemName: "icloud").foregroundStyle(.primary)
            }
        }
    }

    private static func status(_ snapshot: HearthSyncSnapshot, online: Bool) -> (text: String, color: Color) {
        switch snapshot.account {
        case .checking: return ("Checking", .gray)
        case .unavailable: return ("Off", .gray)
        case .available: break
        }
        if snapshot.isSyncing { return ("Syncing", .blue) }
        if snapshot.errorMessage != nil { return ("Couldn’t Sync", .red) }
        if !online || (snapshot.pendingChanges ?? 0) > 0 { return ("Waiting", .orange) }
        return ("Up to Date", .green)
    }
}

// MARK: - Header

/// The app's color across the top, fading into the gray, as on every main screen.
/// The app's color fading down from the top, behind a color-header screen's large white title
/// (Profile, Household).
struct HearthProfileHeader: View {
    let color: Color

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let curve: [(Double, Double)] = sizeClass == .compact
            ? [(0, 1), (0.3, 0.88), (0.6, 0.5), (0.85, 0.15), (1, 0)]
            : [(0, 1), (1, 0)]
        let end = color.mix(with: .white, by: 0.12)
        GeometryReader { geo in
            LinearGradient(
                stops: curve.map { Gradient.Stop(color: color.mix(with: end, by: $0.0).opacity($0.1), location: $0.0) },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: geo.size.width, height: geo.size.height * (sizeClass == .compact ? 0.5 : 0.4))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Links

enum HearthProfileLinks {
    static let support = URL(string: "https://hearthapps.com/support")!
    static let privacy = URL(string: "https://hearthapps.com/privacy")!
    static let terms = URL(string: "https://hearthapps.com/terms")!
    static let supportEmail = "support@hearthapps.com"

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
