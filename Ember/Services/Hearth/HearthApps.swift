// HearthApps.swift — the "Hearth Apps" page every Hearth app shows: what each app does, how it
// works with the one you're in, and a way to open or get the others.
//
// Canonical copy: ~/Developer/hearthkit/HearthApps.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthShared.swift (for
// `HearthApp`) and the icons in Assets.xcassets › Hearth, which sync.sh copies too.
//
// Using it
// - Push `HearthAppsView(current: .<app>)` from Settings or Profile, with
//   `HearthAppsRowLabel(current: .<app>)` as the row's label.
// - Each app's Info.plist lists the other apps' URL schemes under LSApplicationQueriesSchemes,
//   so the page can tell which are installed and offer Open instead of Get.
//
// Keeping it true
// - `HearthAppInfo.availability`: when an app leaves TestFlight, switch it to `.appStore`.
// - `HearthAppInfo.connections` lists what the apps do for each other, one entry per thing:
//   which app shares, which app uses it, and a title and a line. Add an entry when a new one
//   ships (only what has shipped). The page groups them by app and keeps long lists short, so
//   the list can grow without redesigning the page. Pairs with nothing specific fall back to
//   what they share through the Hearth sign-in (`signInLine`).

import SwiftUI
import UIKit

// MARK: - The catalog

