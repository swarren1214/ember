// HearthPaywall.swift — the one paywall every Hearth app shows: Hearth+ (all five apps) or the
// app's own plan, and every state from loading to "you're a member". Plus the pieces that live
// outside it: the locked-feature card, the member badge, the billing banner, the Account row and
// the Hearth+ teaser for the apps working together. Drawn from the "Hearth Paywall" canvas.
//
// Canonical copy: ~/Developer/hearthkit/HearthPaywall.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthPurchases.swift,
// HearthShared.swift and HearthApps.swift (`HearthAppIcon`, colors).
//
// Using it
// - `.hearthPaywall(isPresented: $showsPaywall, feature: "Automatic bank sync")` on any view.
//   `startWith: .hearthPlus` opens on Hearth+ (it does by default); `.app` opens on the app's plan.
// - `HearthLockedCard(feature: …)` where a paid feature would be. It opens the paywall itself.
// - `HearthMemberBadge()` next to the signed-in person in Account; `HearthMembershipRow()` as a
//   row under it; `HearthBillingBanner()` at the top of the app's first tab.
// - `HearthPlusTeaser(…)` in an app that could show another app's data with Hearth+.

import RevenueCat
import SwiftUI

// MARK: - What's in each plan

/// One paid feature, as the locked card and the paywall name it.
nonisolated struct HearthPaywallFeature: Hashable, Sendable {
    var title: String
    var detail: String?
    var symbol: String?

    init(_ title: String, detail: String? = nil, symbol: String? = nil) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

nonisolated enum HearthPlanCopy {
    /// One line per app for the Hearth+ list.
    static func perk(_ app: HearthApp) -> String {
        switch app {
        case .bigtable: "AI meal plans and grocery lists, recipe scanning"
        case .suffice: "Automatic bank sync, Ask, debt payoff planner"
        case .sated: "Coach, label scanning, restaurant menus"
        case .caloma: "Wall display, Home Control and Home Care"
        case .hearken: "Listen, study groups and every game"
        case .trove: "Unlimited assets and the emergency packet"
        case .ember: "Cloud help for harder questions, from iPhone and Apple Watch"
        }
    }

    /// What the app's own plan includes.
    static func perks(_ app: HearthApp) -> [String] {
        switch app {
        case .bigtable: ["AI meal plans for the whole family", "AI grocery lists with cost estimates", "Scan recipes and import from any site"]
        case .suffice: ["Automatic bank sync", "Ask about your money, by text or voice", "Receipt splitting and a debt payoff plan"]
        case .sated: ["Coach, private on your device", "Scan nutrition labels and log by voice", "Restaurant menus and all-time trends"]
        case .caloma: ["The family wall display on iPad", "Home Control and Home Care", "The Pencil whiteboard"]
        case .hearken: ["Listen to any chapter", "Study groups and every game mode", "Import your own books and PDFs"]
        case .trove: ["Unlimited homes, vehicles and other assets", "The emergency packet for someone you trust", "Custom reminder times for every document"]
        case .ember: ["Cloud help for planning and harder questions", "Ask from Apple Watch without your iPhone", "De-identified: the cloud never learns who you are"]
        }
    }

    static let headline = "Your whole home, in one place."
    static let pitch = "Meals, money, health, family and faith. Five apps that work together, for everyone at home."

    /// "Plan Thursday tacos" → … the apps working together, top to bottom.
    static let flow: [(app: HearthApp, title: String)] = [
        (.bigtable, "Plan Thursday tacos"),
        (.caloma, "Dinner shows up on the family wall"),
        (.sated, "Log it with one tap"),
        (.suffice, "Groceries land in your budget"),
    ]

    static let termsURL = URL(string: "https://hearthapps.com/terms")!
    static let privacyURL = URL(string: "https://hearthapps.com/privacy")!
}

// MARK: - Colors

nonisolated private extension Color {
    init(hearthHex hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

nonisolated private func hearthUIColor(_ hex: UInt32, _ opacity: Double) -> UIColor {
    UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: opacity
    )
}

nonisolated private extension Color {
    /// One color in light mode, another in dark; follows the app's or the system's appearance.
    init(hearthLight light: UInt32, _ lightOpacity: Double = 1, dark: UInt32, _ darkOpacity: Double = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? hearthUIColor(dark, darkOpacity)
                : hearthUIColor(light, lightOpacity)
        })
    }
}

