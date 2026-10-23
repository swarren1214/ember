import SwiftUI

// The orb: Ember's one moving part, the same on iPhone and Apple Watch (compiled into both).
// Design: the "Ember Orb Motion" prototype.
//
// How it's drawn
// - The flame is three blobs of light and a bright core, each a radial gradient that fades to
//   nothing well inside the area it fills, so no edge is ever drawn.
// - That flame is drawn as a layer several times at different blurs, added together: a wide
//   halo, the soft body, and a faint sharper pass. It reads as light seen through squinted
//   eyes rather than shapes stacked on shapes.
//
// How it moves
// - Every motion advances a phase by (time since the last frame × speed), and every value eases
//   toward its target. A state change can only bend the motion, never jump it. (The first
//   version multiplied the clock by a speed; the clock is about 800 million seconds, so
//   changing the speed jumped the rotation by billions of radians: the "seizure".)
// - Listening follows the microphone: louder makes the orb at most 8% bigger and the flame and
//   halo brighter, never faster. Fast attack, slow release, so syllables read as pulses.
// - Thinking: the flame draws in and dims a little, sparks spiral in from the edge and are
//   swallowed by the core, and the core swells on a slow two-second breath.
// - Answering: brightness follows Ember speaking.
// - Reduce Motion keeps the glow and the voice response and drops the drifting.
//
// The orb draws past its frame (the halo needs the room); place it by its frame as usual.

nonisolated enum EmberOrbMood: Equatable, Sendable {
    case idle, listening, thinking, answering
}

