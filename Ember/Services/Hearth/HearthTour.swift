// HearthTour.swift — the guided tour every Hearth app shows: a Welcome screen (the app's icon,
// what it does, Show Me Around or Skip for Now), then one step per tab, each switching to that
// tab and lighting up one thing on it with a card beside it. It started as Hearken's tour.
//
// Canonical copy: ~/Developer/hearthkit/HearthTour.swift. Don't edit the copies inside the apps;
// edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthShared.swift and
// HearthApps.swift (for `HearthApp`, its info and `HearthAppIcon`).
//
// Using it
// - On the root (the TabView), once. It configures the tour, shows the Welcome sheet and the
//   spotlight, and calls `onStep` so the app can switch tabs (and pop to the tab's top):
//
//       TabView(selection: $router.tab) { ... }
//           .hearthTour(app: .sated, steps: SatedTour.steps, finishTitle: "Log a Meal",
//                       autoStart: !ScreenshotMode.isOn) { step in
//               router.tab = SatedTour.tab(for: step)
//           }
//
//   `autoStart` shows the Welcome once on a new install, as soon as the root appears (the root
//   only appears after onboarding). Hearken starts it itself after sign-in instead.
// - On each screen, mark what a step points at (one view; `isEnabled` picks one out of a list):
//
//       TodaySummaryCard().hearthTourTarget("today")
//
//   A step with nothing marked (or not on screen) shows its card docked at the bottom.
// - Profile › Take the Tour: `HearthProfilePresenter.shared.dismiss()` then
//   `HearthTour.shared.start(skippingWelcome: true, after: .milliseconds(600))`.
// - Ending with the last step's button (not Skip) sets `finishRequested`; an app that wants to
//   do something then (Hearken opens the reader) watches it and clears it.

import Observation
import SwiftUI
import UIKit

// MARK: - Steps

/// One stop on the tour: a tab, and what to say about it.
struct HearthTourStep: Identifiable, Equatable, Sendable {
    /// Also the target's name (`.hearthTourTarget(id)`).
    let id: String
    let title: String
    let message: String
    /// The tab's own icon, so the card names the icon-only tab bar.
    let symbol: String
    let color: Color

    init(_ id: String, title: String, message: String, symbol: String, color: Color) {
        self.id = id
        self.title = title
        self.message = message
        self.symbol = symbol
        self.color = color
    }
}

// MARK: - The tour

@MainActor
@Observable
final class HearthTour {
    static let shared = HearthTour()

    private(set) var app: HearthApp = .hearken
    private(set) var steps: [HearthTourStep] = []
    /// The last step's button: "Start Reading", "Plan a Week".
    private(set) var finishTitle = "Done"
    /// The step on screen, or nil when the tour isn't running.
    private(set) var step: HearthTourStep?
    /// The Welcome sheet is up.
    var showsWelcome = false
    /// Where the current step's target is, in global (window) coordinates.
    private(set) var targetFrame: CGRect?
    /// The tour ended with the last step's button; the app may act on it, then clears it.
    var finishRequested = false

    /// Every target's latest frame. Not observed: it changes on every scroll, and only the
    /// current step's frame (`targetFrame`) should redraw anything.
    @ObservationIgnored private var frames: [String: CGRect] = [:]
    @ObservationIgnored private var doneKey = ""

    private init() {}

    var isActive: Bool { step != nil || showsWelcome }
    var index: Int? { step.flatMap { current in steps.firstIndex { $0.id == current.id } } }
    var isLastStep: Bool { index == steps.count - 1 }

    /// Where "seen the tour" is kept for an app.
    nonisolated static func doneKey(for app: HearthApp) -> String { "hearth.tour.done.\(app.rawValue)" }

    /// Whether they've seen the tour (finished or skipped), here or on another of their devices
    /// (iCloud key-value storage, so a new iPad doesn't show it again).
    var isDone: Bool {
        UserDefaults.standard.bool(forKey: doneKey) || NSUbiquitousKeyValueStore.default.bool(forKey: doneKey)
    }

