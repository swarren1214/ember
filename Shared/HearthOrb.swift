import SwiftUI

// HearthOrb.swift: the Hearth assistant's orb, shared by every app that talks (Ember, Ask
// Suffice, Sated's Coach), so talking to any Hearth app looks and feels the same. Canonical copy
// in ~/Developer/hearthkit; `bash sync.sh` copies it to each app's Services/Hearth (and to
// ember/Shared, so Ember's Watch has it too). Edit it here, never in a copy.
//
// A sphere of Apple's Liquid Glass with a living light inside it, in the five Hearth app colors
// ("Ember Redesign" canvas › Light · Liquid Glass Orb):
//
//   Idle       the light drifts slowly, the glass breathes
//   Listening  the light brightens and sinks toward you, swelling with your voice; the glass
//              wobbles like liquid
//   Thinking   the colors pull in and swirl around a bright white center
//   Speaking   the light pulses with speech and the glow around the orb grows
//
// The lights wander on their own: each color's path is a sum of slow waves whose periods don't
// line up, so the pattern never visibly repeats, and each one swells and dims on its own rhythm.
// The colors cross through the middle, where they meet in a white heart.
//
// Cheap enough for the Watch: every soft shape is blurred once into a picture (HearthBaked), and
// each frame only moves, scales and fades those pictures. The glass is a real Liquid Glass layer
// over the light, so the system draws its refraction and highlights. Frames pause when the Watch
// dims or Reduce Motion is on.

struct HearthOrb: View {
    enum Mode: Equatable { case idle, listening, thinking, speaking }

    var mode: Mode = .idle
    var size: CGFloat
    /// The microphone's level, 0…1, while listening. Pass it when the app has it as a value (it
    /// redraws with it); leave it nil to read `meter` each frame instead.
    var level: Double? = nil
    var meter: HearthLevelMeter? = .shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var motion = OrbMotion()