/// The microphone's loudness for the orb, written on the audio thread and read each frame. It
/// isn't observed: the orb redraws on its own clock, so the level never re-renders the screen
/// around it (twenty screen updates a second while listening were part of the stutter).
nonisolated final class EmberLevelMeter: @unchecked Sendable {
    static let shared = EmberLevelMeter()
    private let lock = NSLock()
    private var stored = 0.0

    var value: Double {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct EmberOrb: View {
    var mood: EmberOrbMood
    /// Microphone loudness, 0...1 (listening), when it's passed in (the Watch).
    var level: Double = 0
    /// Or read each frame from a meter (the iPhone).
    var meter: EmberLevelMeter?
    /// Ember is speaking (answering): the glow follows a speech-like rhythm.
    var speaking: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = EmberOrbClock()

    /// How far past its frame the halo reaches, as a multiple of the frame.
    private static let bleed: CGFloat = 2.2

    var body: some View {
        #if os(watchOS)
        // The Watch can't redraw blurred layers every frame (it stalled the whole app): a few
        // soft gradients moved by Core Animation instead, with the same colors and moods.
        EmberOrbLite(mood: mood, speaking: speaking)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #else
        canvasBody
        #endif
    }

    private var canvasBody: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            TimelineView(.animation) { timeline in
                let frame = clock.advance(to: timeline.date, mood: mood, level: meter?.value ?? level, speaking: speaking, reduceMotion: reduceMotion)
                // Drawn off the main thread (from this frame's copy of the state), so a busy
                // moment elsewhere doesn't freeze it.
                Canvas(rendersAsynchronously: true) { @Sendable context, size in
                    frame.draw(in: &context, size: size, orbRadius: side / 2)
                }
                .frame(width: side * Self.bleed, height: side * Self.bleed)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Keeps the orb's state between frames. Not observed, so it never causes a redraw of its own.
final class EmberOrbClock {
    private var engine = EmberOrbEngine()

    func advance(to date: Date, mood: EmberOrbMood, level: Double, speaking: Bool, reduceMotion: Bool) -> EmberOrbEngine {
        engine.step(to: date, mood: mood, level: level, speaking: speaking, reduceMotion: reduceMotion)
        return engine
    }
}

/// The orb's state for one frame: phases, eased values and sparks. A value, so a frame being
/// drawn on another thread never sees the next one being worked out.
nonisolated struct EmberOrbEngine: Sendable {
    private struct Spark {
        var angle: Double
        var distance: Double
        var life: Double
    }

    private var lastDate: Date?
    // Phases (radians), advanced by dt × speed.
    private var spin = 0.0
    private var morph = 0.0
    private var breath = 0.0
    private var corePhase = 0.0
    private var speechClock = 0.0
    // Eased values.
    private var level = 0.0
    private var speech = 0.0
    private var glow = 0.5
    private var brightness = 1.0
    private var inward = 0.0
    private var voiceScale = 1.0
    private var sparks: [Spark] = []
    private var mood: EmberOrbMood = .idle

    /// The flame is laid down a few times and added together: a wide, faint bloom (the flame
    /// drawn larger; its gradients are already soft, so it needs no blur), the body with one
    /// modest blur, and a faint crisp pass. Blurring a large layer is the expensive part of a
    /// frame, and while Ember's voice and the on-device model share the GPU, a frame that blurs
    /// three big layers waits its turn and the orb stutters. One small blur keeps it smooth.
    private struct Pass { var scale: Double; var blur: Double; var opacity: Double }
    #if os(watchOS)
    private static let passes = [Pass(scale: 1.6, blur: 0, opacity: 0.4), Pass(scale: 1, blur: 0.1, opacity: 1)]
    private static let sparkRate = 10.0
    #else
    private static let passes = [Pass(scale: 1.7, blur: 0, opacity: 0.38), Pass(scale: 1, blur: 0.1, opacity: 0.95), Pass(scale: 1, blur: 0, opacity: 0.3)]
    private static let sparkRate = 22.0
    #endif

    mutating func step(to date: Date, mood: EmberOrbMood, level input: Double, speaking: Bool, reduceMotion: Bool) {
        let dt = min(max(date.timeIntervalSince(lastDate ?? date), 0), 0.05)
        lastDate = date
        self.mood = mood

        // The voice: fast attack, slow release.
        let heard = mood == .listening ? min(max(input, 0), 1) : 0
        level = Self.follow(level, heard, dt)
        speechClock += dt
        let said = mood == .answering && speaking ? Self.speechEnvelope(speechClock) * 0.8 : 0
        speech = Self.follow(speech, said, dt)

        // Targets for this mood.
        let targetGlow, targetBrightness, targetInward: Double
        switch mood {
        case .idle:
            (targetGlow, targetBrightness, targetInward) = (0.5, 1, 0)
        case .listening:
            (targetGlow, targetBrightness, targetInward) = (0.7 + level * 0.5, 1 + level * 0.55, 0)
        case .thinking:
            (targetGlow, targetBrightness, targetInward) = (0.55, 0.92, 1)
        case .answering:
            (targetGlow, targetBrightness, targetInward) = (0.4 + speech * 0.4, 1 + speech * 0.4, 0)
        }
        let voice = mood == .listening ? level : mood == .answering ? speech * 0.6 : 0
        glow = Self.ease(glow, targetGlow, dt, rate: mood == .listening ? 18 : 4)
        brightness = Self.ease(brightness, targetBrightness, dt, rate: 18)
        inward = Self.ease(inward, targetInward, dt, rate: 3)
        voiceScale = Self.ease(voiceScale, 1 + 0.08 * voice, dt, rate: 22)

        // The same calm pace in every mood; only the breath slows down or speeds up.
        let drift = reduceMotion ? 0.0 : 1.0
        spin += dt * drift
        morph += dt * drift
        breath += dt * (mood == .thinking ? 2 * .pi / 2.1 : 2 * .pi / 5)
        corePhase += dt * 1.9

        // Sparks spiral in while thinking.
        if !reduceMotion, mood == .thinking, Double.random(in: 0...1) < dt * Self.sparkRate {
            sparks.append(Spark(angle: .random(in: 0...(2 * .pi)), distance: .random(in: 1.9...2.5), life: 0))
        }
        for index in sparks.indices.reversed() {
            sparks[index].life += dt
            sparks[index].distance -= dt * (0.55 + sparks[index].life * 0.9)
            sparks[index].angle += dt * (1.6 / max(sparks[index].distance, 0.3))
            if sparks[index].distance < 0.18 { sparks.remove(at: index) }
        }
        if reduceMotion { sparks.removeAll() }
    }

    func draw(in context: inout GraphicsContext, size: CGSize, orbRadius: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let breathing = (mood == .listening ? 0.012 : 0.035) * sin(breath)
        let r = orbRadius * voiceScale * (1 + breathing)

        // A faint ambient wash around the orb.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Self.rgb(1, 0.44, 0.16, 0.22 * glow), location: 0),
                    .init(color: Self.rgb(1, 0.31, 0.12, 0.08 * glow), location: 0.4),
                    .init(color: Self.rgb(1, 0.31, 0.12, 0), location: 1),
                ]),
                center: center, startRadius: 0, endRadius: r * 2.6
            )
        )

        // Sparks behind the flame (soft gradients, no blur).
        if !sparks.isEmpty {
            var sparkContext = context
            sparkContext.blendMode = .plusLighter
            for spark in sparks {
                let point = CGPoint(x: center.x + cos(spark.angle) * r * spark.distance,
                                    y: center.y + sin(spark.angle) * r * spark.distance)
                let fade = min(1, spark.life * 3) * min(1, (spark.distance - 0.18) * 2.5) * inward
                let size = max(5, r * 0.06)
                sparkContext.fill(
                    Path(ellipseIn: CGRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Self.rgb(1, 0.925, 0.82, 0.95 * fade), location: 0),
                            .init(color: Self.rgb(1, 0.59, 0.27, 0.5 * fade), location: 0.4),
                            .init(color: Self.rgb(1, 0.47, 0.2, 0), location: 1),
                        ]),
                        center: point, startRadius: 0, endRadius: size
                    )
                )
            }
        }

        // The flame, laid down once per pass at its own blur, all added together.
        for pass in Self.passes {
            var passContext = context
            passContext.blendMode = .plusLighter
            passContext.opacity = pass.opacity * (pass.scale > 1 ? min(1.4, brightness) : 1)
            let radius = r * pass.scale
            if pass.blur > 0 {
                passContext.addFilter(.blur(radius: max(1, r * pass.blur)))
                passContext.drawLayer { layer in
                    layer.blendMode = .plusLighter
                    self.drawFlame(in: &layer, center: center, radius: radius)
                }
            } else {
                self.drawFlame(in: &passContext, center: center, radius: radius)
            }
        }
    }

    private func drawFlame(in context: inout GraphicsContext, center: CGPoint, radius r: CGFloat) {
        let b = brightness
        func a(_ value: Double) -> Double { min(1, value * b) }

        blob(&context, center, r * 1.05, angle: spin * 2 * .pi / 9, wobble: morph * 2 * .pi / 7, focus: (0.34, 0.34), stops: [
            (Self.rgb(1, 0.835, 0.573, a(0.85)), 0),
            (Self.rgb(1, 0.478, 0.184, a(0.7)), 0.35),
            (Self.rgb(1, 0.275, 0.098, a(0.18)), 0.7),
            (Self.rgb(1, 0.235, 0.078, 0), 1),
        ])
        blob(&context, center, r * 1.0, angle: -spin * 2 * .pi / 13 + 1.7, wobble: morph * 2 * .pi / 9 + 1.7, focus: (0.62, 0.64), stops: [
            (Self.rgb(1, 0.29, 0.18, a(0.7)), 0),
            (Self.rgb(0.84, 0.157, 0.275, a(0.32)), 0.4),
            (Self.rgb(0.745, 0.118, 0.235, a(0.08)), 0.75),
            (Self.rgb(0.78, 0.118, 0.235, 0), 1),
        ])
        blob(&context, center, r * 0.8, angle: spin * 2 * .pi / 6 + 3.1, wobble: morph * 2 * .pi / 5 + 3.1, focus: (0.48, 0.3), stops: [
            (Self.rgb(1, 0.953, 0.863, a(0.75)), 0),
            (Self.rgb(1, 0.745, 0.392, a(0.38)), 0.3),
            (Self.rgb(1, 0.706, 0.353, 0), 1),
        ])

        // The core: brighter with the voice; while thinking it swells as the sparks arrive.
        let coreBoost = mood == .thinking ? 0.25 + 0.25 * sin(breath) : 0
        let coreAlpha = min(1, (0.7 + 0.15 * sin(corePhase)) * b + coreBoost)
        let coreRadius = r * 0.55 * (1 + coreBoost * 0.3)
        context.fill(
            Path(CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Self.rgb(1, 0.98, 0.94, coreAlpha), location: 0),
                    .init(color: Self.rgb(1, 0.84, 0.63, coreAlpha * 0.45), location: 0.35),
                    .init(color: Self.rgb(1, 0.78, 0.55, 0), location: 1),
                ]),
                center: center, startRadius: 0, endRadius: coreRadius
            )
        )
    }

    /// One blob of light: turned, gently squashed, its gradient off-center inside it.
    private func blob(_ context: inout GraphicsContext, _ center: CGPoint, _ r: CGFloat, angle: Double, wobble: Double,
                      focus: (Double, Double), stops: [(Color, Double)]) {
        var blob = context
        blob.translateBy(x: center.x, y: center.y)
        blob.rotate(by: .radians(angle))
        blob.scaleBy(x: 1 + 0.07 * sin(wobble), y: 1 + 0.07 * cos(wobble * 1.3))
        let focusPoint = CGPoint(x: (focus.0 - 0.5) * r, y: (focus.1 - 0.5) * r)
        blob.fill(
            Path(CGRect(x: -r * 1.6, y: -r * 1.6, width: r * 3.2, height: r * 3.2)),
            with: .radialGradient(
                Gradient(stops: stops.map { Gradient.Stop(color: $0.0, location: $0.1) }),
                center: focusPoint, startRadius: 0, endRadius: r
            )
        )
    }

    // MARK: Helpers

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: max(0, min(1, alpha)))
    }

    private static func ease(_ current: Double, _ goal: Double, _ dt: Double, rate: Double) -> Double {
        current + (goal - current) * (1 - exp(-dt * rate))
    }

    /// Fast attack, slow release.
    private static func follow(_ current: Double, _ input: Double, _ dt: Double) -> Double {
        ease(current, input, dt, rate: input > current ? 28 : 5)
    }

    /// A speech-like envelope: syllables inside words, pauses between phrases.
    private static func speechEnvelope(_ t: Double) -> Double {
        let phrase = (sin(t * 0.9) + sin(t * 0.37 + 1)) > -0.2 ? 1.0 : 0.0
        let syllable = max(0, sin(t * 2 * .pi * 4.6) * 0.6 + sin(t * 2 * .pi * 2.1 + 2) * 0.4)
        let jitter = 0.75 + 0.25 * sin(t * 13.7) * sin(t * 7.1)
        return phrase * syllable * jitter
    }
}