nonisolated struct HearthAppInfo: Sendable {
    nonisolated enum Availability: Sendable {
        case appStore(URL)
        case testFlight(URL)
    }

    nonisolated struct Feature: Sendable, Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    let app: HearthApp
    /// "Meal planning & groceries".
    let category: String
    /// One line for lists.
    let tagline: String
    let headline: String
    let blurb: String
    let features: [Feature]
    let platforms: String
    let note: String?
    /// The app's own URL scheme, used to open it and to tell whether it's installed.
    let scheme: String
    let availability: Availability
    /// SF Symbol for when the icon image is missing.
    let symbol: String
    let colorHex: UInt32
    /// Text and tints on light backgrounds.
    let inkHex: UInt32
    /// Text and tints on dark backgrounds.
    let liteHex: UInt32

    var openURL: URL? { URL(string: "\(scheme)://") }

    var getURL: URL {
        switch availability {
        case .appStore(let url), .testFlight(let url): url
        }
    }

    var isOnAppStore: Bool {
        if case .appStore = availability { return true }
        return false
    }

    static func info(for app: HearthApp) -> HearthAppInfo {
        switch app {
        case .bigtable: bigtable
        case .suffice: suffice
        case .sated: sated
        case .caloma: caloma
        case .hearken: hearken
        case .trove: trove
        case .ember: ember
        }
    }

    /// The apps in the order the family is always shown. Trove joins the page once it has a
    /// public TestFlight (add it here and give it a `.testFlight` link).
    /// Ember joins the same way once it has a public TestFlight.
    static let order: [HearthApp] = [.bigtable, .suffice, .sated, .caloma, .hearken]

    // MARK: Together

    /// One thing two apps do for each other: `from` shares something, `to` uses it. `twoWay`
    /// when each app reads the other (meal times kept in step in both, say).
    nonisolated struct Connection: Sendable, Identifiable, Hashable {
        let from: HearthApp
        let to: HearthApp
        var twoWay = false
        let symbol: String
        /// Short, as a feature name: "Tonight’s dinner".
        let title: String
        /// One sentence, from the person's side.
        let detail: String

        var id: String { "\(from.rawValue)>\(to.rawValue):\(title)" }
        var apps: Set<HearthApp> { [from, to] }

        func involves(_ app: HearthApp) -> Bool { from == app || to == app }

        /// The other app in it, seen from `app`.
        func partner(of app: HearthApp) -> HearthApp { from == app ? to : from }

        /// "BigTable → Caloma", or "BigTable ⇄ Caloma" both ways.
        var direction: String {
            "\(from.displayName) \(twoWay ? "⇄" : "→") \(to.displayName)"
        }
    }

    /// Everything the apps do for each other today. Add to it as things ship; the page keeps up.
    static let connections: [Connection] = [
        Connection(from: .bigtable, to: .caloma, symbol: "fork.knife", title: "Tonight’s dinner",
                   detail: "What BigTable has planned for dinner shows on Caloma’s Home, on the family calendar, and in its widget and watch app."),
        Connection(from: .bigtable, to: .caloma, twoWay: true, symbol: "clock", title: "Meal times in step",
                   detail: "Breakfast, lunch and dinner happen at the same times in both, so the calendar and the meal plan agree."),
        Connection(from: .caloma, to: .bigtable, symbol: "person.2", title: "Your household, ready",
                   detail: "BigTable can set up your household from Caloma’s family, so you don’t type everyone in twice."),
        Connection(from: .bigtable, to: .sated, symbol: "fork.knife", title: "Log what you planned",
                   detail: "Pick a meal from BigTable’s plan in Sated’s Add Food, with the nutrition worked out from the recipe."),
        Connection(from: .caloma, to: .suffice, symbol: "person.2", title: "Your household, ready",
                   detail: "Suffice can fill in who’s budgeting from Caloma’s family, photos included."),
        Connection(from: .caloma, to: .hearken, twoWay: true, symbol: "person.crop.circle.badge.checkmark", title: "Continue as you",
                   detail: "Sign in with Apple in one and the other offers to continue as you, photo and all."),
    ]

    /// What `a` and `b` do for each other, most specific first.
    static func connections(between a: HearthApp, _ b: HearthApp) -> [Connection] {
        connections.filter { $0.apps == [a, b] }
    }

    /// Everything `app` does with the others.
    static func connections(involving app: HearthApp) -> [Connection] {
        connections.filter { $0.involves(app) }
    }

    /// What two apps share through the Hearth sign-in, for pairs with nothing more specific.
    static func signInLine(_ a: HearthApp, _ b: HearthApp) -> String {
        // BigTable, Suffice and Sated share the account session; Caloma and Hearken share the
        // Apple identity. Across the two, the name (and photo) still carries over.
        let session: Set<HearthApp> = [.bigtable, .suffice, .sated]
        if session.contains(a) && session.contains(b) {
            return "One sign-in covers both, so there’s nothing new to set up."
        }
        let identity: Set<HearthApp> = [.caloma, .hearken]
        if identity.contains(a) && identity.contains(b) {
            return "Sign in with Apple in one and the other offers to continue as you."
        }
        return "Sign in with Apple in one and the other already knows your name."
    }

    /// One line about a pair, for places with room for only one.
    static func together(_ a: HearthApp, _ b: HearthApp) -> String {
        connections(between: a, b).first?.detail ?? signInLine(a, b)
    }

    // MARK: The apps

    private static let bigtable = HearthAppInfo(
        app: .bigtable,
        category: "Meal planning & groceries",
        tagline: "Meal plans and grocery lists for big families.",
        headline: "Feed the whole crew. Without the 5 p.m. panic.",
        blurb: "Plan breakfast, lunch and dinner for the week around everyone’s likes, dislikes and allergies, then turn the plan into a grocery list sorted by aisle. The whole household plans together.",
        features: [
            Feature(symbol: "sparkles", title: "Plan My Week", detail: "Describe the week you want and get a full plan to preview before it lands."),
            Feature(symbol: "cart", title: "Lists by aisle", detail: "Generate groceries for any date range, check items off as you shop, and share the list."),
            Feature(symbol: "text.viewfinder", title: "Recipes in, any way", detail: "Say it, type it, scan a cookbook page or paste a link. Servings scale for you."),
            Feature(symbol: "person.3", title: "The household, together", detail: "Invite family and set who can edit the plan."),
        ],
        platforms: "iPhone · iPad",
        note: "Free, with BigTable Plus for more. BigTable uses an account so everyone in your household sees the same plan.",
        scheme: "bigtable",
        availability: .appStore(URL(string: "https://apps.apple.com/us/app/bigtable/id6772788255")!),
        symbol: "fork.knife",
        colorHex: 0xD9472B, inkHex: 0xC0391F, liteHex: 0xFF8466
    )

    private static let suffice = HearthAppInfo(
        app: .suffice,
        category: "Household budget",
        tagline: "A household budget you share with your partner.",
        headline: "Money talk, minus the tension.",
        blurb: "See every account’s cash at a glance, every transaction with who made it, budgets with subcategories, and the bills coming due, shared between partners through your own iCloud.",
        features: [
            Feature(symbol: "chart.pie", title: "Budgets as rings", detail: "Plan a month, split it into subcategories, and see what’s left at a glance."),
            Feature(symbol: "calendar.badge.clock", title: "Bills that remind", detail: "Due this week, subscriptions and overdue. Mark paid and it files itself."),
            Feature(symbol: "bubble.left.and.text.bubble.right", title: "Ask Suffice", detail: "“How much did we spend eating out?” Answered on your iPhone."),
            Feature(symbol: "faceid", title: "Locked with Face ID", detail: "Amounts hide on the Lock Screen. Export to CSV whenever you like."),
        ],
        platforms: "iPhone · Apple Watch",
        note: "Free while in beta. No account needed.",
        scheme: "suffice",
        availability: .testFlight(URL(string: "https://testflight.apple.com/join/eNu3hBJ6")!),
        symbol: "wallet.bifold",
        colorHex: 0x1E9E6A, inkHex: 0x167A52, liteHex: 0x45D69B
    )

    private static let sated = HearthAppInfo(
        app: .sated,
        category: "Calories & macros",
        tagline: "Calories and macros, logged in seconds.",
        headline: "Know what you ate. Not just guess.",
        blurb: "Track calories, protein, carbs, fat and fiber with a 13,000-food library that works offline, a barcode scanner, and a label reader. A coach that lives on your iPhone answers with your real numbers.",
        features: [
            Feature(symbol: "mic", title: "Say It", detail: "“Two eggs and toast.” Sated splits it into foods and amounts, and you confirm."),
            Feature(symbol: "barcode.viewfinder", title: "Scan labels & barcodes", detail: "The label reader runs on the device and flags numbers that don’t add up."),
            Feature(symbol: "sparkles", title: "A private coach", detail: "Ask what to eat for dinner and log the suggestion with one tap."),
            Feature(symbol: "chart.bar", title: "Day, week, month", detail: "Summaries from your exact log, plus widgets and Apple Health."),
        ],
        platforms: "iPhone · iPad · Apple Watch",
        note: "Free while in beta. No account needed.",
        scheme: "sated",
        availability: .testFlight(URL(string: "https://testflight.apple.com/join/pp2V9MdA")!),
        symbol: "leaf",
        colorHex: 0xDA8300, inkHex: 0x9C5D00, liteHex: 0xFFB442
    )

    private static let caloma = HearthAppInfo(
        app: .caloma,
        category: "Chores, rewards & the family calendar",
        tagline: "Chores, rewards, the calendar and the house.",
        headline: "A house that runs itself. Almost.",
        blurb: "Kids’ chores with rewards your family designs, a shared calendar that knows who’s driving and what to bring, and the home care jobs that come around every few months, shared between both parents’ iCloud.",
        features: [
            Feature(symbol: "checkmark.circle", title: "Chores kids want to do", detail: "A ring for each kid, and a celebration when it closes."),
            Feature(symbol: "gift", title: "Rewards you choose", detail: "Privileges, experiences, money or items, plus a family goal everyone saves toward."),
            Feature(symbol: "calendar", title: "The family calendar", detail: "Who’s going, who’s driving, what to pack, and a get-ready chore the night before."),
            Feature(symbol: "wrench.and.screwdriver", title: "Home care, on schedule", detail: "Filters, smoke detectors, the dryer vent. Hand any job to a kid as a chore."),
        ],
        platforms: "iPhone · iPad · Apple Watch",
        note: "Free while in beta. No account needed.",
        scheme: "caloma",
        availability: .testFlight(URL(string: "https://testflight.apple.com/join/QDje8vqM")!),
        symbol: "house",
        colorHex: 0xE0284F, inkHex: 0xC21E43, liteHex: 0xFF6F8E
    )

    private static let hearken = HearthAppInfo(
        app: .hearken,
        category: "Scripture study",
        tagline: "Scripture study that helps you remember.",
        headline: "Read with purpose. Remember what you learn.",
        blurb: "Seven subjects with mastery meters, short games that use spaced repetition, a library of readings, and a reader made for highlighting and notes.",
        features: [
            Feature(symbol: "highlighter", title: "A reader for marking up", detail: "Highlight in your own color legend, underline, or add a note inline."),
            Feature(symbol: "rosette", title: "Mastery you can see", detail: "Rings and tiers for every subject and unit, earned through recall."),
            Feature(symbol: "gamecontroller", title: "Games that teach", detail: "Daily Challenge, Chronology, Unit Checks and Spaced Review."),
            Feature(symbol: "hand.raised", title: "No ads. No tracking.", detail: "Sign in with Apple is optional. Every feature works without it."),
        ],
        platforms: "iPhone · iPad · Apple Watch",
        note: "Free while in beta. Hearken is an independent study app. It is not made, sponsored or endorsed by The Church of Jesus Christ of Latter-day Saints.",
        scheme: "hearken",
        availability: .testFlight(URL(string: "https://testflight.apple.com/join/bSxK5KSt")!),
        symbol: "book",
        colorHex: 0x0A7AFF, inkHex: 0x0060D6, liteHex: 0x5AA9FF
    )

    private static let trove = HearthAppInfo(
        app: .trove,
        category: "Important documents",
        tagline: "Your family’s important papers, and where the originals are.",
        headline: "Know where everything is. Before you need it.",
        blurb: "Passports, licenses, titles, warranties and policies, tied to the people and things they belong to. Trove keeps the scans, reminds you before anything expires, and remembers where the paper original is kept.",
        features: [
            Feature(symbol: "doc.viewfinder", title: "Scan once", detail: "Trove reads the type, owner and dates on your iPhone, and keeps the original photo."),
            Feature(symbol: "mappin.and.ellipse", title: "Where the original is", detail: "The fire safe, the safe deposit box, the attorney’s office. Never hunt for a birth certificate again."),
            Feature(symbol: "calendar.badge.exclamationmark", title: "Before it expires", detail: "Passports nine months ahead, registrations six weeks ahead, with what renewing takes."),
            Feature(symbol: "faceid", title: "Locked and private", detail: "Numbers stay hidden until Face ID. Everything is encrypted in your family’s iCloud."),
        ],
        platforms: "iPhone · iPad",
        note: "Coming soon. No account needed.",
        scheme: "trove",
        // Not on TestFlight yet: the page doesn't list Trove (see `order`).
        availability: .testFlight(URL(string: "https://hearthapps.com")!),
        symbol: "archivebox",
        colorHex: 0x38C2E9, inkHex: 0x0F7A9C, liteHex: 0x6FD6F2
    )

    private static let ember = HearthAppInfo(
        app: .ember,
        category: "Voice assistant",
        tagline: "Ask your household anything, out loud.",
        headline: "Everything your Hearth apps know, one question away.",
        blurb: "Ember answers from your meal plan, budget, family calendar and study plan, on your iPhone or straight from your Apple Watch. It thinks on your device first, and anything that does go to the cloud carries no names and nothing that identifies you.",
        features: [
            Feature(symbol: "waveform", title: "Just talk", detail: "Tap the orb and ask, or hold it while you speak. Ember answers out loud in a natural voice."),
            Feature(symbol: "square.stack.3d.up", title: "Knows your Hearth", detail: "Dinner, groceries, the budget, chores and the calendar, all in one answer."),
            Feature(symbol: "applewatch", title: "On your wrist", detail: "Ask from Apple Watch, with or without your iPhone nearby."),
            Feature(symbol: "lock.shield", title: "Private by design", detail: "On device first. The cloud never learns who you are."),
        ],
        platforms: "iPhone · Apple Watch",
        note: "Coming soon.",
        scheme: "ember",
        // Not on TestFlight yet: the page doesn't list Ember (see `order`).
        availability: .testFlight(URL(string: "https://hearthapps.com")!),
        symbol: "flame",
        colorHex: 0xEE5A1C, inkHex: 0xC2410C, liteHex: 0xFF9A5C
    )
}

