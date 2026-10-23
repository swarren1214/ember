import SwiftUI

// Profile, the HearthKit screen every Hearth app shows, with Ember's own sections: What Ember
// Knows (the "iPhone · What Ember knows" artboard): Cloud Help, the apps Ember reads, what it
// remembers, Ember's voice, and Report a Problem.

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
                for key in ["ember.cloudHelp", "ember.readable", "ember.naturalVoice", "ember.voiceID", "ember.voiceSpeed",
                            "ember.pronunciations", "ember.remembered"] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        ) {
            EmberAccountSection(profile: profile)
        } settings: {
            EmberKnowsSections()
        } data: {
            NavigationLink {
                EmberDataStatusView()
            } label: {
                HearthProfileRow("iCloud Data", systemImage: "icloud")
            }
            EmberReportButton()
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
            ForEach([HearthApp.bigtable, .suffice, .caloma, .sated, .hearken], id: \.self) { app in
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
            Text("Ember reads these apps’ data from your family’s iCloud and this \(DeviceName.current). It can make changes you ask for, the way the app would, and asks first for anything involving money or the family’s plans.")
        }

        Section {
            if settings.remembered.isEmpty {
                Text("Nothing yet. Say “Remember that…” and Ember keeps it here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.remembered, id: \.self) { fact in
                    Text(fact)
                }
                .onDelete { settings.remembered.remove(atOffsets: $0) }
            }
        } header: {
            Text("Ember Remembers")
        } footer: {
            Text("Kept on this \(DeviceName.current) and only used here. Swipe to delete.")
        }

        Section {
            Toggle("Natural Voice", isOn: $settings.naturalVoice)
            if settings.naturalVoice, kokoro.state == .ready {
                Picker("Voice", selection: $settings.voiceID) {
                    ForEach(KokoroVoices.choices) { voice in
                        Text("\(voice.name) · \(voice.detail)").tag(voice.id)
                    }
                }
                .tint(.primary)
                Button {
                    EmberConversation.shared.speakResult("Hi, I’m Ember. Dinner’s at six thirty, and you have eighty-six dollars left for groceries.")
                } label: {
                    HearthProfileRow("Hear a Sample", systemImage: "play.circle")
                }
                .tint(.primary)
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Speed", value: settings.voiceSpeed.formatted(.number.precision(.fractionLength(2))) + "×")
                Slider(value: $settings.voiceSpeed, in: 0.9...1.2, step: 0.05)
                    .tint(EmberTheme.accent)
            }
            NavigationLink {
                EmberPronunciationsView()
            } label: {
                HearthProfileRow("Pronunciations", systemImage: "character.bubble", value: "\(settings.pronunciations.count)")
            }
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
        case .suffice: "Spending, budgets and bills"
        case .caloma: "Chores, family calendar and allowance"
        case .sated: "Food log and goals"
        case .hearken: "Today’s reading"
        default: ""
        }
    }
}

/// How Ember says names it gets wrong.
struct EmberPronunciationsView: View {
    @State private var settings = EmberSettings.shared
    @State private var word = ""
    @State private var spoken = ""

