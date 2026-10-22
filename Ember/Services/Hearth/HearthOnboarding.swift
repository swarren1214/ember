// HearthOnboarding.swift — the pieces every Hearth app's first-run onboarding is built from, in
// the dark style of the Hearth Onboarding canvas: the page (step dots, icon, title, a line under
// it, the step's content, buttons pinned at the bottom), option cards, chips, toggle and value
// rows, the All Set summary, and the last page every flow ends on, Better with Hearth.
//
// Canonical copy: ~/Developer/hearthkit/HearthOnboarding.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthShared.swift,
// HearthApps.swift (`HearthApp`, its info, `HearthAppIcon`, `HearthInstalledApps`),
// HearthTour.swift and HearthHouseholdViews.swift (`HearthFlowLayout`).
//
// Using it
// - The app keeps its own steps and state; each step is a `HearthOnboardingPage`:
//
//       HearthOnboardingPage(app: .sated, step: (2, 5), symbol: "target",
//                            title: "What’s your goal?", subtitle: "Pick one…") {
//           HearthOnboardingOption("Eat healthier", detail: "…", isSelected: goal == .healthy) { goal = .healthy }
//       } controls: {
//           HearthOnboardingButtons(app: .sated, primary: "Continue", action: next,
//                                   secondary: "Skip", secondaryAction: next)
//       }
//
//   Put the whole flow in `.hearthOnboardingStyle(.sated)` (black, dark, the app's tint).
// - The household step is `HearthHouseholdOnboarding` (HearthHouseholdOnboarding.swift).
// - Every flow ends with All Set (`HearthOnboardingSummaryRow`s), then
//   `HearthOnboardingAppsPage`, whose Show Me Around and Jump In call `HearthOnboarding.finish`.

import SwiftUI
import UIKit

// MARK: - Finishing

@MainActor
enum HearthOnboarding {
    /// Ends onboarding. The tour won't show its own Welcome afterwards (onboarding already
    /// welcomed them); with `tour`, it starts at its first step once the tabs are up. Remembered
    /// in iCloud too, so this person's other devices skip onboarding (`isDoneOnAnotherDevice`).
    static func finish(_ app: HearthApp, tour: Bool) {
        UserDefaults.standard.set(true, forKey: HearthTour.doneKey(for: app))
        NSUbiquitousKeyValueStore.default.set(true, forKey: HearthTour.doneKey(for: app))
        rememberInCloud(app)
        if tour { HearthTour.shared.start(skippingWelcome: true, after: .milliseconds(700)) }
    }

    // MARK: Done on another device

    // Onboarding asks once per person, not once per device: finishing it is kept in iCloud
    // key-value storage (the app needs Signing & Capabilities › iCloud › Key-value storage), so
    // their iPad skips it after their iPhone did. What the family set up (the household, the
    // kitchen, the family's settings) is the app's to check; this is only the person.
    //
    // At the root, for a device that hasn't onboarded:
    //
    //     if await HearthOnboarding.waitForOtherDevices(.sated) { onboardingDone = true }
    //
    // and once onboarded (also for people who onboarded before this existed):
    //
    //     HearthOnboarding.rememberInCloud(.sated)

    /// Where "this person finished onboarding" is kept in iCloud key-value storage.
    nonisolated static func cloudKey(for app: HearthApp) -> String { "hearth.onboarded.\(app.rawValue)" }

    /// Says in iCloud that this person has been through onboarding. Cheap to call at every launch.
    static func rememberInCloud(_ app: HearthApp) {
        let cloud = NSUbiquitousKeyValueStore.default
        guard !cloud.bool(forKey: cloudKey(for: app)) else { return }
        cloud.set(true, forKey: cloudKey(for: app))
        cloud.synchronize()
    }

    /// Erase <App> Data: onboarding and the tour show again, on this device and the next.
    static func forgetInCloud(_ app: HearthApp) {
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.removeObject(forKey: cloudKey(for: app))
        cloud.removeObject(forKey: HearthTour.doneKey(for: app))
        cloud.synchronize()
    }

    /// This person finished onboarding on another of their devices.
    static func isDoneOnAnotherDevice(_ app: HearthApp) -> Bool {
        NSUbiquitousKeyValueStore.default.bool(forKey: cloudKey(for: app))
    }