nonisolated extension HearthApp {
    var info: HearthAppInfo { HearthAppInfo.info(for: self) }
}

// MARK: - Installed apps

enum HearthInstalledApps {
    /// The Hearth apps on this device. Needs the schemes in LSApplicationQueriesSchemes;
    /// without them every other app reads as not installed, which only means Get instead of Open.
    static func current(including app: HearthApp) -> Set<HearthApp> {
        var installed: Set<HearthApp> = [app]
        for other in HearthApp.allCases where other != app {
            if let url = other.info.openURL, UIApplication.shared.canOpenURL(url) {
                installed.insert(other)
            }
        }
        return installed
    }
}

// MARK: - Colors

nonisolated private func hearthUIColor(_ hex: UInt32) -> UIColor {
    UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

nonisolated private func hearthDynamicColor(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
        hearthUIColor(traits.userInterfaceStyle == .dark ? dark : light)
    })
}

nonisolated extension HearthAppInfo {
    var color: Color { Color(uiColor: hearthUIColor(colorHex)) }
    /// Readable text in the app's color, in light and dark.
    var ink: Color { hearthDynamicColor(light: inkHex, dark: liteHex) }
}

// MARK: - The page

struct HearthAppsView: View {
    /// The app showing the page.
    let current: HearthApp

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var installed: Set<HearthApp> = []
    @State private var selected: HearthAppSelection?
    @State private var showsAllElsewhere = false

