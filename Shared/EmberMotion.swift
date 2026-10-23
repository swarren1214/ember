import SwiftUI
#if os(watchOS)
import WatchKit
#endif

// Ember's motion, on iPhone and Apple Watch, in the five Hearth app colors:
//
//   Edge ring     a soft glow around the screen's edge: bright while listening, a thin fast line
//                 while thinking, breathing while Ember speaks
//   Spectrum      seven bars that follow your voice (listening)
//   Five Embers   one dot per app, circling (thinking)
//   Ember Voice   a soft color core that pulses with speech, rings rippling out (speaking)
//   Mic ring      the talk button's turning color ring (idle)
//
// Nothing here blurs anything frame by frame, which is what made the old orb stall. Everything
// soft is either a gradient that fades to nothing (it looks blurred and costs nothing), or a
// shape blurred once into a picture when first needed (`EmberBaked`). Each frame then only turns,
// grows or fades what's already drawn: work the GPU does almost for free, even on the Watch.
// Every motion comes from the clock (TimelineView), so nothing keeps running between frames and
// nothing can freeze after the screen dims; frames pause while the Watch is dimmed.

enum EmberPalette {
    /// BigTable, Sated, Suffice, Hearken, Caloma (the lighter tints, for a dark background).
    static let colors: [Color] = [
        Color(red: 1.0, green: 0.518, blue: 0.4),     // #FF8466
        Color(red: 1.0, green: 0.706, blue: 0.259),   // #FFB442
        Color(red: 0.271, green: 0.839, blue: 0.608), // #45D69B
        Color(red: 0.353, green: 0.663, blue: 1.0),   // #5AA9FF
        Color(red: 1.0, green: 0.435, blue: 0.557),   // #FF6F8E
    ]

    static var wheel: AngularGradient {
        AngularGradient(colors: colors + [colors[0]], center: .center)
    }
}

// MARK: - Baked blur

/// Soft shapes blurred once into a picture, kept for reuse.
@MainActor
enum EmberBaked {
    private static var cache: [String: Image] = [:]

    static func image<Content: View>(_ key: String, size: CGSize, @ViewBuilder _ content: () -> Content) -> Image? {
        let fullKey = "\(key)-\(Int(size.width))x\(Int(size.height))"
        if let cached = cache[fullKey] { return cached }
        guard size.width > 1, size.height > 1 else { return nil }
        let renderer = ImageRenderer(content: content().frame(width: size.width, height: size.height))
        // Soft shapes need few pixels.
        renderer.scale = 1.5
        guard let cgImage = renderer.cgImage else { return nil }
        let image = Image(decorative: cgImage, scale: renderer.scale)
        if cache.count > 40 { cache.removeAll() }
        cache[fullKey] = image
        return image
    }
}

/// How often frames are drawn: 60 a second on iPhone, 30 on the Watch.
private enum MotionClock {
    #if os(watchOS)
    static let interval = 1.0 / 30
    #else
    static let interval = 1.0 / 60
    #endif
}

// MARK: - Edge ring

/// The glow around the screen's edge. Put it behind or over the screen's content, ignoring the
/// safe area; it never takes touches.
struct HearthEdgeGlow: View {
    enum Mode: Equatable { case off, listening, thinking, speaking }

