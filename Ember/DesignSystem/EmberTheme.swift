import SwiftUI
import UIKit

/// Ember's look: a warm glow on near-black coal (the "Ember · Hearth AI" canvas). Ember is a
/// dark app; the Hearth color header appears only on its settings screens.
enum EmberTheme {
    /// The app's color: ember orange. For the orb, filled buttons, toggles and big numbers only
    /// (see AGENT.md › App color).
    static let accent = Color(red: 1.0, green: 0.478, blue: 0.184)          // #FF7A2F
    /// Accent text on dark surfaces, where the full orange is too strong for words.
    static let accentSoft = Color(red: 1.0, green: 0.698, blue: 0.478)      // #FFB27A
    static let coal = Color(red: 0.055, green: 0.043, blue: 0.039)          // #0E0B0A
    static let ash = Color(red: 0.659, green: 0.620, blue: 0.588)           // #A89E96
    static let smoke = Color(red: 0.522, green: 0.478, blue: 0.447)         // #857A72
    static let text = Color(red: 0.961, green: 0.937, blue: 0.918)          // #F5EFEA
    static let success = Color(red: 0.498, green: 0.867, blue: 0.682)       // #7FDDAE

    /// Each Hearth app's own color, for source tiles.
    static func color(_ app: HearthApp) -> Color {
        Color(hex: app.info.colorHex)
    }
}

enum DeviceName {
    static var current: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension View {
    /// The prototype's glass: a translucent card with a hairline, on the dark coal background.
    func emberGlass(cornerRadius: CGFloat = 22) -> some View {
        glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: cornerRadius))
    }

    /// Keeps content to a comfortable reading width on iPad, centered; no change on iPhone.
    func readableWidth(_ maxWidth: CGFloat = 640) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}