    var body: some View {
        let still = reduceMotion || isLuminanceReduced
        TimelineView(.animation(minimumInterval: OrbMotion.interval, paused: still)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let voice = mode == .listening ? (level ?? meter?.value ?? 0) : 0
            let state = motion.step(to: OrbTarget(mode), at: now, level: voice, still: still)
            OrbBody(size: size, state: state)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The five Hearth app colors, as the orb's light: BigTable, Sated, Suffice, Hearken, Caloma
/// (the lighter tints, which glow on the orb's dark inside).
enum HearthOrbPalette {
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

/// Soft shapes blurred once into a picture, kept for reuse.
@MainActor
enum HearthBaked {
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

/// The microphone's loudness, written on the audio thread and read each frame. Not observed:
/// the orb redraws on its own clock.
nonisolated final class HearthLevelMeter: @unchecked Sendable {
    static let shared = HearthLevelMeter()
    private let lock = NSLock()
    private var stored = 0.0

    var value: Double {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - What each mode looks like

/// Where the orb is heading for a mode; the orb eases toward it, so changes flow.
private struct OrbTarget {
    var speed: Double       // how fast the lights wander
    var spread: Double      // how far they wander from the middle
    var light: Double       // brightness of the colors
    var heart: Double       // brightness of the white center
    var aura: Double        // the glow around the orb
    var scale: Double       // size of the light inside the glass
    var drop: Double        // how far the light sinks (toward the person)
    var swirl: Double       // degrees a second the light turns
    var wobble: Double      // how much the glass sways like liquid
    var pulse: Double       // speech pulse strength

    init(_ mode: HearthOrb.Mode) {
        switch mode {
        case .idle:
            self = .init(speed: 0.55, spread: 1, light: 0.72, heart: 0.5, aura: 0.16, scale: 0.86, drop: 0, swirl: 3, wobble: 0.006, pulse: 0)
        case .listening:
            self = .init(speed: 1.3, spread: 1.05, light: 1, heart: 0.8, aura: 0.42, scale: 1.04, drop: 0.07, swirl: 6, wobble: 0.022, pulse: 0)
        case .thinking:
            self = .init(speed: 2.1, spread: 0.45, light: 0.95, heart: 1, aura: 0.3, scale: 0.8, drop: 0, swirl: 42, wobble: 0.01, pulse: 0)
        case .speaking:
            self = .init(speed: 1.1, spread: 0.85, light: 1, heart: 1, aura: 0.55, scale: 1, drop: 0, swirl: 6, wobble: 0.02, pulse: 1)
        }
    }

    init(speed: Double, spread: Double, light: Double, heart: Double, aura: Double, scale: Double, drop: Double,
         swirl: Double, wobble: Double, pulse: Double) {
        self.speed = speed; self.spread = spread; self.light = light; self.heart = heart; self.aura = aura
        self.scale = scale; self.drop = drop; self.swirl = swirl; self.wobble = wobble; self.pulse = pulse
    }
}

/// One frame of the orb.
private struct OrbState {
    var phase: Double = 0       // the lights' own clock (runs faster or slower by mode)
    var time: Double = 0        // wall clock, for the glass and the pulse
    var spread = 1.0
    var light = 0.72
    var heart = 0.5
    var aura = 0.16
    var scale = 0.86
    var drop = 0.0
    var swirlAngle = 0.0
    var wobble = 0.006
    var pulse = 0.0
    var level = 0.0
}

/// Eases the orb between modes, frame by frame, and keeps the lights' clock running at the
/// mode's speed without jumps.
private final class OrbMotion {
    #if os(watchOS)
    static let interval = 1.0 / 30
    #else
    static let interval = 1.0 / 60
    #endif

    private var state = OrbState()
    private var speed = 0.55
    private var swirl = 3.0
    private var last: Double?

    func step(to target: OrbTarget, at now: Double, level: Double, still: Bool) -> OrbState {
        let dt = min(max(now - (last ?? now), 0), 0.1)
        last = now
        // About two thirds of the way there in half a second.
        let k = still ? 1 : 1 - exp(-dt / 0.45)
        func ease(_ value: inout Double, _ goal: Double) { value += (goal - value) * k }
        ease(&speed, target.speed)
        ease(&swirl, target.swirl)
        ease(&state.spread, target.spread)
        ease(&state.light, target.light)
        ease(&state.heart, target.heart)
        ease(&state.aura, target.aura)
        ease(&state.scale, target.scale)
        ease(&state.drop, target.drop)
        ease(&state.wobble, target.wobble)
        ease(&state.pulse, target.pulse)
        // The voice: rises fast, falls slowly, like a meter.
        let rise = level > state.level ? 1 - exp(-dt / 0.05) : 1 - exp(-dt / 0.25)
        state.level += (level - state.level) * rise
        if !still {
            state.phase += dt * speed
            state.swirlAngle = (state.swirlAngle + dt * swirl).truncatingRemainder(dividingBy: 360)
            state.time = now.truncatingRemainder(dividingBy: 3600)
        }
        return state
    }
}

// MARK: - Drawing

private struct OrbBody: View {
    var size: CGFloat
    var state: OrbState

    /// Each color's wandering: two slow waves across, two down, with periods that don't line up,
    /// plus its own swell. (rest x, rest y, then frequencies and phases.)
    private struct Path {
        var x, y: Double
        var fx1, fx2, fy1, fy2: Double
        var px, py: Double
        var fs1, fs2: Double
    }

    private static let paths: [Path] = [
        Path(x: -0.12, y: -0.08, fx1: 0.53, fx2: 1.31, fy1: 0.71, fy2: 1.73, px: 0.0, py: 1.9, fs1: 1.7, fs2: 2.9),
        Path(x: 0.13, y: -0.13, fx1: 0.61, fx2: 1.47, fy1: 0.47, fy2: 1.19, px: 2.3, py: 0.4, fs1: 1.4, fs2: 3.3),
        Path(x: 0.12, y: 0.13, fx1: 0.43, fx2: 1.67, fy1: 0.67, fy2: 1.37, px: 4.1, py: 3.0, fs1: 2.1, fs2: 2.6),
        Path(x: -0.14, y: 0.12, fx1: 0.71, fx2: 1.09, fy1: 0.53, fy2: 1.61, px: 1.2, py: 5.2, fs1: 1.2, fs2: 3.7),
        Path(x: 0.0, y: 0.0, fx1: 0.37, fx2: 1.23, fy1: 0.59, fy2: 1.43, px: 3.4, py: 2.2, fs1: 1.9, fs2: 3.1),
    ]

    /// The three sparks: small, pale, fast, fading in and out.
    private static let sparks: [(color: Int, path: Path, blink: Double)] = [
        (1, Path(x: 0, y: 0, fx1: 1.9, fx2: 3.1, fy1: 2.3, fy2: 2.7, px: 0.5, py: 1.1, fs1: 0, fs2: 0), 1.3),
        (2, Path(x: 0, y: 0, fx1: 2.2, fx2: 2.9, fy1: 1.7, fy2: 3.3, px: 2.7, py: 4.0, fs1: 0, fs2: 0), 1.7),
        (3, Path(x: 0, y: 0, fx1: 1.6, fx2: 3.5, fy1: 2.6, fy2: 1.9, px: 5.1, py: 0.3, fs1: 0, fs2: 0), 1.1),
    ]

    var body: some View {
        let blob = HearthBaked.image("orb-blob", size: CGSize(width: 96, height: 96)) {
            Circle().fill(.white).padding(26).blur(radius: 13)
        }
        let spark = HearthBaked.image("orb-spark", size: CGSize(width: 48, height: 48)) {
            Circle().fill(.white).padding(16).blur(radius: 5)
        }
        let heartGlow = HearthBaked.image("orb-heart", size: CGSize(width: 96, height: 96)) {
            Circle().fill(.white).padding(28).blur(radius: 16)
        }
        let heartCore = HearthBaked.image("orb-core", size: CGSize(width: 64, height: 64)) {
            Circle().fill(.white).padding(20).blur(radius: 5)
        }
        let halo = HearthBaked.image("orb-aura", size: CGSize(width: 120, height: 120)) {
            Circle().fill(.white).padding(30).blur(radius: 18)
        }
        let caustic = HearthBaked.image("orb-caustic", size: CGSize(width: 96, height: 40)) {
            Capsule().fill(.white).padding(.horizontal, 18).padding(.vertical, 12).blur(radius: 7)
        }

        let p = state.phase
        let t = state.time
        let speech = state.pulse * Self.speech(t)
        let voice = state.level
        let lightScale = state.scale * (1 + 0.22 * voice + 0.1 * speech)
        let wobbleX = 1 + state.wobble * sin(t * 3.7)
        let wobbleY = 1 - state.wobble * sin(t * 3.7 + 0.6)
        let breathe = 1 + 0.012 * sin(t * 1.25)
        let blobSize = size * 0.62

        ZStack {
            // The glow around the orb, turning slowly through the colors.
            if let halo {
                Circle()
                    .fill(HearthOrbPalette.wheel)
                    .frame(width: size * 1.5, height: size * 1.5)
                    .rotationEffect(.degrees(t * 20))
                    .mask { halo.resizable().frame(width: size * 1.5, height: size * 1.5) }
                    .opacity(state.aura * (1 + 0.5 * speech))
            }

            // Inside the glass: a dark sphere with the light in it.
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.1), Color(white: 0.03)],
                                         center: .center, startRadius: 0, endRadius: size * 0.55))

                ZStack {
                    if let blob {
                        ForEach(0..<5, id: \.self) { index in
                            let path = Self.paths[index]
                            let dx = path.x + state.spread * (0.2 * sin(path.fx1 * p + path.px) + 0.09 * sin(path.fx2 * p + path.py))
                            let dy = path.y + state.spread * (0.2 * sin(path.fy1 * p + path.py) + 0.09 * sin(path.fy2 * p + path.px))
                            let swell = 1 + 0.16 * sin(path.fs1 * p + path.px) + 0.08 * sin(path.fs2 * p)
                            let glow = 0.82 + 0.18 * sin(path.fs2 * p + path.py)
                            blob.resizable()
                                .frame(width: blobSize, height: blobSize)
                                .colorMultiply(HearthOrbPalette.colors[index])
                                .scaleEffect(swell)
                                .offset(x: dx * size, y: dy * size)
                                .opacity(state.light * glow)
                                .blendMode(.plusLighter)
                        }
                    }
                    if let spark {
                        ForEach(0..<3, id: \.self) { index in
                            let item = Self.sparks[index]
                            let path = item.path
                            let dx = 0.28 * sin(path.fx1 * p + path.px) * cos(path.fx2 * p * 0.5)
                            let dy = 0.28 * sin(path.fy1 * p + path.py) * cos(path.fy2 * p * 0.5)
                            let blink = max(0, sin(item.blink * p * 1.7 + path.px))
                            spark.resizable()
                                .frame(width: size * 0.24, height: size * 0.24)
                                .colorMultiply(HearthOrbPalette.colors[item.color].mix(with: .white, by: 0.55))
                                .offset(x: dx * size, y: dy * size)
                                .opacity(0.9 * blink * state.light)
                                .blendMode(.plusLighter)
                        }
                    }
                    // Where the colors meet: a white heart.
                    if let heartGlow, let heartCore {
                        let beat = 1 + 0.07 * sin(t * 2.7) + 0.04 * sin(t * 4.3 + 1) + 0.12 * speech
                        heartGlow.resizable()
                            .frame(width: size * 0.62, height: size * 0.62)
                            .scaleEffect(beat)
                            .opacity(0.75 * state.heart)
                            .blendMode(.plusLighter)
                        heartCore.resizable()
                            .frame(width: size * 0.3, height: size * 0.3)
                            .scaleEffect(beat)
                            .opacity(state.heart)
                            .blendMode(.plusLighter)
                    }
                }
                .compositingGroup()
                .rotationEffect(.degrees(state.swirlAngle))
                .scaleEffect(lightScale)
                .offset(y: state.drop * size)

                // Light gathered where it leaves the glass, at the bottom.
                if let caustic {
                    Rectangle()
                        .fill(LinearGradient(colors: [HearthOrbPalette.colors[3], HearthOrbPalette.colors[2], HearthOrbPalette.colors[1],
                                                      HearthOrbPalette.colors[0], HearthOrbPalette.colors[4]],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: size * 0.62, height: size * 0.2)
                        .mask { caustic.resizable() }
                        .offset(y: size * 0.37)
                        .opacity(0.3 + 0.35 * state.aura + 0.2 * voice)
                        .blendMode(.plusLighter)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            // The shell: Liquid Glass over the light, so the system bends and catches it.
            .overlay {
                Color.clear
                    .glassEffect(.clear, in: Circle())
            }
            .overlay {
                // A thin bright rim, so the sphere reads as glass even when small.
                Circle()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: max(0.75, size * 0.008))
            }
            .scaleEffect(x: wobbleX * breathe, y: wobbleY * breathe)
        }
        .frame(width: size, height: size)
    }

    /// A speech-like rhythm: syllables inside phrases, 0…1.
    private static func speech(_ t: Double) -> Double {
        let syllable = max(0, sin(t * 2 * .pi * 4.2) * 0.6 + sin(t * 2 * .pi * 1.9 + 2) * 0.4)
        let phrase = (sin(t * 0.9) + sin(t * 0.37 + 1)) > -0.4 ? 1.0 : 0.35
        return min(1, syllable * phrase)
    }
}

// MARK: - The talk button

/// The orb as a button-sized talk control (the composer's talk button, the Watch face).
struct HearthOrbButtonLabel: View {
    var size: CGFloat
    var mode: HearthOrb.Mode = .idle

    var body: some View {
        HearthOrb(mode: mode, size: size)
            .contentShape(.circle)
    }
}

/// "Thinking…" with a small thinking orb, for a typed conversation's waiting row.
struct HearthOrbThinking: View {
    var text = "Thinking…"
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: 12) {
            HearthOrb(mode: .thinking, size: size)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(spacing: 40) {
        HearthOrb(mode: .listening, size: 220)
        HStack(spacing: 30) {
            HearthOrb(mode: .idle, size: 80)
            HearthOrb(mode: .thinking, size: 80)
            HearthOrb(mode: .speaking, size: 80)
        }
    }
    .padding(40)
    .background(.black)
}