/// Hearth+ colors. Dark: ember on brown-black. Light: ember on warm paper (the "Hearth Paywall"
/// canvas's Light mode row). Each follows the app's or the system's appearance.
@MainActor
private enum Ember {
    static let ground = Color(hearthLight: 0xFBF5EE, dark: 0x17110D)
    static let card = Color(hearthLight: 0xFFFFFF, dark: 0x1F1712)
    static let text = Color(hearthLight: 0x24160D, dark: 0xFFF6EE)
    static let sub = Color(hearthLight: 0x6B5444, dark: 0xFFF0E4, 0.70)
    static let label = Color(hearthLight: 0xB4501A, dark: 0xFFB27A)
    static let ember = Color(hearthHex: 0xFF8A3D)
    /// Text on ember and on the orange button, in both appearances.
    static let ink = Color(hearthHex: 0x241005)
    /// Text on `text` (the selected segment, Continue).
    static let inverse = Color(hearthLight: 0xFFF6EE, dark: 0x241005)
    static let error = Color(hearthLight: 0xC4281C, dark: 0xFF9B8A)
    /// Cards and rows.
    static let fill = Color(hearthLight: 0xFFFFFF, dark: 0xFFFFFF, 0.06)
    static let stroke = Color(hearthLight: 0x5A3214, 0.10, dark: 0xFFFFFF, 0.10)
    static let divider = Color(hearthLight: 0x5A3214, 0.12, dark: 0xFFFFFF, 0.12)
    /// Secondary buttons and chips.
    static let raised = Color(hearthLight: 0xFFFFFF, dark: 0xFFFFFF, 0.10)
    static let track = Color(hearthLight: 0x5A3214, 0.07, dark: 0xFFFFFF, 0.14)
    static let trackStroke = Color(hearthLight: 0x5A3214, 0.12, dark: 0xFFFFFF, 0.24)
    static let radioOff = Color(hearthLight: 0x24160D, 0.28, dark: 0xFFFFFF, 0.35)
    static let selectedFill = Color(hearthLight: 0xFFF1E6, dark: 0xFF8A3D, 0.14)
    static let upgradeInk = Color(hearthLight: 0x6A3510, dark: 0xFFE7D6)
    static let scrim = Color(hearthLight: 0xFBF5EE, 0.96, dark: 0x140E0A, 0.96)
    static let shine = Color(hearthLight: 0xF3E7DA, dark: 0xFFFFFF, 0.14)
    static let button = LinearGradient(colors: [Color(hearthHex: 0xFF7A3D), Color(hearthHex: 0xFFB347)], startPoint: .leading, endPoint: .trailing)
    static let badge = LinearGradient(colors: [Color(hearthHex: 0xFFB347), Color(hearthHex: 0xFF6A2B)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Presenting it

extension View {
    /// The Hearth paywall as a full-screen cover.
    func hearthPaywall(isPresented: Binding<Bool>, feature: HearthPaywallFeature? = nil, startWith kind: HearthPlan.Kind = .hearthPlus) -> some View {
        fullScreenCover(isPresented: isPresented) {
            HearthPaywall(feature: feature, startWith: kind)
        }
    }

    func hearthPaywall(isPresented: Binding<Bool>, feature: String, startWith kind: HearthPlan.Kind = .hearthPlus) -> some View {
        hearthPaywall(isPresented: isPresented, feature: HearthPaywallFeature(feature), startWith: kind)
    }
}

// MARK: - The paywall

struct HearthPaywall: View {
    var feature: HearthPaywallFeature?
    var startWith: HearthPlan.Kind = .hearthPlus

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = HearthPurchases.shared
    @State private var kind: HearthPlan.Kind = .hearthPlus
    @State private var term: HearthPlan.Term = .annual
    @State private var phase: Phase = .choosing
    @State private var toast: Toast?
    @State private var showsLink = false
    /// The sign-in step is showing before a Hearth+ purchase (not the link step after one).
    @State private var linkBeforePurchase = false
    @State private var didStart = false

    private enum Phase: Equatable {
        case choosing, purchasing, failed(String), pending, success
    }

    private enum Toast: Equatable {
        case restored, nothing, failed(String)

        var text: String {
            switch self {
            case .restored: "Purchases restored"
            case .nothing: "No purchases found for this Apple Account"
            case .failed(let message): message
            }
        }
    }

    private var app: HearthApp { store.app }
    private var info: HearthAppInfo { app.info }
    private var isHearth: Bool { kind == .hearthPlus }
    /// Hearth+ covers every app and the household, so it's tied to a Hearth account: sign in first.
    private var needsSignIn: Bool { isHearth && !store.isSignedIn }
    /// They already have this app's plan: Hearth+ is an upgrade.
    private var isUpgrade: Bool {
        store.membership?.kind == .app && store.membership?.source != .household
    }
    private var isMember: Bool {
        guard let membership = store.membership else { return false }
        return membership.kind == .hearthPlus || !isUpgrade || kind == .app
    }

    private var plans: [HearthPlan] {
        let all = isHearth ? store.hearthPlans : store.appPlans
        return isUpgrade ? all.filter { $0.term != .monthly } : all
    }

    private var chosen: HearthPlan? {
        plans.first { $0.term == term } ?? plans.first
    }

    var body: some View {
        ZStack {
            background
            if isMember && phase != .success {
                memberPage
            } else {
                buyPage
            }
            if phase == .success {
                success
                    .transition(.opacity)
            }
            if let toast {
                toastView(toast)
            }
        }
        .animation(.smooth(duration: 0.3), value: kind)
        .animation(.smooth(duration: 0.3), value: phase)
        .animation(.smooth(duration: 0.3), value: toast)
        .task {
            guard !didStart else { return }
            didStart = true
            kind = isUpgrade ? .hearthPlus : startWith
            if store.plansState != .loaded { await store.loadPlans() }
        }
        .fullScreenCover(isPresented: $showsLink) {
            HearthLinkAccountView(beforePurchase: linkBeforePurchase) {
                showsLink = false
                if linkBeforePurchase {
                    linkBeforePurchase = false
                    // Signed in: carry on to Apple's purchase sheet once this cover is gone.
                    if store.isSignedIn {
                        Task {
                            try? await Task.sleep(for: .seconds(0.6))
                            await buy()
                        }
                    }
                } else {
                    dismiss()
                }
            }
        }
    }

    // MARK: Background

    @ViewBuilder
    private var background: some View {
        if isHearth || isMember && store.hasHearthPlus {
            HearthEmberBackground(reduceMotion: reduceMotion)
        } else {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground)
                LinearGradient(
                    stops: [
                        .init(color: info.color, location: 0),
                        .init(color: info.color.opacity(0.88), location: 0.3),
                        .init(color: info.color.opacity(0.5), location: 0.6),
                        .init(color: info.color.opacity(0.15), location: 0.85),
                        .init(color: info.color.opacity(0), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 420)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Buying

    private var buyPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                topBar
                if isHearth { hearthHeader } else { appHeader }
                if let feature { featureChip(feature) }
                if !isUpgrade { segment }
                if isUpgrade { upgradeCard }
                planList
                if isHearth { hearthSell } else { appSell }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .opacity(phase == .purchasing ? 0.55 : 1)
            .disabled(phase == .purchasing)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(isHearth ? Ember.text : .white)
            .accessibilityLabel("Close")
            Spacer()
            Button("Restore") { Task { await restore() } }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glass)
                .tint(isHearth ? Ember.text : .white)
        }
        .foregroundStyle(isHearth ? Ember.text : .white)
        .padding(.top, 8)
    }

    private var hearthHeader: some View {
        VStack(spacing: 8) {
            HearthAppArc(reduceMotion: reduceMotion)
                .frame(height: 150)
                .padding(.top, 6)
            Text("HEARTH+")
                .font(.footnote.weight(.bold))
                .tracking(2.4)
                .foregroundStyle(Ember.label)
            Text(HearthPlanCopy.headline)
                .font(.system(.largeTitle, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Ember.text)
            Text(HearthPlanCopy.pitch)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Ember.sub)
                .frame(maxWidth: 330)
        }
        .padding(.top, 4)
    }

    private var appHeader: some View {
        VStack(spacing: 10) {
            HearthAppIcon(app: app, size: 76)
                .clipShape(.rect(cornerRadius: 19, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.white.opacity(0.85), lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 10)
            Text(app.planName)
                .font(.largeTitle.bold())
                .foregroundStyle(.white.opacity(0.95))
            Text("Everything in \(app.displayName), unlocked.")
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .multilineTextAlignment(.center)
        .padding(.top, 18)
    }

    private func featureChip(_ feature: HearthPaywallFeature) -> some View {
        Label(feature.title, systemImage: feature.symbol ?? "lock.open.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isHearth ? Ember.text : .white)
            .background(isHearth ? AnyShapeStyle(Ember.raised) : AnyShapeStyle(.white.opacity(0.2)), in: .capsule)
            .padding(.top, 16)
    }

    private var segment: some View {
        HStack(spacing: 4) {
            segmentButton("All 5 apps", selected: isHearth) { kind = .hearthPlus }
            segmentButton("\(app.displayName) only", selected: !isHearth) { kind = .app }
        }
        .padding(4)
        .background(isHearth ? Ember.track : .white.opacity(0.14), in: .capsule)
        .overlay(Capsule().strokeBorder(isHearth ? Ember.trackStroke : .white.opacity(0.24)))
        .padding(.top, 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What to unlock")
    }

    private func segmentButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(selected ? (isHearth ? Ember.inverse : info.ink) : (isHearth ? Ember.text : .white))
                .background(selected ? AnyShapeStyle(isHearth ? Ember.text : .white) : AnyShapeStyle(.clear), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var upgradeCard: some View {
        HStack(spacing: 12) {
            HearthAppIcon(app: app, size: 34)
                .clipShape(.rect(cornerRadius: 9, style: .continuous))
            Text(upgradeText)
                .font(.subheadline)
                .foregroundStyle(Ember.upgradeInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ember.ember.opacity(0.14), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Ember.ember.opacity(0.45)))
        .padding(.top, 22)
    }

    private var upgradeText: AttributedString {
        let yearly = store.hearthPlans.first { $0.term == .annual }
        let own = store.appPlans.first { $0.term == .annual }
        var text = AttributedString("You have \(app.planName). ")
        if let yearly, let own, yearly.priceValue > own.priceValue {
            let difference = (yearly.priceValue - own.priceValue).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
            var bold = AttributedString("Hearth+ is \(difference) more a year")
            bold.font = .subheadline.bold()
            text += bold
            text += AttributedString("; Apple credits the rest of your current plan.")
        } else {
            text += AttributedString("Moving to Hearth+ credits the rest of your current plan.")
        }
        return text
    }

    // MARK: Plans

    @ViewBuilder
    private var planList: some View {
        VStack(spacing: 10) {
            switch store.plansState {
            case .idle, .loading:
                ForEach(0..<3, id: \.self) { _ in
                    HearthShimmer(hearth: isHearth)
                        .frame(height: 66)
                        .clipShape(.rect(cornerRadius: 18))
                }
            case .unavailable:
                unavailableCard
            case .loaded:
                ForEach(plans) { plan in
                    planRow(plan)
                }
            }
        }
        .padding(.top, 16)
    }

    private var unavailableCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.title2)
                .foregroundStyle(subStyle)
            Text("Prices didn't load")
                .font(.headline)
            Text("Check your connection and try again. Nothing has been charged.")
                .font(.subheadline)
                .foregroundStyle(subStyle)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await store.loadPlans() } }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(isHearth ? Ember.text : Color.primary)
                .padding(.top, 6)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(cardBackground, in: .rect(cornerRadius: 22))
    }

    private func planRow(_ plan: HearthPlan) -> some View {
        let selected = plan.term == chosen?.term
        return Button { term = plan.term } label: {
            HStack(spacing: 12) {
                ZStack {
                    if selected {
                        Circle().fill(isHearth ? Ember.ember : info.ink)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(isHearth ? Ember.ink : .white)
                    } else {
                        Circle().strokeBorder(isHearth ? Ember.radioOff : Color(.systemGray3), lineWidth: 2)
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(planName(plan))
                            .font(.headline)
                        if let badge = store.savings(for: plan) {
                            Text(badge)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .foregroundStyle(isHearth ? Ember.ink : .white)
                                .background(isHearth ? Ember.ember : info.ink, in: .capsule)
                        }
                    }
                    Text(planDetail(plan))
                        .font(.footnote)
                        .foregroundStyle(subStyle)
                }
                Spacer(minLength: 8)
                Text(plan.price)
                    .font(.headline)
                    .monospacedDigit()
            }
            .foregroundStyle(isHearth ? Ember.text : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 66)
            .background(rowBackground(selected: selected), in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(selected ? (isHearth ? Ember.ember : info.ink) : (isHearth ? Ember.divider : .clear), lineWidth: selected ? (isHearth ? 1.5 : 2) : 1)
            }
            .scaleEffect(selected && !reduceMotion ? 1.015 : 1)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.smooth(duration: 0.25), value: selected)
    }

    private func rowBackground(selected: Bool) -> AnyShapeStyle {
        if isHearth {
            return AnyShapeStyle(selected ? Ember.selectedFill : Ember.fill)
        }
        return AnyShapeStyle(Color(.secondarySystemGroupedBackground))
    }

    private func planName(_ plan: HearthPlan) -> String {
        switch plan.term {
        case .monthly: "Monthly"
        case .annual: "Yearly"
        case .lifetime: "Lifetime"
        }
    }

    private func planDetail(_ plan: HearthPlan) -> String {
        switch plan.term {
        case .monthly: "Cancel anytime"
        case .annual: plan.perMonth.map { "\($0) a month, billed yearly" } ?? "Billed yearly"
        case .lifetime: "Pay once, keep it forever"
        }
    }

    // MARK: Selling Hearth+

    private var hearthSell: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let annual = store.hearthPlans.first(where: { $0.term == .annual }),
               annual.price.hasPrefix("$"), annual.priceValue == Decimal(string: "99.99") {
                bundleSavings(price: annual.price)
            }
            Text("How it all connects")
                .font(.title3.bold())
                .foregroundStyle(Ember.text)
                .padding(.top, 26)
                .padding(.bottom, 10)
                .padding(.horizontal, 4)
            HearthFlowCard(reduceMotion: reduceMotion)
            Text("Every premium feature")
                .font(.title3.bold())
                .foregroundStyle(Ember.text)
                .padding(.top, 26)
                .padding(.bottom, 10)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(HearthAppInfo.order.enumerated()), id: \.element) { index, other in
                    HStack(spacing: 12) {
                        HearthAppIcon(app: other, size: 36)
                            .clipShape(.rect(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(other.displayName)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Ember.text)
                            Text(HearthPlanCopy.perk(other))
                                .font(.footnote)
                                .foregroundStyle(Ember.sub)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Ember.divider).frame(height: 0.5) }
                    }
                }
            }
            .background(Ember.fill, in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Ember.stroke))
            HStack(spacing: 8) {
                trustTile("Your whole family, however big", symbol: "person.2")
                trustTile("Your data stays in your iCloud", symbol: "lock.shield")
                trustTile("No ads. Cancel anytime", symbol: "checkmark")
            }
            .padding(.top, 16)
        }
    }

    private func bundleSavings(price: String) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("All five apps separately")
                Text("With Hearth+")
            }
            .font(.subheadline)
            .foregroundStyle(Ember.sub)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("$179.95/yr")
                    .font(.subheadline)
                    .strikethrough()
                    .foregroundStyle(Ember.sub)
                Text("\(price)/yr")
                    .font(.headline)
                    .foregroundStyle(Ember.text)
            }
            .monospacedDigit()
            Text("Save $79.96")
                .font(.footnote.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(Ember.ink)
                .background(Ember.ember, in: .rect(cornerRadius: 12))
        }
        .padding(16)
        .background(Ember.fill, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Ember.stroke))
        .padding(.top, 16)
    }

    private func trustTile(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Ember.label)
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(Ember.text.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ember.fill, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ember.stroke))
    }

    // MARK: Selling the app's plan

    private var appSell: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(app.planName) includes")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(HearthPlanCopy.perks(app), id: \.self) { perk in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(perk)
                    }
                    .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            Button { kind = .hearthPlus } label: {
                HStack(spacing: 12) {
                    HStack(spacing: -6) {
                        ForEach(HearthAppInfo.order, id: \.self) { other in
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(other.info.color)
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ember.card, lineWidth: 2))
                        }
                    }
                    .padding(.leading, 6)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Get all 5 with Hearth+")
                            .font(.callout.weight(.semibold))
                        Text(upsellLine)
                            .font(.footnote)
                            .foregroundStyle(Ember.sub)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Ember.sub)
                }
                .foregroundStyle(Ember.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Ember.card, in: .rect(cornerRadius: 22))
                .contentShape(.rect(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .environment(\.colorScheme, .dark)
            .padding(.top, 16)
        }
    }

    private var upsellLine: String {
        if let hearth = store.hearthPlans.first(where: { $0.term == .annual }),
           let own = store.appPlans.first(where: { $0.term == .annual }),
           hearth.priceValue > own.priceValue {
            let difference = (hearth.priceValue - own.priceValue).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
            return "All five apps for \(difference) more a year"
        }
        return "Every premium feature in all five apps"
    }

    // MARK: The button

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if phase == .pending {
                Label("Waiting for approval", systemImage: "hourglass")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(isHearth ? AnyShapeStyle(Ember.raised) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: .capsule)
                    .foregroundStyle(isHearth ? Ember.text : Color.primary)
                Text("Your request went to your family organizer. \(isHearth ? "Hearth+" : app.planName) unlocks as soon as it's approved; you can close this.")
                    .font(.footnote)
                    .foregroundStyle(subStyle)
                    .multilineTextAlignment(.center)
            } else {
                Button {
                    if needsSignIn {
                        linkBeforePurchase = true
                        showsLink = true
                    } else {
                        Task { await buy() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        if phase == .purchasing { ProgressView().tint(isHearth ? Ember.ink : .white) }
                        Text(ctaTitle)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(isHearth ? Ember.ink : .white)
                    .background(ctaBackground, in: .capsule)
                    .overlay {
                        if !ctaDisabled && !reduceMotion { HearthSheen().clipShape(.capsule) }
                    }
                    .shadow(color: isHearth ? Ember.ember.opacity(0.35) : info.color.opacity(0.3), radius: 14, y: 10)
                    .opacity(ctaDisabled ? 0.55 : 1)
                }
                .buttonStyle(.plain)
                .disabled(ctaDisabled)
                if case .failed(let message) = phase {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(isHearth ? Ember.error : Color(.systemRed))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    Text(fineprint)
                        .font(.footnote)
                        .foregroundStyle(subStyle)
                        .multilineTextAlignment(.center)
                }
            }
            HStack(spacing: 16) {
                Link("Terms", destination: HearthPlanCopy.termsURL)
                Link("Privacy", destination: HearthPlanCopy.privacyURL)
                Button("Redeem code") { store.redeemCode() }
            }
            .font(.footnote)
            .foregroundStyle(subStyle)
            .tint(subStyle)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(isHearth ? AnyShapeStyle(Ember.ground.opacity(0.82)) : AnyShapeStyle(.bar))
        .background(.ultraThinMaterial)
    }

    private var ctaBackground: AnyShapeStyle {
        isHearth ? AnyShapeStyle(Ember.button) : AnyShapeStyle(info.ink)
    }

    private var ctaDisabled: Bool {
        store.plansState != .loaded || chosen == nil || phase == .purchasing
    }

    private var ctaTitle: String {
        if phase == .purchasing { return "Confirming with Apple" }
        if store.plansState == .loading || store.plansState == .idle { return "Loading prices" }
        if store.plansState == .unavailable { return "Unavailable" }
        if case .failed = phase { return "Try Again" }
        guard let plan = chosen else { return "Unavailable" }
        if needsSignIn { return "Sign in to continue" }
        if isUpgrade && isHearth { return "Upgrade to Hearth+" }
        if plan.term == .lifetime { return "Buy for \(plan.price)" }
        if plan.offersTrial, let days = plan.trialDays { return "Try free for \(days) days" }
        return "Subscribe for \(plan.price) \(plan.term == .annual ? "a year" : "a month")"
    }

    private var fineprint: String {
        if needsSignIn {
            return "Hearth+ covers all your Hearth apps and your household, so it’s tied to your Hearth account. Your data stays in iCloud."
        }
        guard let plan = chosen else { return "Shared with your family. Cancel anytime in Settings." }
        if plan.term == .lifetime { return "One payment of \(plan.price). No subscription. Shared with your family." }
        if isUpgrade && isHearth { return "Starts today. Apple credits what's left of \(app.planName)." }
        let period = plan.term == .annual ? "a year" : "a month"
        if plan.offersTrial, let days = plan.trialDays {
            return "Free for \(days) days, then \(plan.price) \(period). Cancel anytime in Settings."
        }
        return "Renews \(plan.term == .annual ? "yearly" : "monthly") until you cancel. Cancel anytime in Settings."
    }

    private var subStyle: Color { isHearth ? Ember.sub : Color.secondary }
    private var cardBackground: AnyShapeStyle {
        isHearth ? AnyShapeStyle(Ember.fill) : AnyShapeStyle(Color(.secondarySystemGroupedBackground))
    }

    // MARK: Actions

    private func buy() async {
        guard let plan = chosen, phase != .purchasing else { return }
        phase = .purchasing
        switch await store.purchase(plan) {
        case .purchased: phase = .success
        case .cancelled: phase = .choosing
        case .pending: phase = .pending
        case .failed: phase = .failed("Payment didn't go through. Check your payment method in Settings, then try again.")
        }
    }

    private func restore() async {
        switch await store.restore() {
        case .restored: show(.restored)
        case .nothing: show(.nothing)
        case .failed(let message): show(.failed(message))
        }
    }

    private func show(_ next: Toast) {
        toast = next
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == next { toast = nil }
        }
    }

    private func toastView(_ toast: Toast) -> some View {
        VStack {
            Label(toast.text, systemImage: toast == .restored ? "checkmark" : "exclamationmark.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(white: 0.11, opacity: 0.92), in: .capsule)
                .shadow(color: .black.opacity(0.3), radius: 15, y: 10)
                .padding(.top, 64)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
            Spacer()
        }
    }

    // MARK: Success

    private var success: some View {
        let unlocked = store.hasHearthPlus ? HearthAppInfo.order : [app]
        return ZStack {
            Ember.scrim.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                HearthCelebration(reduceMotion: reduceMotion)
                    .frame(width: 120, height: 120)
                Text(store.hasHearthPlus ? "Welcome to Hearth+" : "\(app.planName) is on")
                    .font(.title.bold())
                    .foregroundStyle(Ember.text)
                    .padding(.top, 28)
                Text(store.hasHearthPlus
                     ? "Every premium feature in all five apps is unlocked for you and your family."
                     : "Everything in \(app.displayName) is unlocked for you and your family.")
                    .font(.body)
                    .foregroundStyle(Ember.sub)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.top, 8)
                HStack(spacing: 10) {
                    ForEach(unlocked, id: \.self) { other in
                        HearthAppIcon(app: other, size: 44)
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.top, 26)
                Spacer()
                Button {
                    if store.needsAccountLink && store.signInButton != nil {
                        showsLink = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(Ember.inverse)
                        .background(Ember.text, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            .padding(32)
            .frame(maxWidth: 520)
        }
    }

    // MARK: Member

    private var memberPage: some View {
        let membership = store.membership
        let hearth = membership?.kind == .hearthPlus
        return ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .tint(hearth ? Ember.text : .white)
                    .foregroundStyle(hearth ? Ember.text : .white)
                    .accessibilityLabel("Close")
                    Spacer()
                }
                .padding(.top, 8)
                if hearth { hearthHeader } else { appHeader }
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your plan")
                            .font(.footnote.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(hearth ? Ember.sub : Color.secondary)
                        Text(membership?.title(for: app) ?? app.planName)
                            .font(.title3.bold())
                        Text(memberLine(membership))
                            .font(.subheadline)
                            .foregroundStyle(hearth ? Ember.sub : Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    ForEach(HearthAppInfo.order, id: \.self) { other in
                        let on = hearth || other == app
                        HStack(spacing: 12) {
                            HearthAppIcon(app: other, size: 30)
                                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                            Text(other.displayName)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(on ? "Unlocked" : "Not included")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(on ? (hearth ? Ember.text : Color.primary) : Color.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .overlay(alignment: .top) {
                            Rectangle().fill(hearth ? Ember.divider : Color(.separator)).frame(height: 0.5)
                        }
                    }
                }
                .foregroundStyle(hearth ? Ember.text : Color.primary)
                .background(hearth ? AnyShapeStyle(Ember.fill) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: .rect(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(hearth ? Ember.stroke : .clear))
                .padding(.top, 22)
                if !hearth && isUpgrade {
                    Button { kind = .hearthPlus } label: {
                        Text("Upgrade to Hearth+")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(Ember.ink)
                            .background(Ember.button, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if membership?.source == .own {
                    // Liquid Glass, like Close and Restore: it floats over the plan card as it
                    // scrolls, so it needs glass rather than a see-through fill.
                    Button { Task { await store.manageSubscription() } } label: {
                        Text("Manage Subscription")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(hearth ? Ember.text : Color.primary)
                    .foregroundStyle(hearth ? Ember.text : Color.primary)
                    Text(membership?.term == .lifetime ? "Yours for good." : "Change or cancel your plan in Apple Account settings.")
                        .font(.footnote)
                        .foregroundStyle(hearth ? Ember.sub : Color.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: 560)
        }
        // The plan card fades out under the button and its note instead of showing through.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    private func memberLine(_ membership: HearthMembership?) -> String {
        guard let membership else { return "" }
        let shared: String
        switch membership.source {
        case .own: shared = "Shared with your family"
        case .familySharing: shared = "Through Family Sharing"
        case .household: shared = "From your household"
        }
        guard let date = membership.expiresAt else {
            return membership.term == .lifetime ? "Lifetime · \(shared)" : shared
        }
        let day = date.formatted(.dateTime.month(.wide).day().year())
        if membership.isTrial { return "Free trial until \(day) · \(shared)" }
        return "\(membership.willRenew ? "Renews" : "Ends") \(day) · \(shared)"
    }
}

// MARK: - Link your account

/// After buying Hearth+ signed out: sign in once so the other apps unlock too.
struct HearthLinkAccountView: View {
    /// True when shown before a Hearth+ purchase (sign in first); false after a signed-out one.
    var beforePurchase = false
    var onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = HearthPurchases.shared

    var body: some View {
        ZStack {
            HearthEmberBackground(reduceMotion: reduceMotion)
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Ember.ember.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 66))
                        .frame(width: 132, height: 132)
                    Circle()
                        .fill(Ember.badge)
                        .frame(width: 88, height: 88)
                        .shadow(color: Color(hearthHex: 0xFF7832, opacity: 0.5), radius: 17)
                    Image(systemName: beforePurchase ? "person.crop.circle" : "link")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Ember.ink)
                }
                .padding(.top, 40)
                Text("HEARTH+")
                    .font(.footnote.weight(.bold))
                    .tracking(2.4)
                    .foregroundStyle(Ember.label)
                    .padding(.top, 10)
                Text(beforePurchase ? "Sign in for Hearth+" : "One more step")
                    .font(.title.bold())
                    .foregroundStyle(Ember.text)
                    .padding(.top, 8)
                Text(message)
                    .font(.body)
                    .foregroundStyle(Ember.sub)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
                    .padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(Array(HearthAppInfo.order.enumerated()), id: \.element) { index, other in
                        HStack(spacing: 12) {
                            HearthAppIcon(app: other, size: 34)
                                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                            Text(other.displayName)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Ember.text)
                            Spacer()
                            Text(status(for: other))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(other == store.app || store.isSignedIn ? Ember.text : Ember.sub)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .overlay(alignment: .top) {
                            if index > 0 { Rectangle().fill(Ember.divider).frame(height: 0.5) }
                        }
                    }
                }
                .background(Ember.fill, in: .rect(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Ember.stroke))
                .padding(.top, 30)
                Spacer()
                if let button = store.signInButton {
                    button()
                        .frame(height: 54)
                        .clipShape(.capsule)
                }
                Button(beforePurchase && store.signInButton == nil ? "Back" : "Not now", action: onDone)
                    .font(.headline)
                    .foregroundStyle(Ember.text)
                    .frame(minHeight: 44)
                    .padding(.top, 8)
                Text("Your data stays in iCloud. Your Hearth account only tells your apps that you're a member.")
                    .font(.footnote)
                    .foregroundStyle(Ember.sub)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: 520)
        }
        .onChange(of: store.isSignedIn) { _, signedIn in
            if signedIn {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    onDone()
                }
            }
        }
    }

    private var message: String {
        guard beforePurchase else {
            return "\(store.app.displayName) is unlocked. Sign in once so Hearth+ unlocks in your other apps too."
        }
        if store.signInButton == nil {
            return "Hearth+ lives on your Hearth account. Sign in from another Hearth app, then come back: \(store.app.displayName) picks it up on its own."
        }
        return "Hearth+ unlocks all five apps and your household, so it lives on your Hearth account. Sign in once, then confirm with Apple."
    }

    private func status(for other: HearthApp) -> String {
        if beforePurchase { return store.isSignedIn ? "Unlocked" : "Included" }
        return other == store.app || store.isSignedIn ? "Unlocked" : "After sign-in"
    }
}

// MARK: - In the app

/// Where a paid feature would be: what it does, and a way to start the trial.
struct HearthLockedCard: View {
    var feature: HearthPaywallFeature
    /// A free way to do it anyway ("Add by hand").
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    @State private var store = HearthPurchases.shared
    @State private var showsPaywall = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(feature: HearthPaywallFeature, secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil) {
        self.feature = feature
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    init(_ title: String, detail: String? = nil, secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil) {
        self.init(feature: HearthPaywallFeature(title, detail: detail), secondaryTitle: secondaryTitle, secondaryAction: secondaryAction)
    }

    private var tryTitle: String {
        let trial = store.hearthPlans.first { $0.term == .annual } ?? store.appPlans.first { $0.term == .annual }
        if let trial, trial.offersTrial, let days = trial.trialDays { return "Try free for \(days) days" }
        return "See plans"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HEARTH+ OR \(store.app.planName.uppercased())")
                .font(.caption.weight(.bold))
                .tracking(1.6)
                .foregroundStyle(Ember.sub)
            Text(feature.title)
                .font(.title3.bold())
                .foregroundStyle(Ember.text)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = feature.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Ember.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                Ember.ground
                Circle()
                    .fill(RadialGradient(colors: [store.app.info.color.opacity(0.75), .clear], center: .center, startRadius: 0, endRadius: 100))
                    .frame(width: 200, height: 200)
                    .offset(x: 50, y: -60)
                    .opacity(reduceMotion ? 0.8 : 1)
            }
        }
        .clipShape(.rect(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
        .hearthPaywall(isPresented: $showsPaywall, feature: feature)
    }

    @ViewBuilder
    private var buttons: some View {
        Button { showsPaywall = true } label: {
            Text(tryTitle)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .foregroundStyle(Ember.ink)
                .background(Ember.button, in: .capsule)
                .overlay { if !reduceMotion { HearthSheen().clipShape(.capsule) } }
        }
        .buttonStyle(.plain)
        if let secondaryTitle, let secondaryAction {
            Button(secondaryTitle, action: secondaryAction)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .foregroundStyle(Ember.text)
                .background(.white.opacity(0.1), in: .capsule)
                .buttonStyle(.plain)
        }
    }
}

/// "HEARTH+" or "SUFFICE PLUS" next to the person in Account, when they have a plan.
struct HearthMemberBadge: View {
    @State private var store = HearthPurchases.shared

    var body: some View {
        if let membership = store.membership {
            Text(membership.kind == .hearthPlus ? "HEARTH+" : store.app.planName.uppercased())
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Ember.label)
                .background(Ember.ground, in: .capsule)
                .environment(\.colorScheme, .dark)
                .accessibilityLabel(membership.kind == .hearthPlus ? "Hearth+ member" : "\(store.app.planName) member")
        }
    }
}

/// The Account row: "Manage Hearth+" for members, "Get Hearth+" for everyone else.
struct HearthMembershipRow: View {
    @State private var store = HearthPurchases.shared
    @State private var showsPaywall = false

    var body: some View {
        Button { showsPaywall = true } label: {
            HStack(spacing: 12) {
                Image(systemName: store.isUnlocked ? "sparkles" : "flame.fill")
                    .foregroundStyle(.primary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hearthPaywall(isPresented: $showsPaywall)
    }

    private var title: String {
        guard let membership = store.membership else { return "Get Hearth+" }
        return membership.kind == .hearthPlus ? "Manage Hearth+" : "Manage \(store.app.planName)"
    }

    private var detail: String? {
        guard store.membership == nil else { return nil }
        return "Every premium feature in all five apps"
    }
}

/// The renewal failed: update the payment method before the grace period ends.
struct HearthBillingBanner: View {
    @State private var store = HearthPurchases.shared

    var body: some View {
        if let until = store.billingIssueUntil, let membership = store.membership {
            HStack(spacing: 12) {
                Image(systemName: "creditcard")
                    .font(.title3)
                    .foregroundStyle(Color(hearthLight: 0xB25E00, dark: 0xFFB25C))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(membership.kind == .hearthPlus ? "Hearth+" : store.app.planName) couldn't renew")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(hearthLight: 0x5C3300, dark: 0xFFE2C2))
                    Text("Update your payment method by \(until.formatted(.dateTime.month(.abbreviated).day())) to keep it.")
                        .font(.footnote)
                        .foregroundStyle(Color(hearthLight: 0x7A4A12, dark: 0xE8C39A))
                }
                Spacer(minLength: 0)
                Button("Update") { Task { await store.manageSubscription() } }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .foregroundStyle(.white)
                    .background(Color(hearthHex: 0xB25E00), in: .capsule)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(hearthLight: 0xFFF4E5, dark: 0x2E1F0E), in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(hearthLight: 0xF5C77E, dark: 0x6B4A1F)))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Another app's data that could show here with Hearth+ ("Your BigTable dinner plan could
/// show up here"). Shows nothing for Hearth+ members.
struct HearthPlusTeaser: View {
    var from: HearthApp
    var title: String
    var detail: String

    @State private var store = HearthPurchases.shared
    @State private var showsPaywall = false

    var body: some View {
        if !store.hasHearthPlus {
            Button { showsPaywall = true } label: {
                HStack(spacing: 12) {
                    HearthAppIcon(app: from, size: 36)
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Ember.text)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Ember.sub)
                    }
                    Spacer(minLength: 0)
                    Text("Hearth+")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(Ember.ink)
                        .background(Ember.ember, in: .capsule)
                }
                .padding(14)
                .background(Ember.card, in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Ember.stroke))
                .contentShape(.rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .hearthPaywall(isPresented: $showsPaywall, feature: HearthPaywallFeature(title))
        }
    }
}

// MARK: - Drawing

/// The warm, drifting background behind everything Hearth+.
struct HearthEmberBackground: View {
    var reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Light mode keeps the same glow, much softer, on warm paper.
        let light = colorScheme == .light
        let ground = light ? Color(hearthHex: 0xFBF5EE) : Color(hearthHex: 0x17110D)
        let orbOpacity = light ? 0.22 : 0.55
        let emberStrength = light ? 0.55 : 0.95
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ground))
                let orbs: [(UInt32, CGFloat, CGFloat, CGFloat, Double)] = [
                    (0xE0503A, -0.15, -0.05, 260, 11),
                    (0x3B74D9, 0.52, -0.07, 240, 13),
                    (0xFF8A3D, 0.2, 0.14, 220, 9),
                    (0x3A7D34, -0.2, 0.62, 260, 14),
                ]
                canvas.drawLayer { layer in
                    layer.addFilter(.blur(radius: 46))
                    for (index, orb) in orbs.enumerated() {
                        let phase = sin(t * 2 * .pi / orb.4 + Double(index))
                        let x = orb.1 * size.width + 18 * phase
                        let y = orb.2 * size.height + 22 * phase
                        let scale = 1 + 0.12 * (phase + 1) / 2
                        let side = orb.3 * scale
                        layer.opacity = orbOpacity
                        layer.fill(Path(ellipseIn: CGRect(x: x, y: y, width: side, height: side)), with: .color(Color(hearthHex: orb.0)))
                    }
                }
                let colors: [UInt32] = [0xFFB27A, 0xFF8A3D, 0xFFD3A8, 0xFF6A2B]
                for index in 0..<14 {
                    let duration = 7 + Double(index % 5) * 1.3
                    let progress = ((t + Double(index) * 0.9) / duration).truncatingRemainder(dividingBy: 1)
                    let x = CGFloat((index * 53) % 370 + 10) / 390 * size.width
                    let y = size.height + 10 - CGFloat(progress) * min(640, size.height * 0.8)
                    let radius = CGFloat(2 + index % 3) * CGFloat(1 - 0.7 * progress) / 2 + 0.5
                    let alpha = progress < 0.12 ? progress / 0.12 * emberStrength : emberStrength * (1 - progress)
                    canvas.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(Color(hearthHex: colors[index % 4], opacity: alpha)))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The five app icons floating in an arc over a glow.
private struct HearthAppArc: View {
    var reduceMotion: Bool
    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let positions: [(CGFloat, CGFloat)] = [(-140, 70), (-70, 22), (0, 4), (70, 22), (140, 70)]
            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [Ember.ember.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 90))
                    .frame(width: 180, height: 80)
                    .position(x: width / 2, y: 98)
                ForEach(Array(HearthAppInfo.order.enumerated()), id: \.element) { index, app in
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                        let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                        let bob = sin(t * 2 * .pi / (3.6 + Double(index) * 0.35)) * 3.5
                        HearthAppIcon(app: app, size: 56)
                            .clipShape(.rect(cornerRadius: 15, style: .continuous))
                            .shadow(color: app.info.color.opacity(0.55), radius: 12, y: 10)
                            .offset(y: bob - 3.5)
                    }
                    .position(x: width / 2 + positions[index].0, y: positions[index].1 + 28)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(.spring(duration: 0.7).delay(0.05 + Double(index) * 0.09), value: appeared)
                }
            }
        }
        .accessibilityHidden(true)
        .onAppear { appeared = true }
    }
}