    var body: some View {
        List {
            Section {
                TextField("Word, like Caloma", text: $word)
                TextField("Say it as, like kuh LOH muh", text: $spoken)
                Button("Add") {
                    let key = word.trimmingCharacters(in: .whitespaces)
                    let value = spoken.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty, !value.isEmpty else { return }
                    settings.pronunciations[key] = value
                    word = ""
                    spoken = ""
                }
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty || spoken.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("Spell it the way it sounds, with spaces between the parts and the stressed part in capitals.")
            }
            Section {
                ForEach(settings.pronunciations.keys.sorted(), id: \.self) { key in
                    Button {
                        EmberConversation.shared.speakResult(key)
                    } label: {
                        LabeledContent(key, value: settings.pronunciations[key] ?? "")
                    }
                    .tint(.primary)
                }
                .onDelete { offsets in
                    let keys = settings.pronunciations.keys.sorted()
                    for index in offsets { settings.pronunciations[keys[index]] = nil }
                }
            } footer: {
                Text("Tap one to hear it.")
            }
        }
        .navigationTitle("Pronunciations")
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
                        EmberOrb(mode: .idle, size: 64)
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

/// Report a Problem: the last 20 turns, de-identified, in an email the person reads first.
struct EmberReportButton: View {
    @State private var request: EmberComposeRequest?
    @State private var trace = EmberTrace.shared

    var body: some View {
        Button {
            let report = EmberComposeRequest(kind: .mail, recipients: ["support@hearthapps.com"], subject: "Ember problem report",
                                             body: "What went wrong:\n\n\n" + trace.report())
            if EmberCompose.shared.canMail {
                request = report
            } else {
                EmberCompose.shared.queue(report)
                EmberCompose.shared.presentQueued()
            }
        } label: {
            HearthProfileRow("Report a Problem", systemImage: "exclamationmark.bubble")
        }
        .tint(.primary)
        .disabled(trace.entries.isEmpty)
        .sheet(item: $request) { request in
            EmberComposeSheet(request: request) { self.request = nil }
                .ignoresSafeArea()
        }
    }
}

/// What Ember can see of each app in iCloud: where it reads from, how much, how fresh, and the
/// newest Suffice entry, so "Ember says nothing was spent" can be told apart from "Suffice
/// hasn't synced". Fetch Again throws the copy away and reads everything fresh.
struct EmberDataStatusView: View {
    private struct Row: Identifiable {
        var id: String { name }
        var name: String
        var location: String
        var records: Int
        var fetched: Date?
        var error: String?
    }

    @State private var rows: [Row] = []
    @State private var entries = 0
    @State private var newest: Date?
    @State private var newestPayees: [String] = []
    @State private var isFetching = false
    @State private var local: (entries: Int, newest: Date?, updated: Date)?

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.name).font(.headline)
                            Spacer()
                            Text("\(row.records) records").foregroundStyle(.secondary)
                        }
                        Text(row.location + (row.fetched.map { " · checked \($0.formatted(.relative(presentation: .named)))" } ?? " · not checked yet"))
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = row.error {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
            } header: {
                Text("Zones")
            }
            Section {
                if let local {
                    LabeledContent("Entries", value: "\(local.entries)")
                    LabeledContent("Newest", value: local.newest?.formatted(date: .abbreviated, time: .omitted) ?? "None")
                    LabeledContent("Shared", value: local.updated.formatted(.relative(presentation: .named)))
                } else {
                    Text("Suffice hasn’t shared its numbers on this iPhone yet. Opening Suffice once with this version does it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Suffice on this iPhone")
            } footer: {
                Text("Ember answers money questions from Suffice’s own numbers first, and from iCloud when that’s newer.")
            }
            Section {
                LabeledContent("Entries", value: "\(entries)")
                LabeledContent("Newest", value: newest?.formatted(date: .abbreviated, time: .omitted) ?? "None")
                ForEach(newestPayees, id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Suffice in iCloud")
            } footer: {
                Text("If Suffice shows newer transactions than these, they haven’t reached iCloud yet: open Suffice on a device with them and check Profile for a sync problem.")
            }
            Section {
                Button {
                    Task {
                        isFetching = true
                        let data = EmberData.shared
                        await data.budget.refetchEverything()
                        await data.family.refetchEverything()
                        await data.kitchen.refetchEverything()
                        await load()
                        isFetching = false
                    }
                } label: {
                    HStack {
                        Text("Fetch Everything Again")
                        if isFetching { Spacer(); ProgressView() }
                    }
                }
                .disabled(isFetching)
            }
        }
        .navigationTitle("iCloud Data")
        .task {
            await EmberData.shared.refreshAll(force: true)
            await load()
        }
        .refreshable {
            await EmberData.shared.refreshAll(force: true)
            await load()
        }
    }

    private func load() async {
        let data = EmberData.shared
        rows = [("Suffice", data.budget), ("Caloma", data.family), ("BigTable", data.kitchen)].map { name, zone in
            Row(name: name, location: zone.whereLabel, records: zone.records.count, fetched: zone.lastFetched,
                error: zone.lastError?.localizedDescription)
        }
        let ledger = await data.budget.snapshot(SufficeLedger.init(records:))
        let dated = ledger.entries.filter { $0.date > .distantPast }.sorted { $0.date > $1.date }
        entries = dated.count
        newest = dated.first?.date
        if let shared = SufficeMoney.onThisPhone() {
            local = (shared.book.entries.count, shared.book.newestEntry, shared.updatedAt)
        } else {
            local = nil
        }
        newestPayees = dated.prefix(5).map { "\($0.date.formatted(.dateTime.month(.abbreviated).day())): \($0.payee) \(EmberMoney.exact($0.amountCents))" }
    }
}