    func configure(app: HearthApp, steps: [HearthTourStep], finishTitle: String, doneKey: String? = nil) {
        self.app = app
        self.steps = steps
        self.finishTitle = finishTitle
        self.doneKey = doneKey ?? Self.doneKey(for: app)
    }

    /// A new install: the Welcome, once.
    func startIfNew(after delay: Duration = .zero) {
        guard !isDone, !isActive, !steps.isEmpty else { return }
        start(skippingWelcome: false, after: delay)
    }

    /// Profile › Take the Tour skips the Welcome and waits for the sheet to close.
    func start(skippingWelcome: Bool, after delay: Duration = .zero) {
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            if skippingWelcome {
                begin()
            } else {
                showsWelcome = true
            }
        }
    }

    /// Show Me Around.
    func begin() {
        showsWelcome = false
        guard let first = steps.first else { return }
        go(to: first)
    }

    func next() {
        guard let index else { return }
        if index + 1 < steps.count {
            go(to: steps[index + 1])
        } else {
            finish(completed: true)
        }
    }

    func skip() {
        finish(completed: false)
    }

    func finish(completed: Bool) {
        step = nil
        showsWelcome = false
        targetFrame = nil
        UserDefaults.standard.set(true, forKey: doneKey)
        NSUbiquitousKeyValueStore.default.set(true, forKey: doneKey)
        if completed { finishRequested = true }
    }

    private func go(to next: HearthTourStep) {
        step = next
        targetFrame = frames[next.id]
    }

    // MARK: Targets

    func report(_ frame: CGRect, for target: String) {
        frames[target] = frame
        if step?.id == target, targetFrame != frame { targetFrame = frame }
    }

    func forget(_ target: String) {
        frames[target] = nil
        if step?.id == target { targetFrame = nil }
    }
}

// MARK: - Modifiers

extension View {
    /// The tour on the app's root: configures it, shows the Welcome sheet and the spotlight, and
    /// calls `onStep` as each step begins so the app can show that step's tab.
    func hearthTour(
        app: HearthApp,
        steps: [HearthTourStep],
        finishTitle: String,
        doneKey: String? = nil,
        autoStart: Bool = true,
        onStep: @escaping (HearthTourStep) -> Void
    ) -> some View {
        modifier(HearthTourRoot(app: app, steps: steps, finishTitle: finishTitle, doneKey: doneKey, autoStart: autoStart, onStep: onStep))
    }

    /// Marks the view a tour step points at. Reports its frame on screen as it moves (scrolling,
    /// rotation, resizing), across tab and navigation containers. `isEnabled` picks one view out
    /// of a list (the first card, say).
    func hearthTourTarget(_ id: String, isEnabled: Bool = true) -> some View {
        modifier(HearthTourTargetModifier(id: id, isEnabled: isEnabled))
    }
}

private struct HearthTourRoot: ViewModifier {
    let app: HearthApp
    let steps: [HearthTourStep]
    let finishTitle: String
    let doneKey: String?
    let autoStart: Bool
    let onStep: (HearthTourStep) -> Void

    @State private var tour = HearthTour.shared

    func body(content: Content) -> some View {
        @Bindable var tour = tour
        content
            .onAppear {
                tour.configure(app: app, steps: steps, finishTitle: finishTitle, doneKey: doneKey)
                if autoStart { tour.startIfNew(after: .milliseconds(600)) }
            }
            .sheet(isPresented: $tour.showsWelcome) {
                HearthTourWelcome(app: app)
            }
            .onChange(of: tour.step) { _, step in
                if let step { onStep(step) }
            }
            .overlay { HearthTourOverlay() }
    }
}

private struct HearthTourTargetModifier: ViewModifier {
    let id: String
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    HearthTour.shared.report(frame, for: id)
                }
                .onDisappear { HearthTour.shared.forget(id) }
        } else {
            content
        }
    }
}

// MARK: - Welcome

/// The tour's first screen: the app's icon, its tagline, three things it does (from
/// hearthapps.com, `HearthAppInfo.features`), then Show Me Around or Skip for Now. A sheet on
/// iPhone; a centered form-sized card on iPad.
struct HearthTourWelcome: View {
    let app: HearthApp
    var tour = HearthTour.shared