/// BigTable → Caloma → Sated → Suffice, with a light traveling down the line.
private struct HearthFlowCard: View {
    var reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(HearthPlanCopy.flow.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 14) {
                    HearthAppIcon(app: step.app, size: 34)
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                        .padding(4)
                        .background(Ember.card, in: .rect(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Ember.text)
                        Text(step.app.displayName)
                            .font(.footnote)
                            .foregroundStyle(Ember.sub)
                    }
                }
                .frame(minHeight: 58)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                let top: CGFloat = 26
                let bottom = proxy.size.height - 26
                LinearGradient(colors: [Color(hearthHex: 0xE0503A), Color(hearthHex: 0xD9577A), Color(hearthHex: 0xF08A24), Color(hearthHex: 0x3A7D34)], startPoint: .top, endPoint: .bottom)
                    .frame(width: 2, height: bottom - top)
                    .opacity(0.5)
                    .position(x: 33, y: (top + bottom) / 2)
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let progress = (context.date.timeIntervalSinceReferenceDate / 4.5).truncatingRemainder(dividingBy: 1)
                        let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
                        Circle()
                            .fill(Color(hearthHex: 0xFFE2C7))
                            .frame(width: 12, height: 12)
                            .shadow(color: Color(hearthHex: 0xFFAA64, opacity: 0.8), radius: 7)
                            .position(x: 33, y: top + (bottom - top) * eased)
                    }
                }
            }
        }
        .background(Ember.fill, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Ember.stroke))
        .accessibilityElement(children: .combine)
    }
}

