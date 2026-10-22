// HearthSplash.swift — the launch splash every Hearth app plays.
//
// Canonical copy: ~/Developer/hearthkit/HearthSplash.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh.
//
// What it does
// 1. The static launch screen is just the app's color (Info.plist `UILaunchScreen` ›
//    `UIColorName` = `Hearth/splash-<app>`), so the first frame here matches it exactly.
// 2. Droplets of the app's color spring out, swirl and pool back together into the app's real
//    icon (Assets › Hearth/<app>). A ripple rings out as they merge and a glint crosses the icon.
// 3. The app's name rises out of a blur, with the real Hearth logo (Assets › Hearth/hearth)
//    at the bottom.
// 4. When the app is ready (at least `minimumDuration`, at most `maximumDuration`), the color
//    rises with a liquid edge into the app's own color header and the app shows through.
//
// Use: `.hearthSplash(.bigtable, isReady: …, isEnabled: !ScreenshotMode.isOn)` on the root view.
// It plays once per launch, in the first window, in an overlay window above sheets and
// full-screen covers. Reduce Motion gets a short fade instead of the morph.

import SwiftUI
import UIKit

// MARK: - Using it

extension View {
    /// Plays the Hearth splash over the app when it launches.
    /// - Parameters:
    ///   - app: The app launching.
    ///   - isReady: False while the app is still loading what its first screen needs. The splash
    ///     waits for it, but never longer than `HearthSplash.maximumDuration`.
    ///   - isEnabled: False to skip it (screenshot mode, UI tests).
    func hearthSplash(_ app: HearthApp, isReady: Bool = true, isEnabled: Bool = true) -> some View {
        modifier(HearthSplashModifier(app: app, isReady: isReady, isEnabled: isEnabled))
    }
}

enum HearthSplash {
    /// The splash always plays at least this long (the morph and the name).
    static let minimumDuration: Double = 2.2
    /// It hands off by now even if the app isn't ready, so a slow network never holds anyone up.
    static let maximumDuration: Double = 3.2
    /// The color rising into the header.
    static let handoffDuration: Double = 0.75

    /// The launch screen's color: the app's color in Light Mode, a deeper shade in Dark Mode.
    /// Matches the `Hearth/splash-<app>` color assets.
    nonisolated static func backgroundColor(for app: HearthApp) -> Color {
        let hex = app.info.colorHex
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? splashUIColor(hex).darkened(0.38) : splashUIColor(hex)
        })
    }
}

/// Whether the app is ready, shared between the root view and the splash window.
@MainActor
@Observable
final class HearthSplashState {
    var isReady = true
}

// MARK: - The modifier

private struct HearthSplashModifier: ViewModifier {
    let app: HearthApp
    let isReady: Bool
    let isEnabled: Bool

    /// Covers the app in the launch color until the splash window is up.
    @State private var covering: Bool
    @State private var state = HearthSplashState()

    init(app: HearthApp, isReady: Bool, isEnabled: Bool) {
        self.app = app
        self.isReady = isReady
        self.isEnabled = isEnabled
        _covering = State(initialValue: isEnabled && !HearthSplashPresenter.hasStarted)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if covering {
                    HearthSplash.backgroundColor(for: app)
                        .ignoresSafeArea()
                        .background {
                            HearthSplashSceneReader { scene, window in
                                HearthSplashPresenter.present(app: app, state: state, scene: scene, host: window)
                                // Let the splash window draw its first frame (the same color)
                                // before uncovering the app beneath it.
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(150))
                                    covering = false
                                }
                            }
                        }
                        .accessibilityHidden(true)
                        .transition(.identity)
                }
            }
            .onChange(of: isReady, initial: true) { _, ready in
                state.isReady = ready
            }
            .task {
                // A failsafe: never leave the cover up if the window couldn't be found.
                guard covering else { return }
                try? await Task.sleep(for: .seconds(HearthSplash.maximumDuration + 1))
                covering = false
            }
    }
}

/// Finds the window scene the root view lives in.
private struct HearthSplashSceneReader: UIViewRepresentable {
    let onScene: @MainActor (UIWindowScene, UIWindow) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScene = onScene
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onScene: (@MainActor (UIWindowScene, UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let scene = window.windowScene, let onScene else { return }
            self.onScene = nil
            // Outside SwiftUI's update pass; the cover hides the frame in between.
            Task { @MainActor in onScene(scene, window) }
        }
    }
}

// MARK: - The window

