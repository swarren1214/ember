import SwiftUI

// The orb: Ember's one moving part, the same on iPhone and Apple Watch (compiled into both; the
// "Ember · Hearth AI" canvas). Three soft blobs of ember light turn and change shape at their own
// speeds around a bright core, blended with `.screen` so they glow where they overlap.
//
//   idle       slow breathing
//   listening  bigger, softer, pulses with your voice, ripples out
//   thinking   spins faster, a spark circles it
//   answering  small and crisp, still glowing
//
// Drawn from a TimelineView clock, so every state change is a spring between two steady
// motions, never a restart. Reduce Motion keeps the glow and drops the motion.

enum EmberOrbMood: Equatable {
    case idle, listening, thinking, answering
}

struct EmberOrb: View {
    var mood: EmberOrbMood
    /// Microphone loudness, 0...1 (listening only).
    var level: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let size = min(proxy.size.width, proxy.size.height)
                ZStack {
                    if mood == .listening && !reduceMotion {
                        ripples(t: t, size: size)
                    }
                    if mood == .thinking && !reduceMotion {
                        spark(t: t, size: size)
                    }
                    orb(t: t, size: size)
                        .scaleEffect(scale(t: t))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Parts

    private func orb(t: Double, size: CGFloat) -> some View {
        let speed = mood == .thinking ? 3.2 : 1.0
        let blur = size * (mood == .listening ? 0.07 : mood == .answering ? 0.03 : 0.05)
        return ZStack {
            blob(t: t * speed, period: 9, morph: 7, size: size, inset: 0.06,
                 colors: [Color(red: 1, green: 0.835, blue: 0.573), Color(red: 1, green: 0.478, blue: 0.184), Color(red: 1, green: 0.235, blue: 0.078).opacity(0)],
                 center: UnitPoint(x: 0.34, y: 0.34), offset: 0)
            blob(t: -t * speed, period: 13, morph: 9, size: size, inset: 0.08,
                 colors: [Color(red: 1, green: 0.29, blue: 0.18), Color(red: 0.84, green: 0.157, blue: 0.275).opacity(0.55), Color(red: 0.78, green: 0.118, blue: 0.235).opacity(0)],
                 center: UnitPoint(x: 0.6, y: 0.62), offset: 1.7)
            blob(t: t * speed, period: 6, morph: 5, size: size, inset: 0.16,
                 colors: [Color(red: 1, green: 0.953, blue: 0.863), Color(red: 1, green: 0.745, blue: 0.392).opacity(0.6), Color(red: 1, green: 0.706, blue: 0.353).opacity(0)],
                 center: UnitPoint(x: 0.48, y: 0.3), offset: 3.1)
            // The core.
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.973, blue: 0.925).opacity(0.95), Color(red: 1, green: 0.808, blue: 0.588).opacity(0.35), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.2))
                .frame(width: size * 0.4, height: size * 0.4)
                .opacity(0.8 + 0.2 * sin(t * 1.9))
                .blur(radius: size * 0.025)
        }
        .compositingGroup()
        .blur(radius: blur)
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.8), value: mood)
    }

    private func blob(t: Double, period: Double, morph: Double, size: CGFloat, inset: CGFloat, colors: [Color], center: UnitPoint, offset: Double) -> some View {
        let angle = Angle.radians((t / period) * 2 * .pi + offset)
        let phase = (t / morph) * 2 * .pi + offset
        let width = 1 + 0.07 * sin(phase)
        let height = 1 + 0.07 * cos(phase * 1.3)
        let diameter = size * (1 - inset * 2)
        return Ellipse()
            .fill(RadialGradient(colors: colors, center: center, startRadius: 0, endRadius: diameter * 0.62))
            .frame(width: diameter * width, height: diameter * height)
            .rotationEffect(angle)
            .blendMode(.screen)
    }

    private func ripples(t: Double, size: CGFloat) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let progress = ((t / 2.6) + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(Color(red: 1, green: 0.588, blue: 0.314).opacity(0.55 * (1 - progress)), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(0.92 + progress * 0.83)
            }
        }
    }

    private func spark(t: Double, size: CGFloat) -> some View {
        let angle = (t / 1.5) * 2 * .pi
        let radius = size * 0.5 + 16
        return ZStack {
            Circle()
                .stroke(Color(red: 1, green: 0.667, blue: 0.431).opacity(0.16), lineWidth: 1)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(Color(red: 1, green: 0.882, blue: 0.745))
                .frame(width: 8, height: 8)
                .shadow(color: Color(red: 1, green: 0.55, blue: 0.24).opacity(0.8), radius: 7)
                .offset(x: cos(angle) * radius, y: sin(angle) * radius)
        }
    }

    private func scale(t: Double) -> CGFloat {
        guard !reduceMotion else { return 1 }
        switch mood {
        case .idle, .answering:
            return 1 + 0.045 * (0.5 + 0.5 * sin(t * 2 * .pi / 5))
        case .thinking:
            return 1 + 0.04 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.3))
        case .listening:
            // The voice drives it; a gentle pulse underneath so silence still feels alive.
            return 1 + 0.03 * sin(t * 2 * .pi / 1.1) + 0.12 * level
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        EmberOrb(mood: .idle).frame(width: 124, height: 124)
        EmberOrb(mood: .listening, level: 0.4).frame(width: 200, height: 200)
        EmberOrb(mood: .thinking).frame(width: 140, height: 140)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(red: 0.055, green: 0.043, blue: 0.039))
}
