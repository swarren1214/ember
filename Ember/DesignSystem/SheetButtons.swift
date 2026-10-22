import SwiftUI

// The two buttons at the top of a sheet that has both Done and Cancel (see AGENT.md):
//   Done:   a checkmark in a filled circle of the app's color, the icon white.
//   Cancel: an X in a clear glass circle, the icon in the text color.
// The title stays for VoiceOver and for the bar's overflow menu.

struct SheetDoneButton: View {
    var title: String
    var action: () -> Void

    init(_ title: String = "Done", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: "checkmark", role: .confirm, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.glassProminent)
            .tint(EmberTheme.accent)
    }
}

struct SheetCancelButton: View {
    var title: String
    var action: () -> Void

    init(_ title: String = "Cancel", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: "xmark", role: .cancel, action: action)
            .labelStyle(.iconOnly)
            .tint(.primary)
    }
}