/// Shows the splash in its own window above the app, so it covers sheets and full-screen covers
/// presented at launch (onboarding, the household step) too.
@MainActor
enum HearthSplashPresenter {
    /// True once a splash has started this launch; later windows (iPad) don't play it again.
    private(set) static var hasStarted = false
    private static var window: UIWindow?

    static func present(app: HearthApp, state: HearthSplashState, scene: UIWindowScene, host: UIWindow) {
        guard !hasStarted else { return }
        hasStarted = true

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        // Follow the app's own appearance setting (Light, Dark or System). Apps apply it as the
        // root appears, so look again a moment later.
        window.overrideUserInterfaceStyle = host.traitCollection.userInterfaceStyle
        Task { @MainActor [weak host, weak window] in
            try? await Task.sleep(for: .milliseconds(100))
            if let host, let window { window.overrideUserInterfaceStyle = host.traitCollection.userInterfaceStyle }
        }
        let root = HearthSplashHostingController(rootView: HearthSplashView(app: app, state: state) {
            HearthSplashPresenter.dismiss()
        })
        root.view.backgroundColor = .clear
        window.rootViewController = root
        window.isHidden = false
        self.window = window
    }

    static func passTouchesThrough() {
        window?.isUserInteractionEnabled = false
    }

    static func dismiss() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
}

private final class HearthSplashHostingController: UIHostingController<HearthSplashView> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

// MARK: - The splash