    private var others: [HearthApp] { HearthAppInfo.order.filter { $0 != current } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                appsSection
                togetherSection
                elsewhereSection
                sharedSection
                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Hearth Apps")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .sheet(item: $selected) { selection in
            HearthAppSheet(app: selection.app, current: current, isInstalled: installed.contains(selection.app))
        }
    }

    private func refresh() {
        installed = HearthInstalledApps.current(including: current)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HearthMark()
                .frame(width: 58, height: 51)
            Text("Part of Hearth")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("Five apps.\nOne home.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("Each Hearth app takes on one hard, everyday part of running a home. Use the ones you need. They share a look and a sign-in, and the more you use, the more they help each other.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }

    // MARK: The apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("The Apps")
            VStack(spacing: 0) {
                ForEach(Array(([current] + others).enumerated()), id: \.element) { index, app in
                    if index > 0 { Divider().padding(.leading, 84) }
                    appRow(app)
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
            Text("Tap an app to see what it does.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
    }

    private func appRow(_ app: HearthApp) -> some View {
        let info = app.info
        return HStack(spacing: 10) {
            Button {
                selected = HearthAppSelection(app: app)
            } label: {
                HStack(spacing: 14) {
                    HearthAppIcon(app: app, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(info.tagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(app.displayName). \(info.tagline)")
            .accessibilityHint("Shows what \(app.displayName) does")

            if app == current {
                Text("You’re here")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            } else {
                actionPill(for: app)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
    }

    private func actionPill(for app: HearthApp) -> some View {
        let info = app.info
        let isInstalled = installed.contains(app)
        let title = isInstalled ? "Open" : (info.isOnAppStore ? "Get" : "Beta")
        let label = isInstalled
            ? "Open \(app.displayName)"
            : (info.isOnAppStore ? "Get \(app.displayName) on the App Store" : "Join the \(app.displayName) beta on TestFlight")
        return Button {
            if isInstalled, let url = info.openURL {
                openURL(url)
            } else {
                openURL(info.getURL)
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(minWidth: 68, minHeight: 32)
                .background(info.color.opacity(0.14), in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Together

    /// The other apps that do something with this one, in the family's order.
    private var partners: [HearthApp] {
        others.filter { !HearthAppInfo.connections(between: current, $0).isEmpty }
    }

    /// The other apps that only share the sign-in with this one so far.
    private var signInOnly: [HearthApp] {
        others.filter { HearthAppInfo.connections(between: current, $0).isEmpty }
    }

    /// What the other apps do for each other, without this one.
    private var elsewhere: [HearthAppInfo.Connection] {
        HearthAppInfo.connections.filter { !$0.involves(current) }
    }

    private var togetherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Better with \(current.displayName)")
                Text("What changes when \(current.displayName) has company.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            ForEach(partners, id: \.self) { app in
                partnerCard(app)
            }
            if !signInOnly.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(signInOnly.enumerated()), id: \.element) { index, app in
                        if index > 0 { Divider().padding(.leading, 70) }
                        HStack(alignment: .top, spacing: 14) {
                            pairIcons(current, app, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("With \(app.displayName)")
                                    .font(.subheadline.weight(.semibold))
                                Text(HearthAppInfo.signInLine(current, app))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
            }
        }
    }

    /// One app and everything it does with this one.
    private func partnerCard(_ app: HearthApp) -> some View {
        let info = app.info
        let items = HearthAppInfo.connections(between: current, app)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                selected = HearthAppSelection(app: app)
            } label: {
                HStack(spacing: 14) {
                    pairIcons(current, app, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("With \(app.displayName)")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(items.count == 1 ? "1 thing together" : "\(items.count) things together")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what \(app.displayName) does")

            Divider().padding(.leading, 16)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(items) { item in
                    connectionRow(item, tint: info.ink, showsDirection: false)
                }
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
    }

    private func connectionRow(_ item: HearthAppInfo.Connection, tint: Color, showsDirection: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsDirection {
                    Text(item.direction)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .accessibilityLabel(item.twoWay
                            ? "Between \(item.from.displayName) and \(item.to.displayName)"
                            : "From \(item.from.displayName) to \(item.to.displayName)")
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Two app icons overlapped, the second in front.
    private func pairIcons(_ a: HearthApp, _ b: HearthApp, size: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HearthAppIcon(app: a, size: size)
            HearthAppIcon(app: b, size: size)
                .padding(2.5)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: size * 0.225 + 2.5, style: .continuous))
                .offset(x: size * 0.4, y: 1)
        }
        .frame(width: size * 1.4 + 5, height: size + 6, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    // MARK: Across the family

    /// How many of the other apps' connections show before "Show All".
    private let elsewherePreview = 3

    @ViewBuilder
    private var elsewhereSection: some View {
        if !elsewhere.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Across Your Hearth Apps")
                    Text("What the other apps do for each other.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
                let shown = showsAllElsewhere ? elsewhere : Array(elsewhere.prefix(elsewherePreview))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 70) }
                        HStack(alignment: .top, spacing: 14) {
                            pairIcons(item.from, item.to, size: 30)
                            connectionText(item)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .accessibilityElement(children: .combine)
                    }
                    if elsewhere.count > elsewherePreview {
                        Divider()
                        Button {
                            withAnimation(.snappy) { showsAllElsewhere.toggle() }
                        } label: {
                            HStack {
                                Text(showsAllElsewhere ? "Show Less" : "Show All \(elsewhere.count)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: showsAllElsewhere ? "chevron.up" : "chevron.down")
                                    .font(.footnote.weight(.bold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private func connectionText(_ item: HearthAppInfo.Connection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.direction)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.subheadline.weight(.semibold))
            Text(item.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Shared

    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("In Every Hearth App")
            sharedCard(symbol: "person.crop.circle", title: "One sign-in", text: "Sign in once and your other Hearth apps pick it up. The apps that don’t need an account work without one.")
            sharedCard(symbol: "photo.on.rectangle", title: "Your people, everywhere", text: "Add someone’s photo in one app and it shows up in the others.")
            sharedCard(symbol: "lock", title: "Private by design", text: "Suffice, Sated, Caloma and Hearken keep your information on your devices and in your private iCloud. BigTable uses an account so your household can plan together. No ads, no tracking, nothing sold.")
        }
    }

    private func sharedCard(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HearthMark()
                .frame(width: 30, height: 26)
            Link("hearthapps.com", destination: URL(string: "https://hearthapps.com")!)
                .font(.subheadline.weight(.semibold))
                .tint(.primary)
            Text("Hearken is an independent study app. It is not made, sponsored or endorsed by The Church of Jesus Christ of Latter-day Saints.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title2.bold())
            .padding(.horizontal, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct HearthAppSelection: Identifiable {
    let app: HearthApp
    var id: String { app.rawValue }
}

// MARK: - One app

struct HearthAppSheet: View {
    let app: HearthApp
    /// The app showing the sheet.
    let current: HearthApp
    let isInstalled: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var info: HearthAppInfo { app.info }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 10) {
                        HearthAppIcon(app: app, size: 96)
                            .shadow(color: info.color.opacity(0.3), radius: 14, y: 8)
                        Text(app.displayName)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .padding(.top, 4)
                        Text(info.category)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                    action

                    VStack(alignment: .leading, spacing: 8) {
                        Text(info.headline)
                            .font(.title3.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        Text(info.blurb)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(info.features.enumerated()), id: \.element.id) { index, feature in
                            if index > 0 { Divider().padding(.leading, 52) }
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: feature.symbol)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title).font(.headline)
                                    Text(feature.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))

                    if app != current {
                        withCurrent
                    }
                    alsoWorksWith

                    VStack(spacing: 6) {
                        Text(info.platforms)
                            .font(.footnote.weight(.semibold))
                        if let note = info.note {
                            Text(note)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// Everything this app does with the one showing the sheet.
    private var withCurrent: some View {
        let items = HearthAppInfo.connections(between: current, app)
        return VStack(alignment: .leading, spacing: 12) {
            Text("With \(current.displayName)")
                .font(.footnote.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text(HearthAppInfo.signInLine(current, app))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.title, systemImage: item.symbol)
                            .font(.subheadline.weight(.semibold))
                        Text(item.detail)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(info.color.opacity(0.12), in: .rect(cornerRadius: 20, style: .continuous))
    }

    /// What this app does with the rest of the family (not the one showing the sheet).
    @ViewBuilder
    private var alsoWorksWith: some View {
        let items = HearthAppInfo.connections(involving: app).filter { !$0.involves(current) || app == current }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(app == current ? "Works With" : "Also Works With")
                    .font(.footnote.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        HearthAppIcon(app: item.partner(of: app), size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.partner(of: app).displayName): \(item.title)")
                                .font(.subheadline.weight(.semibold))
                            Text(item.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder
    private var action: some View {
        if app == current {
            Text("You’re using \(app.displayName)")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 50)
        } else {
            VStack(spacing: 8) {
                Button {
                    if isInstalled, let url = info.openURL {
                        openURL(url)
                    } else {
                        openURL(info.getURL)
                    }
                } label: {
                    Text(isInstalled ? "Open \(app.displayName)" : (info.isOnAppStore ? "Get on the App Store" : "Join the TestFlight Beta"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(info.color)
                if !isInstalled && !info.isOnAppStore {
                    Text("Betas install through Apple’s free TestFlight app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Settings row

/// The label for the row that opens `HearthAppsView`: the other apps' icons, fanned, with a title
/// and a line about them. Put it inside a NavigationLink in the app's own row style.
struct HearthAppsRowLabel: View {
    let current: HearthApp

    private var others: [HearthApp] { HearthAppInfo.order.filter { $0 != current } }

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .leading) {
                ForEach(Array(others.enumerated()), id: \.element) { index, app in
                    HearthAppIcon(app: app, size: 30)
                        .padding(2)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 30 * 0.225 + 2, style: .continuous))
                        .offset(x: CGFloat(index) * 13)
                }
            }
            .frame(width: 34 + CGFloat(max(others.count - 1, 0)) * 13, height: 34, alignment: .leading)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hearth Apps")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("\(others.count) more apps that work with \(current.displayName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Icons and the mark

/// An app's icon from Assets › Hearth (light and dark, from Developer/app-icons), or a tile in its
/// color when the image is missing.
struct HearthAppIcon: View {
    let app: HearthApp
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let image = UIImage(named: "Hearth/\(app.rawValue)") {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: app.info.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(app.info.color, in: .rect(cornerRadius: size * 0.225, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The Hearth flame: five overlapping petals, one in each app's color.
struct HearthMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 64, size.height / 56)
            context.translateBy(x: (size.width - 64 * scale) / 2, y: (size.height - 56 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            for petal in Self.petals {
                var layer = context
                layer.translateBy(x: 32, y: 52)
                layer.rotate(by: .degrees(petal.angle))
                layer.translateBy(x: -32, y: -52)
                layer.fill(petal.path, with: .color(Color(uiColor: hearthUIColor(petal.hex)).opacity(petal.opacity)))
            }
        }
        .aspectRatio(64.0 / 56.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    nonisolated private struct Petal: Sendable {
        let path: Path
        let angle: Double
        let hex: UInt32
        let opacity: Double
    }

    nonisolated private static let petals: [Petal] = [
        Petal(path: small, angle: -38, hex: 0x1E9E6A, opacity: 0.85),
        Petal(path: small, angle: 38, hex: 0x0A7AFF, opacity: 0.85),
        Petal(path: medium, angle: -19, hex: 0xE0284F, opacity: 0.85),
        Petal(path: medium, angle: 19, hex: 0xDA8300, opacity: 0.85),
        Petal(path: large, angle: 0, hex: 0xD9472B, opacity: 0.88),
    ]

    nonisolated private static let small = petal(tip: 28, (41.5, 42.4), (37.89, 52), (26.11, 52), (22.5, 42.4))
    nonisolated private static let medium = petal(tip: 19, (43, 38.8), (38.82, 52), (25.18, 52), (21, 38.8))
    nonisolated private static let large = petal(tip: 8, (45, 33), (40, 52), (24, 52), (19, 33))

    nonisolated private static func petal(
        tip: CGFloat,
        _ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat),
        _ c: (CGFloat, CGFloat), _ d: (CGFloat, CGFloat)
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 32, y: tip))
        path.addCurve(to: CGPoint(x: 32, y: 52), control1: CGPoint(x: a.0, y: a.1), control2: CGPoint(x: b.0, y: b.1))
        path.addCurve(to: CGPoint(x: 32, y: tip), control1: CGPoint(x: c.0, y: c.1), control2: CGPoint(x: d.0, y: d.1))
        path.closeSubpath()
        return path
    }
}

#Preview("Hearth Apps") {
    NavigationStack {
        HearthAppsView(current: .suffice)
    }
}

#Preview("App sheet") {
    HearthAppSheet(app: .caloma, current: .bigtable, isInstalled: false)
}