    /// A new install: gives iCloud up to `timeout` to say this person already onboarded on
    /// another device. True when they did. No iCloud account answers false at once.
    static func waitForOtherDevices(_ app: HearthApp, timeout: Duration = .seconds(4)) async -> Bool {
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.synchronize()
        if isDoneOnAnotherDevice(app) { return true }
        guard FileManager.default.ubiquityIdentityToken != nil else { return false }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return false }
            if isDoneOnAnotherDevice(app) { return true }
        }
        return false
    }

    /// Onboarding skipped on this device because it's already done (another device, or the
    /// family's): no tour Welcome either, when they've seen it elsewhere.
    static func finishWithoutSteps(_ app: HearthApp) {
        rememberInCloud(app)
        if NSUbiquitousKeyValueStore.default.bool(forKey: HearthTour.doneKey(for: app)) {
            UserDefaults.standard.set(true, forKey: HearthTour.doneKey(for: app))
        }
    }

    /// The app's deep color: buttons and selections, readable under white text.
    static func ink(_ app: HearthApp) -> Color { color(app.info.inkHex) }
    /// The app's bright color: icons and accents on the black ground.
    static func lite(_ app: HearthApp) -> Color { color(app.info.liteHex) }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// The onboarding look: black, Dark Mode, the app's deep color as the tint.
    func hearthOnboardingStyle(_ app: HearthApp) -> some View {
        self
            .background(Color.black.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .tint(HearthOnboarding.ink(app))
    }
}

// MARK: - The page

/// One onboarding screen: step dots, the app's icon (the welcome) or a symbol in a tile, a large
/// title, a line under it, the step's content in a readable column, and the buttons pinned to
/// the bottom. A soft glow of the app's color sits behind the top.
struct HearthOnboardingPage<Content: View, Controls: View>: View {
    let app: HearthApp
    /// "2 of 5" dots; nil hides them (the welcome, All Set, Better with Hearth).
    var step: (number: Int, of: Int)?
    /// An SF Symbol in a tile; nil shows the app's icon (the welcome).
    var symbol: String?
    /// No icon at all (Better with Hearth, where the list needs the room).
    var showsIcon = true
    let title: String
    let subtitle: String
    let content: Content
    let controls: Controls

    init(
        app: HearthApp,
        step: (number: Int, of: Int)? = nil,
        symbol: String? = nil,
        showsIcon: Bool = true,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder controls: () -> Controls
    ) {
        self.app = app
        self.step = step
        self.symbol = symbol
        self.showsIcon = showsIcon
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.controls = controls()
    }

    @State private var height: CGFloat = 900
    private var isShort: Bool { height < 760 }
    static var columnWidth: CGFloat { 460 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if let step {
                        HearthOnboardingDots(app: app, number: step.number, of: step.of)
                            .padding(.bottom, isShort ? 12 : 18)
                    }
                    if showsIcon { icon }
                    Text(title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .padding(.top, showsIcon ? (isShort ? 12 : 18) : 0)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .padding(.top, 8)
                    VStack(spacing: 14) {
                        content
                    }
                    .padding(.top, isShort ? 20 : 26)
                }
                .padding(.horizontal, 28)
                .padding(.top, isShort ? 24 : (step == nil ? 56 : 32))
                .padding(.bottom, 24)
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 8) {
                controls
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: Self.columnWidth)
        }
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            RadialGradient(colors: [app.info.color.opacity(0.38), .clear], center: .center, startRadius: 0, endRadius: 260)
                .frame(width: 560, height: 520)
                .offset(y: -260)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .background(Color.black)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: isShort ? 28 : 34, weight: .medium))
                .foregroundStyle(HearthOnboarding.lite(app))
                .frame(width: isShort ? 60 : 72, height: isShort ? 60 : 72)
                .background(app.info.color.opacity(0.2), in: .rect(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
        } else {
            let size: CGFloat = isShort ? 76 : 92
            HearthAppIcon(app: app, size: size)
                .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
                .shadow(color: app.info.color.opacity(0.45), radius: 15, y: 12)
        }
    }
}

/// "Step 2 of 5": a long dash for this step, short dots for the others.
struct HearthOnboardingDots: View {
    let app: HearthApp
    let number: Int
    let of: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(of, 1), id: \.self) { index in
                Capsule()
                    .fill(index == number ? HearthOnboarding.ink(app) : Color(white: 0.28))
                    .frame(width: index == number ? 20 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number) of \(of)")
    }
}

// MARK: - Buttons

/// The pinned buttons: the step's main action in the app's color, and an optional quieter one
/// (Skip, Not Now) under it, plus an optional small line.
struct HearthOnboardingButtons: View {
    let app: HearthApp
    var primary: String?
    var action: (() -> Void)?
    var secondary: String?
    var secondaryAction: (() -> Void)?
    var footnote: String?
    var isWorking = false

    init(
        app: HearthApp,
        primary: String? = nil,
        action: (() -> Void)? = nil,
        secondary: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        footnote: String? = nil,
        isWorking: Bool = false
    ) {
        self.app = app
        self.primary = primary
        self.action = action
        self.secondary = secondary
        self.secondaryAction = secondaryAction
        self.footnote = footnote
        self.isWorking = isWorking
    }