private struct HearthSplashView: View {
    let app: HearthApp
    let state: HearthSplashState
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var start: Date?
    /// Seconds after `start` when the handoff began.
    @State private var handoffAt: Double?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            TimelineView(.animation(paused: start == nil)) { timeline in
                let t = start.map { timeline.date.timeIntervalSince($0) } ?? 0
                let frame = HearthSplashFrame(
                    t: t,
                    handoff: handoffAt.map { min(1, max(0, (t - $0) / handoffDuration)) } ?? 0,
                    reduceMotion: reduceMotion
                )
                scene(frame, size: size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(handoffAt == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.displayName)
        .task { await run() }
    }

    private var handoffDuration: Double { reduceMotion ? 0.35 : HearthSplash.handoffDuration }

    /// Plays, waits for the app (within the limits), hands off, and finishes.
    private func run() async {
        let begun = Date.now
        start = begun
        let minimum = reduceMotion ? 0.9 : HearthSplash.minimumDuration
        do {
            try await Task.sleep(for: .seconds(minimum))
            while !state.isReady, Date.now.timeIntervalSince(begun) < HearthSplash.maximumDuration {
                try await Task.sleep(for: .milliseconds(50))
            }
            handoffAt = Date.now.timeIntervalSince(begun)
            // Taps go to the app as soon as the color starts to rise.
            HearthSplashPresenter.passTouchesThrough()
            try await Task.sleep(for: .seconds(handoffDuration))
        } catch {
            // Cancelled (the window went away): nothing more to show.
        }
        onFinish()
    }

    // MARK: Drawing

    private var info: HearthAppInfo { app.info }
    private var isDark: Bool { colorScheme == .dark }

    @ViewBuilder
    private func scene(_ f: HearthSplashFrame, size: CGSize) -> some View {
        let tile: CGFloat = min(size.width, size.height) >= 600 ? 136 : 104
        let center = CGPoint(x: size.width / 2, y: size.height * 0.47)

        ZStack {
            liquid(f, size: size)

            ZStack {
                glow(f, tile: tile)
                    .position(center)
                if f.showsBlob {
                    blob(f, tile: tile)
                        .position(center)
                }
                ripple(f, tile: tile)
                    .position(center)
                icon(f, tile: tile)
                    .position(center)
                name(f)
                    .position(x: center.x, y: center.y + tile / 2 + (tile >= 136 ? 52 : 42))
            }
            .scaleEffect(f.lift.scale, anchor: UnitPoint(x: 0.5, y: center.y / max(size.height, 1)))
            .offset(y: -size.height * 0.24 * f.lift.travel)
            .opacity(f.lift.opacity)

            mark(f)
                .position(x: size.width / 2, y: size.height - (tile >= 136 ? 76 : 62))
        }
        .frame(width: size.width, height: size.height)
    }

    /// The app's color, filling the screen, rising away with a wavy edge in the handoff.
    private func liquid(_ f: HearthSplashFrame, size: CGSize) -> some View {
        let base = HearthSplash.backgroundColor(for: app)
        let deep = isDark ? Color.black.opacity(0.5) : Color(uiColor: splashUIColor(info.inkHex))
        return ZStack {
            base
            LinearGradient(colors: [deep.opacity(0), deep], startPoint: UnitPoint(x: 0.5, y: 0.3), endPoint: UnitPoint(x: 0.5, y: 0.95))
                .opacity(f.deepen * (isDark ? 1 : 0.85))
        }
        .clipShape(HearthSplashLiquidEdge(level: f.level, amplitude: f.waveAmplitude, phase: f.t * 7))
        .opacity(f.liquidOpacity)
    }

    private func glow(_ f: HearthSplashFrame, tile: CGFloat) -> some View {
        RadialGradient(colors: [Color.white.opacity(0.42), .white.opacity(0)], center: .center, startRadius: 0, endRadius: tile * 1.3)
            .frame(width: tile * 2.6, height: tile * 2.6)
            .scaleEffect(0.94 + 0.06 * sin(f.t * 2.4))
            .opacity(f.glow)
    }

    /// The droplets and the core, as metaballs: blurred, then cut at half opacity, so shapes
    /// that come close melt into one.
    private func blob(_ f: HearthSplashFrame, tile: CGFloat) -> some View {
        let color = isDark ? info.color : Color(uiColor: splashUIColor(info.colorHex).lightened(0.16))
        let box = tile * 3.4
        return Canvas { context, canvas in
            let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            context.addFilter(.alphaThreshold(min: 0.5, color: color))
            context.addFilter(.blur(radius: tile * 0.09))
            context.drawLayer { layer in
                for drop in f.droplets(tile: tile) where drop.diameter > 0.5 {
                    let rect = CGRect(x: mid.x + drop.offset.width - drop.diameter / 2,
                                      y: mid.y + drop.offset.height - drop.diameter / 2,
                                      width: drop.diameter, height: drop.diameter)
                    layer.fill(Path(ellipseIn: rect), with: .color(.white))
                }
                let core = f.core(tile: tile)
                if core.size.width > 0.5 {
                    let rect = CGRect(x: mid.x - core.size.width / 2, y: mid.y - core.size.height / 2,
                                      width: core.size.width, height: core.size.height)
                    layer.fill(Path(roundedRect: rect, cornerRadius: core.corner, style: .continuous), with: .color(.white))
                }
            }
        }
        .frame(width: box, height: box)
        .shadow(color: Color(uiColor: splashUIColor(info.inkHex)).opacity(isDark ? 0.3 : 0.4), radius: 14, y: 10)
        .opacity(f.blobOpacity)
    }

    private func ripple(_ f: HearthSplashFrame, tile: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
            .stroke(Color.white, lineWidth: 2)
            .frame(width: tile, height: tile)
            .scaleEffect(f.ripple.scale)
            .opacity(f.ripple.opacity)
    }

    /// The app's real icon (always the colorful light-mode one, which reads on its color).
    private func icon(_ f: HearthSplashFrame, tile: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
        return HearthSplashAppIcon(app: app, size: tile)
            .overlay {
                // A glint across the glass.
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: tile * 0.45)
                    .rotationEffect(.degrees(18))
                    .offset(x: tile * f.glint)
                    .opacity(f.glint > -1 && f.glint < 1.4 ? 1 : 0)
                    .blendMode(.plusLighter)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(isDark ? 0.28 : 0.5), lineWidth: 1.5) }
            .shadow(color: Color(uiColor: splashUIColor(isDark ? 0x000000 : info.inkHex)).opacity(0.45), radius: 16, y: 12)
            .scaleEffect(f.iconScale)
            .blur(radius: f.iconBlur)
            .opacity(f.iconOpacity)
    }

    private func name(_ f: HearthSplashFrame) -> some View {
        Text(app.displayName)
            .font(.system(size: 34, weight: .bold))
            .tracking(-0.4)
            .foregroundStyle(.white)
            .fixedSize()
            .offset(y: 14 * (1 - f.name))
            .blur(radius: 10 * (1 - f.name))
            .opacity(f.name)
    }

    /// The real Hearth logo (its dark-appearance version, with the white hearthstone) and name.
    private func mark(_ f: HearthSplashFrame) -> some View {
        HStack(spacing: 7) {
            HearthSplashLogo()
                .frame(width: 22, height: 22)
                .background {
                    // A soft light behind the flame, so its own petals read on any app's color.
                    Circle()
                        .fill(RadialGradient(colors: [.white.opacity(0.35), .white.opacity(0)], center: .center, startRadius: 0, endRadius: 16))
                        .frame(width: 34, height: 34)
                }
                .scaleEffect(x: 1 - 0.015 * f.flicker, y: 1 + 0.04 * f.flicker, anchor: .bottom)
            Text("Hearth")
                .font(.system(size: 15, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.92))
        }
        .fixedSize()
        .offset(y: 10 * (1 - f.mark))
        .blur(radius: 8 * (1 - f.mark))
        .opacity(f.mark * f.lift.opacity)
    }
}

