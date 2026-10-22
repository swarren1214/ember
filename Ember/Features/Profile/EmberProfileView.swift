import SwiftUI

// Profile, the HearthKit screen every Hearth app shows, with Ember's own sections: What Ember
// Knows (the "iPhone · What Ember knows" artboard): Cloud Help, the apps Ember reads, kids, and
// Ember's voice.

struct EmberProfileView: View {
    @State private var profile: HearthAccountProfile?

    var body: some View {
        HearthProfileView(
            app: .ember,
            profile: profile,
            erase: HearthProfileErase(
                app: .ember,
                message: "This clears Ember’s conversations and settings on this \(DeviceName.current). Your Hearth apps’ data isn’t touched, and Ember’s voice stays downloaded for your other apps."
            ) {
                EmberBrain.shared.reset()
                for key in ["ember.cloudHelp", "ember.readable", "ember.naturalVoice", "ember.kidsCanTalk"] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        ) {
            EmberAccountSection(profile: profile)
        } settings: {
            EmberKnowsSections()
        } data: {
            EmptyView()
        } about: {
            Text("Ember’s voice is Kokoro (Apache 2.0), running on your \(DeviceName.current).")
        }
        .task { profile = await Self.loadProfile() }
    }

    /// The Hearth account another Hearth app signed in with, if any.
    static func loadProfile() async -> HearthAccountProfile? {
        let status = await EmberAPI.shared.signInStatus()
        guard status.isSignedIn else { return nil }
        let apple = HearthAccounts.appleID()
        return HearthAccountProfile(name: apple?.fullName, email: status.email ?? apple?.email)
    }
}

/// Ember uses the Hearth account the other apps signed in with; it doesn't create one itself.
private struct EmberAccountSection: View {
    let profile: HearthAccountProfile?

    var body: some View {
        Section {
            if let profile {
                LabeledContent("Hearth Account", value: profile.name ?? profile.email ?? "Signed in")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not signed in")
                        .font(.headline)
                    Text("Ember works without an account. To use Cloud Help with Ember Plus or Hearth+, sign in with Apple in any Hearth app; Ember follows it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Account")
        }
    }
}

/// What Ember Knows.
struct EmberKnowsSections: View {
    @State private var settings = EmberSettings.shared
    @State private var kokoro = KokoroModel.shared
    @State private var context = EmberContext.shared
    @State private var confirmsRemoveVoice = false

    var body: some View {
        Section {
            ForEach(EmberSettings.CloudHelp.allCases) { choice in
                Button {
                    settings.cloudHelp = choice
                } label: {
                    EmberChoiceRow(title: choice.title, detail: choice.detail, isSelected: settings.cloudHelp == choice)
                }
                // Standard text colors; only the checkmark is orange.
                .tint(.primary)
                .accessibilityAddTraits(settings.cloudHelp == choice ? .isSelected : [])
            }
        } header: {
            Text("Cloud Help")
        } footer: {
            Text("Ember thinks on your \(DeviceName.current) first. Anything that goes to the cloud has names replaced and nothing that identifies you, and every cloud answer shows exactly what was sent.")
        }

        Section {
            ForEach([HearthApp.bigtable, .suffice, .caloma, .hearken], id: \.self) { app in
                Toggle(isOn: Binding(
                    get: { settings.canRead(app) },
                    set: { settings.setReadable(app, $0); context.refresh() }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.displayName)
                            Text(Self.what(app)).font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        EmberAppTile(app: app, size: 30)
                    }
                }
            }
            LabeledContent {
                Text("Ask first, every time").foregroundStyle(.secondary)
            } label: {
                Label {
                    Text("Trove")
                } icon: {
                    EmberAppTile(app: .trove, size: 30)
                }
            }
        } header: {
            Text("Your Hearth Apps")
        } footer: {
            Text("Ember reads what these apps share on this \(DeviceName.current). It never changes their data: it opens the app for you.")
        }

        Section {
            Toggle("Kids Can Talk to Ember", isOn: $settings.kidsCanTalk)
        } footer: {
            Text("Kids’ questions stay on the \(DeviceName.current), and Ember won’t talk about money with them.")
        }

        Section {
            Toggle("Natural Voice", isOn: $settings.naturalVoice)
            switch kokoro.state {
            case .ready:
                Button("Remove Voice (\(KokoroModel.approximateSize))", role: .destructive) { confirmsRemoveVoice = true }
            case .notDownloaded, .failed:
                Button {
                    kokoro.download()
                } label: {
                    HearthProfileRow("Download Voice", systemImage: "arrow.down.circle", value: KokoroModel.approximateSize)
                }
                if case .failed(let message) = kokoro.state {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading Ember’s voice") }
            case .unavailable:
                Text("The natural voice needs a real \(DeviceName.current); the Simulator uses Apple’s voice.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Ember speaks with Kokoro, a natural voice that runs on your \(DeviceName.current). It’s shared with Sated and Hearken, so it downloads once. Until then Ember uses Apple’s voice.")
        }
        .alert("Remove Ember’s Voice?", isPresented: $confirmsRemoveVoice) {
            Button("Remove", role: .destructive) { kokoro.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also removes it from Sated and Hearken on this \(DeviceName.current). They’ll use Apple’s voice until it’s downloaded again.")
        }
    }

    static func what(_ app: HearthApp) -> String {
        switch app {
        case .bigtable: "Meal plan and grocery list"
        case .suffice: "Grocery budget"
        case .caloma: "Allowance"
        case .hearken: "Today’s reading"
        default: ""
        }
    }
}

/// First run: how Ember may think (privacy rule 6). Nothing is pre-picked.
struct EmberCloudChoiceView: View {
    @State private var settings = EmberSettings.shared
    @State private var choice: EmberSettings.CloudHelp?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        EmberOrb(mood: .idle)
                            .frame(width: 72, height: 72)
                        Text("How should Ember think?")
                            .font(.title.bold())
                        Text("Ember answers on your \(DeviceName.current) whenever it can. For harder questions, and for Apple Watch without your \(DeviceName.current) nearby, it can ask for help in the cloud.")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(EmberSettings.CloudHelp.allCases) { option in
                        Button {
                            withAnimation(.snappy) { choice = option }
                        } label: {
                            EmberChoiceRow(title: option.title, detail: option.detail, isSelected: choice == option, large: true)
                        }
                        // Standard text colors; only the checkmark is orange.
                        .tint(.primary)
                        .accessibilityAddTraits(choice == option ? .isSelected : [])
                    }
                } footer: {
                    Text("Change this any time in Profile › Cloud Help.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Continue") {
                        settings.cloudHelp = choice
                        dismiss()
                    }
                    .disabled(choice == nil)
                }
            }
        }
    }
}

/// A choice in a list: the checkmark in Ember's orange on the left of the selected option, the
/// title and detail in the standard text colors. Unselected rows keep the checkmark's space, so
/// the text never shifts.
struct EmberChoiceRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    var large = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(EmberTheme.accent)
                .opacity(isSelected ? 1 : 0)
                .scaleEffect(isSelected ? 1 : 0.6)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: large ? 3 : 2) {
                Text(title)
                    .font(large ? .headline : .body)
                    .foregroundStyle(Color.primary)
                Text(detail)
                    .font(large ? .subheadline : .footnote)
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, large ? 4 : 0)
        .contentShape(.rect)
    }
}
