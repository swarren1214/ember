import SwiftUI

// Ember on iPhone, laid out like Ask Suffice and Sated's Coach (the "Ember Redesign" canvas):
//
//   Home          the greeting, a "Right now" line from each Hearth app (tap one to ask about
//                 it), a few starters, and the composer: a text field with the talk button.
//   Conversation  once something's been asked: the questions and answers, with the cards each
//                 answer brought. Typed answers are spoken too.
//   Voice         the talk button opens the voice screen (EmberVoiceView).
//
// Ember is always dark: its colors glow on a dark background.

struct EmberHomeView: View {
    @State private var conversation = EmberConversation.shared
    @State private var brain = EmberBrain.shared
    @State private var context = EmberContext.shared
    @State private var settings = EmberSettings.shared
    @State private var compose = EmberCompose.shared
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var showsSent = false

    /// One line of the message field, and the buttons inside its height (as in Ask Suffice).
    private static let composerHeight: CGFloat = 46
    private static let buttonSize: CGFloat = 40

    private var isAnswering: Bool { conversation.isAnsweringTyped || (brain.isThinking && !conversation.isVoicePresented) }
    private var hasThread: Bool { !brain.turns.isEmpty || isAnswering }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if hasThread {
                            thread
                        } else {
                            welcome
                        }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .readableWidth()
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: brain.turns.count) { scrollDown(proxy) }
                .onChange(of: conversation.liveAnswer) { scrollDown(proxy) }
                .onChange(of: isAnswering) { scrollDown(proxy) }
            }
            .background(EmberTheme.coal.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .toolbar { toolbar }
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $conversation.isVoicePresented) {
            EmberVoiceView {
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    composerFocused = true
                }
            }
        }
        .sheet(isPresented: $showsSent) {
            EmberSentSheet(turn: brain.latest)
        }
        .sheet(item: $compose.presented) { request in
            EmberComposeSheet(request: request) { compose.presented = nil }
                .ignoresSafeArea()
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if hasThread {
            ToolbarItem(placement: .topBarLeading) {
                Button("New Conversation", systemImage: "square.and.pencil") {
                    withAnimation(.snappy) { conversation.newConversation() }
                }
                .tint(.primary)
            }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Circle()
                    .fill(EmberPalette.wheel)
                    .frame(width: 14, height: 14)
                Text("Ember").font(.headline)
            }
            .accessibilityElement(children: .combine)
        }
        // The profile photo, last, as in every Hearth app.
        ToolbarItem(placement: .topBarTrailing) {
            HearthProfileButton(overHeader: false)
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(EmberTheme.ash)
                .padding(.top, 20)
                .padding(.horizontal, 4)
            Text(greeting)
                .font(.largeTitle.bold())
                .foregroundStyle(EmberTheme.text)
                .padding(.top, 4)
                .padding(.horizontal, 4)
            Text("Ask anything across your Hearth apps, out loud or typed.")
                .font(.body)
                .foregroundStyle(EmberTheme.ash)
                .padding(.top, 6)
                .padding(.horizontal, 4)

            if !context.glances.isEmpty {
                Text("Right now")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(EmberTheme.ash)
                    .padding(.top, 32)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(context.glances.enumerated()), id: \.element.id) { index, glance in
                        if index > 0 { Divider().padding(.leading, 60) }
                        Button {
                            ask(Self.question(for: glance.app))
                        } label: {
                            HStack(spacing: 12) {
                                EmberAppTile(app: glance.app, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(glance.value)
                                        .font(.body)
                                        .foregroundStyle(EmberTheme.text)
                                        .lineLimit(1)
                                    Text("\(glance.app.displayName) · \(glance.detail)")
                                        .font(.footnote)
                                        .foregroundStyle(EmberTheme.ash)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(EmberTheme.smoke)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 62)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Asks Ember about it")
                    }
                }
                .background(Color(white: 0.11), in: .rect(cornerRadius: 22))
                .padding(.top, 10)
            }

            if case .failed(let message) = conversation.phase {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(EmberTheme.text)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.11), in: .rect(cornerRadius: 18))
                    .padding(.top, 16)
            }
        }
        .padding(.bottom, 24)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        if let name = context.myFirstName { return "\(part), \(name)" }
        return part
    }

    /// What tapping an app's line asks.
    private static func question(for app: HearthApp) -> String {
        switch app {
        case .bigtable: "What’s for dinner tonight?"
        case .suffice: "How much is left in our budgets this month?"
        case .caloma: "What’s on the family calendar today?"
        case .sated: "How many calories do I have left today?"
        case .hearken: "What’s my reading today?"
        default: "What’s going on today?"
        }
    }

    private var starters: [String] {
        var result: [String] = []
        if settings.canRead(.suffice) { result.append("How much did we spend this week?") }
        if settings.canRead(.caloma) { result.append("What’s on tomorrow?") }
        result.append("Find a good place for lunch")
        result.append("Set a timer for 10 minutes")
        return result
    }

    // MARK: The conversation

    private var thread: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(brain.turns) { turn in
                EmberTurnView(turn: turn) { showsSent = true }
            }
            if isAnswering {
                VStack(alignment: .leading, spacing: 10) {
                    EmberQuestionBubble(text: conversation.question)
                    if conversation.liveAnswer.isEmpty {
                        HStack(spacing: 12) {
                            FiveEmbers(size: 28)
                            Text("Thinking…")
                                .font(.subheadline)
                                .foregroundStyle(EmberTheme.ash)
                        }
                        .padding(.vertical, 6)
                        .transition(.opacity)
                    } else {
                        Text(conversation.liveAnswer)
                            .font(.body)
                            .foregroundStyle(EmberTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            if let reply = conversation.localReply, !conversation.isVoicePresented {
                Text(reply)
                    .font(.body.weight(.medium))
                    .foregroundStyle(EmberTheme.accentSoft)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 16)
        .animation(.snappy, value: brain.turns.count)
    }

    // MARK: Composer (as in Ask Suffice)

    private var composer: some View {
        VStack(spacing: 10) {
            if !hasThread {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(starters, id: \.self) { starter in
                            Button(starter) { ask(starter) }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(EmberTheme.text)
                                .buttonStyle(.glass)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(hasThread ? "Ask a follow-up" : "Ask Ember", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .frame(minHeight: Self.composerHeight)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.composerHeight / 2))

                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        composerFocused = false
                        conversation.presentVoice()
                    } label: {
                        HearthMicRing(size: Self.composerHeight)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Talk to Ember")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(EmberTheme.accent, in: .circle)
                    .padding(.bottom, (Self.composerHeight - Self.buttonSize) / 2)
                    .accessibilityLabel("Send")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: draft.isEmpty)
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .readableWidth()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !text.isEmpty else { return }
        ask(text)
    }

    private func ask(_ text: String) {
        withAnimation(.snappy) { conversation.ask(text) }
    }
}

// MARK: - A turn in the conversation

/// The question in a bubble on the right, the answer below it, then where it came from and the
/// cards it brought.
struct EmberTurnView: View {
    let turn: EmberTurn
    var showSent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmberQuestionBubble(text: turn.question)
            Text(turn.answer)
                .font(.body)
                .foregroundStyle(turn.isNotice ? EmberTheme.accentSoft : EmberTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !turn.sources.isEmpty || turn.tier.usedCloud {
                HStack(spacing: 8) {
                    if !turn.sources.isEmpty {
                        HStack(spacing: -4) {
                            ForEach(turn.sources, id: \.self) { app in EmberAppTile(app: app, size: 18) }
                        }
                        Text("From " + turn.sources.map(\.displayName).formatted(.list(type: .and)))
                            .font(.footnote)
                            .foregroundStyle(EmberTheme.ash)
                    }
                    if turn.tier.usedCloud {
                        Button(action: showSent) {
                            Label(turn.tier == .claude ? "Claude helped" : "Private Cloud helped", systemImage: "cloud")
                                .font(.footnote)
                                .foregroundStyle(EmberTheme.ash)
                        }
                        .accessibilityHint("Shows exactly what was sent")
                    }
                }
            }
            ForEach(turn.cards) { card in
                EmberCardView(card: card)
            }
        }
    }
}

struct EmberQuestionBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(EmberTheme.accent, in: .rect(cornerRadius: 20))
        }
    }
}

/// Privacy rule 6: exactly what went to the cloud for the last answer.
struct EmberSentSheet: View {
    let turn: EmberTurn?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Names are replaced with [P1], [P2] and so on, and nothing that identifies you is sent. hearth-api checks it again and keeps nothing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(turn?.sentToCloud ?? "Nothing left your iPhone for this answer.")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("What Was Sent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { SheetDoneButton { dismiss() } }
            }
        }
    }
}
