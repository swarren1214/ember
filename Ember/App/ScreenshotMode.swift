import Foundation

/// Screenshot mode for marketing screenshots: launched with `-Screenshots` (Debug only), Ember
/// shows a demo household and never signs in or calls the API. Release ignores the argument.
nonisolated enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()
}