/// The check that pops in, with rings and a burst of embers.
private struct HearthCelebration: View {
    var reduceMotion: Bool
    @State private var go = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<2, id: \.self) { ring in
                    Circle()
                        .strokeBorder(Ember.ember, lineWidth: 2)
                        .scaleEffect(go ? 2.2 : 0.8)
                        .opacity(go ? 0 : 0.7)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(ring) * 0.8), value: go)
                }
                ForEach(0..<14, id: \.self) { index in
                    let angle = Double(index) / 14 * 2 * .pi
                    let radius = 80 + Double(index % 3) * 22
                    Circle()
                        .fill(index.isMultiple(of: 2) ? HearthAppInfo.order[index % 5].info.color : Ember.ember)
                        .frame(width: 8, height: 8)
                        .offset(x: go ? cos(angle) * radius : 0, y: go ? sin(angle) * radius : 0)
                        .scaleEffect(go ? 0.2 : 1)
                        .opacity(go ? 0 : 1)
                        .animation(.timingCurve(0.1, 0.7, 0.3, 1, duration: 1).delay(0.15 + Double(index % 4) * 0.04), value: go)
                }
            }
            Circle()
                .fill(Ember.badge)
                .frame(width: 96, height: 96)
                .shadow(color: Color(hearthHex: 0xFF7832, opacity: 0.6), radius: 20)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(Ember.ink)
                }
                .scaleEffect(go || reduceMotion ? 1 : 0.4)
                .animation(.spring(response: 0.5, dampingFraction: 0.55), value: go)
        }
        .accessibilityHidden(true)
        .onAppear { go = true }
    }
}

/// The light that sweeps across the main button.
private struct HearthSheen: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            GeometryReader { proxy in
                let cycle = 3.2
                let progress = ((context.date.timeIntervalSinceReferenceDate - 1) / cycle).truncatingRemainder(dividingBy: 1)
                let travel = min(progress / 0.55, 1)
                let width = proxy.size.width * 0.4
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
                    .rotationEffect(.degrees(-20))
                    .offset(x: -width * 1.4 + (proxy.size.width + width * 2.8) * travel)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A placeholder plan row while prices load.
private struct HearthShimmer: View {
    var hearth: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let progress = (context.date.timeIntervalSinceReferenceDate / 1.3).truncatingRemainder(dividingBy: 1)
            GeometryReader { proxy in
                let base = hearth ? Ember.fill : Color(.secondarySystemGroupedBackground)
                let shine = hearth ? Ember.shine : Color(.systemGray5)
                ZStack {
                    base
                    LinearGradient(colors: [base, shine, base], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width)
                        .offset(x: (progress * 2 - 1) * proxy.size.width)
                }
            }
        }
        .accessibilityLabel("Loading prices")
    }
}