    private var info: HearthAppInfo { app.info }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HearthAppIcon(app: app, size: 84)
                    .clipShape(.rect(cornerRadius: 84 * 0.225, style: .continuous))
                    .shadow(color: info.color.opacity(0.3), radius: 14, y: 8)
                    .padding(.top, 40)

                Text("Welcome to \(app.displayName)")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
                    .accessibilityAddTraits(.isHeader)

                Text(info.tagline)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 22) {
                    ForEach(info.features.prefix(3)) { feature in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: feature.symbol)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(info.color)
                                .frame(width: 44, height: 44)
                                .background(info.color.opacity(0.15), in: .rect(cornerRadius: 12))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title).font(.headline)
                                Text(feature.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 32)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    tour.begin()
                } label: {
                    Text("Show Me Around")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(info.color)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Skip for Now") { tour.skip() }
                    .font(.body.weight(.medium))
                    .tint(Color.primary)
                    .padding(.vertical, 6)
                    .keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
        .interactiveDismissDisabled()
        .presentationSizing(.form)
    }
}

// MARK: - Spotlight and card

/// The tour's spotlight and card, over the whole tab view. Nothing is placed at fixed
/// coordinates: the spotlight follows the target's live frame, and the card goes above or below
/// it, wherever there's room, never over the tab bar (bottom in compact width, top in regular).
/// If neither side has room, or the text is at an accessibility size, the card docks at the
/// edge away from the tab bar.
struct HearthTourOverlay: View {
    var tour = HearthTour.shared

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var cardHeight: CGFloat = 0
    @AccessibilityFocusState private var titleFocused: Bool

    private static let margin: CGFloat = 14
    private static let gap: CGFloat = 14
    private static let holePadding: CGFloat = 8
    private static let holeRadius: CGFloat = 26
    /// Room left for the floating tab bar (and the space around it).
    private static let tabBarClearance: CGFloat = 72
    private static let regularCardWidth: CGFloat = 380

    var body: some View {
        if let step = tour.step {
            GeometryReader { outer in
                let safe = outer.safeAreaInsets
                GeometryReader { full in
                    let placement = place(size: full.size, origin: full.frame(in: .global).origin, safe: safe)
                    stage(step, placement: placement, screenHeight: full.size.height)
                }
                .ignoresSafeArea()
            }
            .transition(.opacity)
        }
    }

    private func stage(_ step: HearthTourStep, placement: Placement, screenHeight: CGFloat) -> some View {
        let motion: Animation = reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.15)
        let increased = contrast == .increased