// MARK: - The timeline

/// Every moving part at time `t` (seconds since the splash appeared), so the whole sequence is
/// one deterministic function of time.
nonisolated private struct HearthSplashFrame {
    let t: Double
    /// 0 until the handoff starts, then up to 1.
    let handoff: Double
    let reduceMotion: Bool

    // The beats, in seconds.
    private static let morphStart = 0.2
    private static let settleStart = 0.95
    private static let iconStart = 1.12

    struct Droplet { var offset: CGSize; var diameter: CGFloat }

    /// angle (radians), distance and size (fractions of the tile), delay.
    private static let droplets: [(Double, Double, Double, Double)] = [
        (-0.55, 0.86, 0.36, 0.00),
        (-2.62, 0.80, 0.30, 0.04),
        (2.27, 0.84, 0.34, 0.08),
        (0.72, 0.88, 0.27, 0.12),
        (-1.55, 0.96, 0.22, 0.16),
    ]

    func droplets(tile: CGFloat) -> [Droplet] {
        Self.droplets.map { angle, distance, size, delay in
            let out = easeOut(progress(t, 0.3 + delay, 0.66 + delay))
            let back = easeInOut(progress(t, 0.7 + delay, 1.1 + delay))
            let grow = easeOut(progress(t, Self.morphStart + delay, 0.42 + delay))
            let reach = distance * out * (1 - back)
            let swirl = angle + 0.4 * out * (1 - back)
            return Droplet(
                offset: CGSize(width: cos(swirl) * reach * tile, height: sin(swirl) * reach * tile),
                diameter: size * tile * grow * (1 - 0.55 * back)
            )
        }
    }

    /// The core: a wobbling drop that springs into the icon's rounded square.
    func core(tile: CGFloat) -> (size: CGSize, corner: CGFloat) {
        let appear = spring(t - Self.morphStart, damping: 0.6, frequency: 2.4)
        let settle = spring(t - Self.settleStart, damping: 0.5, frequency: 2.2)
        let side = tile * (0.55 * appear + (0.98 - 0.55) * settle)
        let wobble = 0.09 * sin(t * 2 * .pi * 2.4) * (1 - min(1, settle))
        let width = max(0, side * (1 + wobble))
        let height = max(0, side * (1 - wobble))
        let roundness = 0.5 - (0.5 - 0.225) * min(1, max(0, settle))
        return (CGSize(width: width, height: height), min(width, height) * roundness)
    }

    var showsBlob: Bool { !reduceMotion && t < 1.6 }
    var blobOpacity: Double { 1 - progress(t, 1.3, 1.55) }

    var iconOpacity: Double {
        reduceMotion ? easeOut(progress(t, 0.1, 0.45)) : easeOut(progress(t, Self.iconStart, 1.4))
    }
    var iconBlur: CGFloat { reduceMotion ? 0 : 6 * (1 - iconOpacity) }
    var iconScale: CGFloat {
        let settle = reduceMotion ? 1 : 0.94 + 0.06 * spring(t - Self.iconStart, damping: 0.45, frequency: 2.6)
        return settle * lift.scaleIcon
    }

    var ripple: (scale: CGFloat, opacity: Double) {
        guard !reduceMotion else { return (1, 0) }
        let p = progress(t, 1.08, 1.8)
        return (1 + 0.85 * easeOut(p), p > 0 && p < 1 ? 0.7 * (1 - p) : 0)
    }

    /// The glint's position across the icon, in tile widths (off the icon before and after).
    var glint: CGFloat { reduceMotion ? -2 : -1.2 + 2.6 * easeInOut(progress(t, 1.42, 2.0)) }

    var glow: Double { reduceMotion ? 0 : 0.9 * easeOut(progress(t, 1.25, 1.8)) * (1 - progress(handoff, 0, 0.4)) }
    var name: Double { reduceMotion ? easeOut(progress(t, 0.2, 0.5)) : easeOut(progress(t, 1.35, 1.95)) }
    var mark: Double { reduceMotion ? easeOut(progress(t, 0.3, 0.6)) : easeOut(progress(t, 1.65, 2.25)) }
    var flicker: Double { reduceMotion ? 0 : (sin(t * 2 * .pi / 2.4) + 1) / 2 }
    var deepen: Double { reduceMotion ? 1 : easeInOut(progress(t, 0.3, 1.4)) }

    // The handoff.

    /// Where the color's bottom edge sits, as a fraction of the height (past 1 covers it all).
    var level: Double { reduceMotion ? 1.05 : 1.05 - 1.15 * easeInOut(handoff) }
    var waveAmplitude: CGFloat { reduceMotion ? 0 : 18 * sin(.pi * handoff) }
    var liquidOpacity: Double { reduceMotion ? 1 - handoff : 1 - progress(handoff, 0.6, 1) }

    /// The icon and name rising toward the header and fading.
    var lift: (scale: CGFloat, scaleIcon: CGFloat, travel: CGFloat, opacity: Double) {
        if reduceMotion { return (1, 1, 0, 1 - handoff) }
        let h = easeInOut(handoff)
        return (1 - 0.4 * h, 1, h, 1 - progress(handoff, 0, 0.65))
    }
}