#if os(watchOS)
/// The orb drawn cheaply, for Apple Watch: three soft blobs turning at different speeds and a
/// breathing core, with no blur. Every frame is worked out from the clock (nothing is kept between
/// frames and no animation is left running), so it can't stall or freeze after the screen dims
/// and wakes; it simply picks up where the clock is. Thirty frames a second, paused while the
/// screen is dimmed (Always On).
struct EmberOrbLite: View {
    var mood: EmberOrbMood
    var speaking: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var glow: Double {
        switch mood {
        case .idle: 0.5
        case .listening: 0.8
        case .thinking: 0.65
        case .answering: speaking ? 0.7 : 0.45
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isLuminanceReduced || reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                let period = mood == .thinking ? 1.0 : 2.6
                let breath = sin(t * 2 * .pi / period)
                ZStack {
                    // Halo.
                    Circle()
                        .fill(RadialGradient(colors: [Self.rgb(1, 0.44, 0.16, 0.45 * glow), Self.rgb(1, 0.31, 0.12, 0.12 * glow), .clear],
                                             center: .center, startRadius: 0, endRadius: side * 1.05))
                        .frame(width: side * 2.1, height: side * 2.1)
                    blob(side * 1.05, focus: UnitPoint(x: 0.34, y: 0.34),
                         colors: [Self.rgb(1, 0.835, 0.573, 0.85), Self.rgb(1, 0.478, 0.184, 0.7), Self.rgb(1, 0.275, 0.098, 0.15), .clear])
                        .rotationEffect(.radians(t * 2 * .pi / 9))
                    blob(side, focus: UnitPoint(x: 0.64, y: 0.64),
                         colors: [Self.rgb(1, 0.29, 0.18, 0.7), Self.rgb(0.84, 0.157, 0.275, 0.3), .clear])
                        .rotationEffect(.radians(-t * 2 * .pi / 13 + 1.7))
                    // Core: breathes, faster while thinking.
                    Circle()
                        .fill(RadialGradient(colors: [Self.rgb(1, 0.98, 0.94, 0.95), Self.rgb(1, 0.84, 0.63, 0.45), .clear],
                                             center: .center, startRadius: 0, endRadius: side * 0.32))
                        .frame(width: side * 0.64, height: side * 0.64)
                        .scaleEffect(1 + 0.08 * breath)
                }
                .frame(width: side, height: side)
                .blendMode(.plusLighter)
            }
        }
    }

    private func blob(_ size: CGFloat, focus: UnitPoint, colors: [Color]) -> some View {
        Circle()
            .fill(RadialGradient(colors: colors, center: focus, startRadius: 0, endRadius: size * 0.55))
            .frame(width: size, height: size)
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
#endif

#Preview {
    VStack(spacing: 80) {
        EmberOrb(mood: .idle).frame(width: 124, height: 124)
        EmberOrb(mood: .listening, level: 0.4).frame(width: 200, height: 200)
        EmberOrb(mood: .thinking).frame(width: 150, height: 150)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(red: 0.055, green: 0.043, blue: 0.039))
}