    var body: some View {
        VStack(spacing: 6) {
            if let primary, let action {
                Button(action: action) {
                    Group {
                        if isWorking { ProgressView() } else { Text(primary) }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(HearthOnboarding.ink(app))
                .controlSize(.large)
                .disabled(isWorking)
                .keyboardShortcut(.defaultAction)
            }
            if let secondary, let secondaryAction {
                Button(secondary, action: secondaryAction)
                    .font(.body.weight(.medium))
                    .tint(Color.primary)
                    .frame(minHeight: 44)
                    .disabled(isWorking)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
    }
}

// MARK: - Content pieces

/// Three things the app does, on the welcome.
struct HearthOnboardingFeature: View {
    let app: HearthApp
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(HearthOnboarding.lite(app))
                .frame(width: 44, height: 44)
                .background(app.info.color.opacity(0.2), in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One choice of several (a radio card): selected, it takes a wash and an edge of the app's color.
struct HearthOnboardingOption: View {
    let title: String
    var detail: String?
    let isSelected: Bool
    let action: () -> Void

    init(_ title: String, detail: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                ZStack {
                    if isSelected {
                        Circle().fill(.tint)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(Color(white: 0.3), lineWidth: 2)
                    }
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color(.secondarySystemBackground)), in: .rect(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}

/// Chips to tap on and off (tastes, kinds of documents, places), wrapping and centered.
struct HearthOnboardingChips: View {
    let options: [String]
    @Binding var selection: Set<String>
    /// Only one at a time (a daily goal, a layout).
    var single = false

    var body: some View {
        HearthFlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let on = selection.contains(option)
                Button {
                    if single {
                        selection = [option]
                    } else if on {
                        selection.remove(option)
                    } else {
                        selection.insert(option)
                    }
                } label: {
                    Text(option)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 40)
                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemBackground)), in: .capsule)
                        .overlay(Capsule().strokeBorder(on ? .clear : Color(white: 0.22)))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A grouped card of rows (toggles, values, times), as in Settings.
struct HearthOnboardingCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group(subviews: content) { subviews in
            VStack(spacing: 0) {
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id {
                        Divider().padding(.leading, 16)
                    }
                    subview
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }
}

/// A row's two lines: a title and an optional smaller line under it.
struct HearthOnboardingRowLabel: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A small centered line under a step's content.
struct HearthOnboardingNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
    }
}

/// One line of All Set: a check, what's done, and a smaller line under it.
struct HearthOnboardingSummaryRow: View {
    let app: HearthApp
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(HearthOnboarding.lite(app))
                .frame(width: 30, height: 30)
                .background(app.info.color.opacity(0.2), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Better with Hearth

/// The last page of every app's onboarding: the other Hearth apps, what each does, and what it
/// does together with this one (`HearthAppInfo.connections`), with Open or Get; then Show Me
/// Around (the tour) or Jump In.
struct HearthOnboardingAppsPage: View {
    let app: HearthApp
    /// Ends onboarding; true starts the tour.
    let finish: (_ tour: Bool) -> Void
    /// Jump In's title ("Start Reading" in Hearken).
    var jumpInTitle = "Jump In"

    init(app: HearthApp, finish: @escaping (_ tour: Bool) -> Void, jumpInTitle: String = "Jump In") {
        self.app = app
        self.jumpInTitle = jumpInTitle
        self.finish = finish
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var installed: Set<HearthApp> = []

    private var others: [HearthApp] {
        let all = HearthApp.allCases.filter { $0 != app }
        // The ones that already do something with this app first.
        return all.sorted { together($0) != nil && together($1) == nil }
    }

    /// What `other` does with this app, from the person's side.
    private func together(_ other: HearthApp) -> String? {
        HearthAppInfo.connections(involving: app).first { $0.partner(of: app) == other }?.detail
    }

    var body: some View {
        HearthOnboardingPage(
            app: app,
            showsIcon: false,
            title: "Better with Hearth",
            subtitle: "One household, one sign-in, and Hearth+ covers every app."
        ) {
            VStack(spacing: 0) {
                ForEach(others, id: \.self) { other in
                    if other != others.first { Divider().padding(.leading, 70) }
                    row(other)
                }
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22, style: .continuous))
        } controls: {
            HearthOnboardingButtons(
                app: app,
                primary: "Show Me Around", action: { finish(true) },
                secondary: jumpInTitle, secondaryAction: { finish(false) }
            )
        }
        .task { installed = HearthInstalledApps.current(including: app) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { installed = HearthInstalledApps.current(including: app) }
        }
    }

    private func row(_ other: HearthApp) -> some View {
        let info = other.info
        let isInstalled = installed.contains(other)
        return HStack(alignment: .top, spacing: 12) {
            HearthAppIcon(app: other, size: 44)
                .clipShape(.rect(cornerRadius: 44 * 0.225, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(other.displayName).font(.headline)
                Text(info.tagline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let together = together(other) {
                    Label {
                        Text(together)
                    } icon: {
                        Image(systemName: "link")
                    }
                    .font(.footnote)
                    .foregroundStyle(HearthOnboarding.lite(app))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Button {
                if isInstalled, let url = info.openURL {
                    openURL(url)
                } else {
                    openURL(info.getURL)
                }
            } label: {
                Text(isInstalled ? "Open" : (info.isOnAppStore ? "Get" : "Beta"))
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.primary)
            .accessibilityLabel(isInstalled ? "Open \(other.displayName)" : "Get \(other.displayName)")
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
