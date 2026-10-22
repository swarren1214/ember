import SwiftUI
import UIKit

// Menu icons in the same color as their text. A menu tints its icons with the app's accent (set
// at the root), even on destructive items, while the titles stay in the text color (or red).
// These draw the symbol in the text color (red for destructive items) as an "original" image,
// which the menu doesn't re-tint. They adapt to Dark Mode. See AGENT.md.

extension Image {
    /// An SF Symbol for a menu row, in its text's color: the label color, or red when the item
    /// is destructive.
    static func menuIcon(_ name: String, role: ButtonRole? = nil) -> Image {
        let color: UIColor = role == .destructive ? .systemRed : .label
        let symbol = UIImage(systemName: name)?.withTintColor(color, renderingMode: .alwaysOriginal)
        return symbol.map { Image(uiImage: $0) } ?? Image(systemName: name)
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    /// A menu button whose icon is its text's color: `Button("Rename", menuIcon: "pencil") { … }`.
    init(_ title: String, menuIcon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) {
            SwiftUI.Label { Text(title) } icon: { Image.menuIcon(menuIcon, role: role) }
        }
    }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    /// A submenu whose icon is the text color.
    init(_ title: String, menuIcon: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) {
            SwiftUI.Label { Text(title) } icon: { Image.menuIcon(menuIcon) }
        }
    }
}

extension Toggle where Label == SwiftUI.Label<Text, Image> {
    /// A menu toggle whose icon is the text color.
    init(_ title: String, menuIcon: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) {
            SwiftUI.Label { Text(title) } icon: { Image.menuIcon(menuIcon) }
        }
    }
}