    var mode: Mode
    /// The screen's corner radius (iPhone about 55, Watch about 40).
    var cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bloom = EmberBaked.image("edge-bloom-\(Int(cornerRadius))", size: size) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white, lineWidth: min(size.width, size.height) * 0.06)
                    .blur(radius: min(size.width, size.height) * 0.055)
            }
            let line = EmberBaked.image("edge-line-\(Int(cornerRadius))", size: size) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white, lineWidth: 3)
                    .blur(radius: 1.2)
            }
            TimelineView(.animation(minimumInterval: MotionClock.interval, paused: mode == .off || isLuminanceReduced || reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                let speed: Double = mode == .thinking ? 280 : mode == .speaking ? 45 : 90
                let angle = Angle.degrees(reduceMotion ? 0 : t * speed)
                let breathe = 0.5 + 0.5 * sin(t * 2 * .pi / 1.1)
                let side = hypot(size.width, size.height)
                ZStack {
                    if let bloom {
                        colorWheel(side: side, angle: angle)
                            .mask { bloom.resizable() }
                            .opacity(bloomOpacity(breathe: breathe))
                    }
                    if let line {
                        colorWheel(side: side, angle: angle)
                            .mask { line.resizable() }
                            .opacity(lineOpacity)
                    }
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .opacity(mode == .off ? 0 : 1)
        .animation(.easeInOut(duration: 0.5), value: mode)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A square of the five colors, larger than the screen, that only turns.
    private func colorWheel(side: CGFloat, angle: Angle) -> some View {
        Rectangle()
            .fill(EmberPalette.wheel)
            .frame(width: side, height: side)
            .rotationEffect(angle)
    }

    private func bloomOpacity(breathe: Double) -> Double {
        switch mode {
        case .off: 0
        case .listening: 0.95
        case .thinking: 0.45
        case .speaking: 0.3 + 0.4 * breathe
        }
    }

    private var lineOpacity: Double {
        switch mode {
        case .off, .speaking: 0
        case .listening: 0.7
        case .thinking: 0.85
        }
    }
}

// MARK: - Spectrum (listening)

/// Seven bars across the app colors, following the microphone level.
struct SpectrumBars: View {
    /// 0...1, read each frame (the iPhone's microphone meter).
    var meter: EmberLevelMeter? = .shared
    var barWidth: CGFloat = 6
    var height: CGFloat = 56

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let shape: [Double] = [0.45, 0.7, 0.9, 1, 0.85, 0.65, 0.4]
    private static let colors: [Color] = [0, 1, 2, 3, 4, 1, 0].map { EmberPalette.colors[$0] }

    var body: some View {
        TimelineView(.animation(minimumInterval: MotionClock.interval)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            let level = max(meter?.value ?? 0.3, 0.12)
            HStack(spacing: barWidth * 0.8) {
                ForEach(0..<7, id: \.self) { index in
                    let wobble = reduceMotion ? 0.8 : 0.65 + 0.35 * sin(t * 9 + Double(index) * 1.3)
                    let fraction = min(1, max(0.1, Self.shape[index] * level * 1.6 * wobble))
                    ZStack {
                        // The glow: a soft ellipse that fades to nothing, no blur.
                        Ellipse()
                            .fill(RadialGradient(colors: [Self.colors[index].opacity(0.55), Self.colors[index].opacity(0)],
                                                 center: .center, startRadius: 0, endRadius: barWidth * 2.2))
                            .frame(width: barWidth * 4.4, height: height * fraction + barWidth * 3)
                        Capsule()
                            .fill(Self.colors[index])
                            .frame(width: barWidth, height: max(barWidth, height * fraction))
                    }
                    .frame(width: barWidth, height: height)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Five Embers (thinking)

/// One glowing dot per app, circling.
struct FiveEmbers: View {
    var size: CGFloat = 40

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.animation(minimumInterval: MotionClock.interval, paused: reduceMotion || isLuminanceReduced)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            let dot = size * 0.2
            let radius = size * 0.36 * (1 + 0.06 * sin(t * 2 * .pi / 1.6))
            ZStack {
                ForEach(0..<5, id: \.self) { index in
                    let angle = Double(index) / 5 * 2 * .pi - .pi / 2
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [EmberPalette.colors[index].opacity(0.6), EmberPalette.colors[index].opacity(0)],
                                                 center: .center, startRadius: 0, endRadius: dot * 1.5))
                            .frame(width: dot * 3, height: dot * 3)
                        Circle()
                            .fill(EmberPalette.colors[index])
                            .frame(width: dot, height: dot)
                    }
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                }
            }
            .rotationEffect(.radians(reduceMotion ? 0 : t * 2 * .pi / 1.6))
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Ember Voice (speaking)

/// A soft color core that pulses like speech, with rings rippling outward.
struct EmberVoiceGlow: View {
    var size: CGFloat = 40
    var speaking = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let ripple = EmberBaked.image("voice-ripple", size: CGSize(width: 120, height: 120)) {
            Circle()
                .strokeBorder(EmberPalette.wheel, lineWidth: 6)
                .blur(radius: 3)
                .padding(4)
        }
        TimelineView(.animation(minimumInterval: MotionClock.interval, paused: !speaking || reduceMotion || isLuminanceReduced)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            let envelope = speaking && !reduceMotion ? Self.speech(t) : 0.3
            ZStack {
                if let ripple, speaking, !reduceMotion {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = (t / 1.8 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                        ripple
                            .resizable()
                            .frame(width: size, height: size)
                            .scaleEffect(0.45 + 0.75 * phase)
                            .opacity(0.85 * (1 - phase))
                    }
                }
                // The core: the color wheel with edges that fade to nothing.
                Circle()
                    .fill(EmberPalette.wheel)
                    .mask {
                        Circle().fill(RadialGradient(colors: [.white, .white.opacity(0.8), .white.opacity(0)],
                                                     center: .center, startRadius: 0, endRadius: size * 0.24))
                    }
                    .frame(width: size * 0.48, height: size * 0.48)
                    .rotationEffect(.radians(t * 2 * .pi / 5))
                    .scaleEffect(0.85 + 0.35 * envelope)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A speech-like rhythm: syllables inside phrases.
    private static func speech(_ t: Double) -> Double {
        let syllable = max(0, sin(t * 2 * .pi * 4.2) * 0.6 + sin(t * 2 * .pi * 1.9 + 2) * 0.4)
        let phrase = (sin(t * 0.9) + sin(t * 0.37 + 1)) > -0.4 ? 1.0 : 0.35
        return min(1, syllable * phrase)
    }
}

// MARK: - Mic ring (idle)

/// The talk button's look: a turning ring of the five colors with a soft glow, around a dark
/// center holding the microphone.
struct HearthMicRing: View {
    var size: CGFloat = 46
    var lineWidth: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || isLuminanceReduced)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [EmberPalette.colors[1].opacity(0.35), .clear],
                                         center: .center, startRadius: size * 0.3, endRadius: size * 0.75))
                    .frame(width: size * 1.5, height: size * 1.5)
                Circle()
                    .fill(EmberPalette.wheel)
                    .rotationEffect(.radians(reduceMotion ? 0 : t * 2 * .pi / 6))
                Circle()
                    .fill(Color(white: 0.11))
                    .padding(lineWidth)
                Image(systemName: "mic.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// The microphone's loudness for the animations, written on the audio thread and read each
/// frame. Not observed: animations redraw on their own clock.
nonisolated final class EmberLevelMeter: @unchecked Sendable {
    static let shared = EmberLevelMeter()
    private let lock = NSLock()
    private var stored = 0.0

    var value: Double {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