// MARK: - Pieces

/// The color layer's shape: everything above a wavy bottom edge.
nonisolated private struct HearthSplashLiquidEdge: Shape {
    var level: Double
    var amplitude: CGFloat
    var phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let baseline = rect.minY + rect.height * level
        path.move(to: CGPoint(x: rect.minX, y: rect.minY - 1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - 1))
        let steps = 48
        for step in stride(from: steps, through: 0, by: -1) {
            let x = rect.minX + rect.width * CGFloat(step) / CGFloat(steps)
            let wave = sin(Double(x / max(rect.width, 1)) * 2 * .pi * 1.4 + phase)
                + 0.35 * sin(Double(x / max(rect.width, 1)) * 2 * .pi * 2.7 - phase * 1.3)
            path.addLine(to: CGPoint(x: x, y: baseline + amplitude * CGFloat(wave)))
        }
        path.closeSubpath()
        return path
    }
}

/// The app's icon from Assets › Hearth, always the light (colorful) version, or a tile in its
/// color when the image is missing.
private struct HearthSplashAppIcon: View {
    let app: HearthApp
    let size: CGFloat

    var body: some View {
        Group {
            if let image = UIImage(named: "Hearth/\(app.rawValue)", in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: .light)) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: app.info.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(app.info.color)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The Hearth logo from Assets › Hearth/hearth, in its dark-appearance version (white
/// hearthstone), which reads on every app's color.
private struct HearthSplashLogo: View {
    var body: some View {
        if let image = UIImage(named: "Hearth/hearth", in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: .dark)) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "flame.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Math and colors

nonisolated private func progress(_ t: Double, _ start: Double, _ end: Double) -> Double {
    min(1, max(0, (t - start) / (end - start)))
}

nonisolated private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

nonisolated private func easeInOut(_ x: Double) -> Double {
    x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}

/// An underdamped spring from 0 to 1 (with overshoot), `x` seconds after it starts.
nonisolated private func spring(_ x: Double, damping: Double, frequency: Double) -> Double {
    guard x > 0 else { return 0 }
    let omega = 2 * Double.pi * frequency
    let damped = omega * (1 - damping * damping).squareRoot()
    let decay = exp(-damping * omega * x)
    return 1 - decay * (cos(damped * x) + damping * omega / damped * sin(damped * x))
}

nonisolated private func splashUIColor(_ hex: UInt32) -> UIColor {
    UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

nonisolated private extension UIColor {
    func darkened(_ amount: CGFloat) -> UIColor { blended(with: .black, amount: amount) }
    func lightened(_ amount: CGFloat) -> UIColor { blended(with: .white, amount: amount) }

    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: a1)
    }
}

// MARK: - Previews

/// Tap to play it again.
private struct HearthSplashPreview: View {
    let app: HearthApp
    @State private var run = 0
    @State private var finished = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            if finished {
                Button("Play Again") {
                    finished = false
                    run += 1
                }
                .buttonStyle(.borderedProminent)
                .tint(app.info.color)
            } else {
                HearthSplashView(app: app, state: HearthSplashState()) { finished = true }
                    .id(run)
            }
        }
    }
}

#Preview("BigTable") { HearthSplashPreview(app: .bigtable) }
#Preview("Suffice") { HearthSplashPreview(app: .suffice) }
#Preview("Sated") { HearthSplashPreview(app: .sated) }
#Preview("Caloma, dark") { HearthSplashPreview(app: .caloma).preferredColorScheme(.dark) }
#Preview("Hearken") { HearthSplashPreview(app: .hearken) }