        return ZStack(alignment: .topLeading) {
            // The dim, with a hole over the target. It takes every tap, so nothing behind it
            // opens mid-tour.
            HearthTourSpotlight(hole: placement.hole ?? .zero, radius: Self.holeRadius)
                .fill(Color.black.opacity(increased ? 0.65 : 0.52), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)

            if let hole = placement.hole {
                // Tapping the lit target moves the tour along.
                RoundedRectangle(cornerRadius: Self.holeRadius, style: .continuous)
                    .fill(Color.white.opacity(0.001))
                    .frame(width: hole.width, height: hole.height)
                    .offset(x: hole.minX, y: hole.minY)
                    .onTapGesture { tour.next() }
                    .accessibilityHidden(true)
            }

            card(step, screenHeight: screenHeight)
                .frame(width: placement.card.width)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                .offset(x: placement.card.minX, y: placement.card.minY)
        }
        .animation(motion, value: step)
        .animation(motion, value: placement)
        .onChange(of: step, initial: true) {
            // VoiceOver starts each step at the card's title.
            Task { titleFocused = true }
        }
    }

    private func card(_ step: HearthTourStep, screenHeight: CGFloat) -> some View {
        let large = typeSize.isAccessibilitySize
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: step.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(step.color)
                    .frame(width: 34, height: 34)
                    .background(step.color.opacity(0.15), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(step.title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
            }

            Group {
                if large {
                    // Very large text: the words scroll inside a card that never outgrows the screen.
                    ScrollView { message(step) }
                        .frame(maxHeight: screenHeight * 0.4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    message(step)
                }
            }
            .padding(.top, 8)

            HStack(spacing: 14) {
                if !large { dots(step) }
                Spacer(minLength: 0)
                Button("Skip") { tour.skip() }
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(tour.isLastStep ? tour.finishTitle : "Next") { tour.next() }
                    .fontWeight(.semibold)
                    .buttonStyle(.glassProminent)
                    .tint(tour.app.info.color)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(18)
        .modifier(HearthTourCardSurface(shape: shape, solid: reduceTransparency))
        .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(named: "Skip Tour") { tour.skip() }
    }

    private func message(_ step: HearthTourStep) -> some View {
        Text(step.message)
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dots(_ step: HearthTourStep) -> some View {
        let color = tour.app.info.color
        return HStack(spacing: 6) {
            ForEach(tour.steps) { each in
                Capsule()
                    .fill(each.id == step.id ? color : Color.secondary.opacity(0.35))
                    .frame(width: each.id == step.id ? 18 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \((tour.index ?? 0) + 1) of \(tour.steps.count)")
    }

    // MARK: Placement

    struct Placement: Equatable {
        /// The spotlight, in the overlay's coordinates; nil when there's nothing on screen to point at.
        var hole: CGRect?
        var card: CGRect
    }

    private func place(size: CGSize, origin: CGPoint, safe: EdgeInsets) -> Placement {
        let compact = sizeClass != .regular
        let large = typeSize.isAccessibilitySize
        // The space the card may use: inside the safe area, clear of the tab bar.
        let topReserve = compact ? 8 : Self.tabBarClearance
        let bottomReserve = compact ? Self.tabBarClearance : 8
        let area = CGRect(
            x: safe.leading + Self.margin,
            y: safe.top + topReserve,
            width: max(0, size.width - safe.leading - safe.trailing - Self.margin * 2),
            height: max(0, size.height - safe.top - safe.bottom - topReserve - bottomReserve)
        )
        let width = (compact || large) ? area.width : min(Self.regularCardWidth, area.width)
        let height = cardHeight
        // Docked: at the edge away from the tab bar, which is the bottom of `area` either way.
        let docked = CGRect(x: area.midX - width / 2, y: area.maxY - height, width: width, height: height)

        guard let global = tour.targetFrame else { return Placement(hole: nil, card: docked) }
        let target = global.offsetBy(dx: -origin.x, dy: -origin.y)
        // Point at it only if most of it is on screen.
        let shown = target.intersection(CGRect(origin: .zero, size: size))
        guard !shown.isNull, shown.height >= target.height * 0.6, shown.width >= target.width * 0.6 else {
            return Placement(hole: nil, card: docked)
        }
        let hole = target.insetBy(dx: -Self.holePadding, dy: -Self.holePadding)
        guard !large else { return Placement(hole: hole, card: docked) }

        let above = hole.minY - Self.gap - area.minY
        let below = area.maxY - (hole.maxY + Self.gap)
        guard height > 0, above >= height || below >= height else { return Placement(hole: hole, card: docked) }
        let goBelow = below >= above || above < height
        let y = goBelow ? hole.maxY + Self.gap : hole.minY - Self.gap - height
        // Compact: full width. Regular: centered on the target, kept inside the safe area.
        let x = compact ? area.midX - width / 2 : min(max(hole.midX - width / 2, area.minX), area.maxX - width)
        return Placement(hole: hole, card: CGRect(x: x, y: y, width: width, height: height))
    }
}

/// The dim layer: the whole screen minus a rounded hole. Animates the hole between steps.
private struct HearthTourSpotlight: Shape {
    var hole: CGRect
    var radius: CGFloat

    var animatableData: CGRect.AnimatableData {
        get { hole.animatableData }
        set { hole.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if hole.width > 0, hole.height > 0 {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}

/// Liquid Glass, or a solid card when Reduce Transparency is on.
private struct HearthTourCardSurface<S: Shape>: ViewModifier {
    let shape: S
    let solid: Bool

    func body(content: Content) -> some View {
        if solid {
            content.background(Color(.secondarySystemGroupedBackground), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}
