import SwiftUI

@main
struct EmberWatchApp: App {
    @State private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .task { model.start() }
        }
    }
}
