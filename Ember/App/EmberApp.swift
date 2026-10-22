import AppIntents
import SwiftUI
import UIKit

@main
struct EmberApp: App {
    @UIApplicationDelegateAdaptor(EmberAppDelegate.self) private var appDelegate

    init() {
        // Alerts use the system label color rather than the accent. Destructive buttons stay red.
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = .label
        // One sign-in for every Hearth app: follow sign-ins and sign-outs in the others.
        EmberSignIn.start()
    }

    var body: some Scene {
        WindowGroup {
            EmberRoot()
                .hearthSplash(.ember, isEnabled: !ScreenshotMode.isOn)
                .task { if !ScreenshotMode.isOn { HearthHouseholdStore.shared.start(app: .ember) } }
                .hearthHouseholdInvitations(accent: EmberTheme.accent)
        }
    }
}

final class EmberAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The household syncs through CloudKit's silent pushes.
        application.registerForRemoteNotifications()
        // The Watch can wake Ember in the background with a question; no screen appears then,
        // so everything a turn needs starts here rather than in the root view.
        if !ScreenshotMode.isOn {
            HearthHouseholdStore.shared.start(app: .ember)
            EmberContext.shared.start()
            EmberWatchRelay.shared.start()
        }
        return true
    }

    /// Household invitations (iCloud) arrive through the scene delegate.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = HearthHouseholdSceneDelegate.self
        return configuration
    }
}

/// The one screen, Profile behind the photo, and the first-run Cloud Help choice.
struct EmberRoot: View {
    @State private var settings = EmberSettings.shared
    @State private var showsCloudChoice = false
    @State private var context = EmberContext.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            // Ember is for parents and adults.
            if context.me?.role == .kid {
                EmberAdultsOnlyView()
            } else {
                EmberHomeView()
            }
        }
            .hearthProfile { EmberProfileView() }
            .tint(EmberTheme.accent)
            .task {
                EmberContext.shared.start()
                EmberWatchRelay.shared.start()
                EmberBrain.shared.prewarm()
                await EmberAPI.shared.prepareSession()
                // Privacy rule 6: the person chooses; nothing is pre-picked.
                if settings.cloudHelp == nil, !ScreenshotMode.isOn { showsCloudChoice = true }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    EmberContext.shared.refresh()
                    EmberData.shared.prefetch()
                    EmberPlace.refresh()
                }
            }
            .onOpenURL { url in EmberLinks.open(url) }
            .sheet(isPresented: $showsCloudChoice) {
                EmberCloudChoiceView()
                    .interactiveDismissDisabled()
            }
    }
}

/// What a kid sees: Ember is for the grown-ups in the household.
struct EmberAdultsOnlyView: View {
    var body: some View {
        ZStack {
            EmberTheme.coal.ignoresSafeArea()
            VStack(spacing: 18) {
                EmberOrb(mood: .idle)
                    .frame(width: 120, height: 120)
                Text("Ember is for parents and adults")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(EmberTheme.text)
                Text("Ask a parent if you need something from the family’s apps.")
                    .font(.body)
                    .foregroundStyle(EmberTheme.ash)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
        .preferredColorScheme(.dark)
    }
}

/// ember://listen starts listening (the Action button, Control Center, the Lock Screen);
/// ember://ask?q=… asks a question.
enum EmberLinks {
    static func open(_ url: URL) {
        guard url.scheme == "ember" else { return }
        switch url.host() {
        case "listen":
            if EmberConversation.shared.phase != .listening { EmberConversation.shared.tapOrb() }
        case "ask":
            let question = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            if let question, !question.isEmpty { EmberConversation.shared.ask(question) }
        default:
            break
        }
    }
}

// MARK: - Siri, the Action button and Shortcuts

/// "Talk to Ember": opens Ember listening. Assign it to the Action button in Settings.
struct TalkToEmberIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Ember"
    static let description = IntentDescription("Opens Ember, ready to listen.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        EmberLinks.open(URL(string: "ember://listen")!)
        return .result()
    }
}

/// "Ask Ember …": opens Ember with a question.
struct AskEmberIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Ember"
    static let description = IntentDescription("Asks Ember a question about your household.")
    static let openAppWhenRun = true

    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        EmberConversation.shared.ask(question)
        return .result()
    }
}

struct EmberShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToEmberIntent(),
            phrases: ["Talk to \(.applicationName)", "Open \(.applicationName)"],
            shortTitle: "Talk to Ember",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: AskEmberIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask Ember",
            systemImageName: "bubble.left"
        )
    }
}
