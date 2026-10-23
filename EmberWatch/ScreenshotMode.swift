import Foundation

/// Screenshot mode on Apple Watch, for marketing screenshots (scripts/screenshots.sh).
///
/// Launched with `-Screenshots`, the watch app shows the demo household's day (as the iPhone's
/// screenshot mode does) from values made in memory. It doesn't talk to the iPhone, hearth-api or
/// iCloud, and never turns the microphone on. Adding `-Screen <name>` opens one page (see
/// `Screen`). Debug builds only: Release ignores the arguments.
nonisolated enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The pages the script captures, by the name passed after `-Screen`, in order.
    nonisolated enum Screen: String, CaseIterable {
        case face, listening, answer
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }()

    /// What the iPhone would have sent: the day's glances, and no Cloud Help prompt.
    static let context = EmberWatchContext(
        glances: [
            EmberGlance(app: "bigtable", title: "Sheet-Pan Chicken Fajitas", detail: "Tonight"),
            EmberGlance(app: "suffice", title: "$1,240 left", detail: "Budgets"),
        ],
        people: [],
        cloudHelp: nil,
        facts: [],
        updatedAt: .now
    )

    static let reply = EmberWatchReply(
        id: UUID(),
        text: "Sheet-pan chicken fajitas, from BigTable’s plan. It takes about 35 minutes.",
        actions: [EmberWatchAction(title: "What’s on the list?", url: nil, followUp: "What’s on the grocery list?")],
        tier: .onDevice
    )
}
