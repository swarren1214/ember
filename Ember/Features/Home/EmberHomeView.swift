import SwiftUI

// Ember's one screen. The orb moves between four layouts as the conversation moves, and
// everything else crossfades around it:
//
//   idle       greeting, what each Hearth app has today, things to try; orb above the composer
//   listening  your words appear as you say them; orb rises and grows
//   thinking   the apps Ember is reading light up; orb breathes
//   answer     the spoken answer, then cards from each app; the orb waits small above the composer
//
// Like every Hearth app: a standard toolbar with the profile photo last, system type and text
// colors, Liquid Glass, and the composer from Ask Suffice and Coach (a glass field with a send
// button that appears once there's something to send).

struct EmberHomeView: View {
    @State private var conversation = EmberConversation.shared
    @State private var brain = EmberBrain.shared
    @State private var context = EmberContext.shared
    @State private var settings = EmberSettings.shared
    /// The answer the person closed (the idle screen shows again).
    @State private var dismissedTurn: UUID?
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var showsSent = false
    @State private var compose = EmberCompose.shared
    @State private var holdTimer: Task<Void, Never>?
    @State private var holdStarted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One line of the message field, and the send button inside it (as in Ask Suffice).
    private static let composerHeight: CGFloat = 46
    private static let buttonSize: CGFloat = 40

    enum Mode: Equatable { case idle, listening, thinking, answer }

    private var mode: Mode {
        switch conversation.phase {
        case .listening: .listening
        case .thinking: .thinking
        case .answering: .answer
        case .idle, .failed:
            if let latest = brain.latest, latest.id != dismissedTurn { .answer } else { .idle }
        }
    }

    private var orbMood: EmberOrbMood {
        switch mode {
        case .idle: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .answer: .answering
        }
    }

    /// The composer shows when Ember is waiting for you, not while it listens or thinks.
    private var showsComposer: Bool { mode == .idle || mode == .answer }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    ambient(in: size)

                    Group {
                        switch mode {
                        case .idle: idle
                        case .listening: listening(in: size)
                        case .thinking: thinking(in: size)
                        case .answer: answer
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.985)),
                        removal: .opacity
                    ))

                    // Typing: the orb steps aside for the keyboard.
                    if !composerFocused {
                        orbButton(in: size)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.85, bounce: 0.18), value: mode)
                .animation(.snappy, value: composerFocused)
            }
            .background(EmberTheme.coal.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsComposer {
                    composer
                        .transition(.opacity.combined(with: .offset(y: 20)))
                }
            }
            .animation(.snappy, value: showsComposer)
            .toolbar { toolbar }
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(weight: .light), trigger: mode)
        .sheet(isPresented: $showsSent) {
            EmberSentSheet(turn: brain.latest)
        }
        .sheet(item: $compose.presented) { request in
            EmberComposeSheet(request: request) { compose.presented = nil }
                .ignoresSafeArea()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if mode == .answer {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", systemImage: "xmark") { closeAnswer() }
                    .tint(.primary)
            }
        }
        if mode == .idle || mode == .answer {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(RadialGradient(colors: [Color(red: 1, green: 0.886, blue: 0.69), EmberTheme.accent, Color(red: 0.78, green: 0.2, blue: 0.16)],
                                             center: UnitPoint(x: 0.36, y: 0.34), startRadius: 0, endRadius: 11))
                        .frame(width: 16, height: 16)
                        .shadow(color: EmberTheme.accent.opacity(0.55), radius: 6)
                    Text("Ember").font(.headline)
                }
                .accessibilityElement(children: .combine)
            }
            // The profile photo, last, as in every Hearth app.
            ToolbarItem(placement: .topBarTrailing) {
                HearthProfileButton(overHeader: false)
            }
        }
    }

    private func closeAnswer() {
        conversation.cancel()
        dismissedTurn = brain.latest?.id
    }

    // MARK: The orb

    private func orbFrame(in size: CGSize) -> (center: CGPoint, diameter: CGFloat) {
        let width = size.width
        switch mode {
        case .idle: return (CGPoint(x: width / 2, y: size.height - 96), 112)
        case .listening: return (CGPoint(x: width / 2, y: size.height * 0.34), min(236, width * 0.6))
        case .thinking: return (CGPoint(x: width / 2, y: size.height * 0.34), 164)
        case .answer: return (CGPoint(x: width / 2, y: size.height - 52), 56)
        }
    }

    private func orbButton(in size: CGSize) -> some View {
        let frame = orbFrame(in: size)
        return EmberOrb(mood: orbMood, meter: .shared, speaking: EmberSpeaker.shared.isSpeaking)
            .frame(width: frame.diameter, height: frame.diameter)
            .scaleEffect(conversation.isHolding ? 1.08 : 1)
            .animation(.spring(duration: 0.35, bounce: 0.3), value: conversation.isHolding)
            .contentShape(.circle)
            // Tap to talk; hold to talk and let go to send (best in a noisy room).
            .onTapGesture {
                guard !holdStarted else { return }
                if mode == .answer, conversation.phase == .idle { dismissedTurn = brain.latest?.id }
                conversation.tapOrb()
            }
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 80) {
            } onPressingChanged: { pressing in
                holdTimer?.cancel()
                if pressing {
                    holdTimer = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        holdStarted = true
                        if mode == .answer { dismissedTurn = brain.latest?.id }
                        conversation.beginHold()
                    }
                } else if holdStarted {
                    conversation.endHold()
                    Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        holdStarted = false
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: conversation.isHolding)
            .position(frame.center)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { conversation.tapOrb() }
            .accessibilityLabel(mode == .listening ? "Done talking" : "Talk to Ember")
            .accessibilityHint(mode == .listening ? "Sends what you said" : "Ember listens and answers out loud")
    }

    private func ambient(in size: CGSize) -> some View {
        let frame = orbFrame(in: size)
        let radius: CGFloat = mode == .listening ? 380 : mode == .answer ? 160 : 260
        let strength: Double = mode == .listening ? 1 : mode == .thinking ? 0.8 : mode == .answer ? 0.3 : 0.5
        return RadialGradient(
            colors: [Color(red: 1, green: 0.44, blue: 0.16).opacity(0.24 * strength), Color(red: 1, green: 0.31, blue: 0.12).opacity(0.09 * strength), .clear],
            center: UnitPoint(x: frame.center.x / max(size.width, 1), y: frame.center.y / max(size.height, 1)),
            startRadius: 0, endRadius: radius
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The line under the orb that says what it does.
    private func orbHint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(EmberTheme.ash)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    // MARK: Idle

    private var idle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(EmberTheme.ash)
                    .padding(.top, 12)
                Text(greeting)
                    .font(.largeTitle.bold())
                    .foregroundStyle(EmberTheme.text)
                    .padding(.top, 2)
                Text(context.glances.isEmpty ? "Ask me anything about your household." : "Here’s your household today.")
                    .font(.body)
                    .foregroundStyle(EmberTheme.ash)
                    .padding(.top, 6)

                if !context.glances.isEmpty {
                    sectionHeader("Today Across Hearth").padding(.top, 36)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(context.glances) { glance in
                                EmberGlanceCard(glance: glance)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollClipDisabled()
                    .padding(.top, 12)
                }

                sectionHeader("Try Asking").padding(.top, 36)
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.text) { index, suggestion in
                        if index > 0 { Divider().padding(.leading, suggestion.app == nil ? 18 : 58) }
                        Button {
                            ask(suggestion.text)
                        } label: {
                            HStack(spacing: 12) {
                                if let app = suggestion.app {
                                    EmberAppTile(app: app, size: 28)
                                }
                                Text(suggestion.text)
                                    .font(.body)
                                    .foregroundStyle(EmberTheme.text)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(EmberTheme.text)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 56)
                            .contentShape(.rect)
                        }
                        .buttonStyle(EmberPressStyle())
                    }
                }
                .emberGlass(cornerRadius: 24)
                .padding(.top, 12)

                if case .failed(let message) = conversation.phase {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(EmberTheme.text)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .emberGlass(cornerRadius: 18)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            // Room for the orb and its hint below the last row.
            .padding(.bottom, 190)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottom) {
            if !composerFocused {
                orbHint("Tap the orb to talk · Hold it while you speak")
                    .padding(.bottom, 12)
                    .background(alignment: .bottom) { bottomFade(height: 200) }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        if let name = context.myFirstName { return "\(part), \(name)" }
        return part
    }

    private struct Suggestion: Hashable {
        var text: String
        var app: HearthApp?
    }

    private var suggestions: [Suggestion] {
        var result: [Suggestion] = []
        let hour = Calendar.current.component(.hour, from: .now)
        if context.mealPlan != nil, hour >= 14 { result.append(Suggestion(text: "What’s for dinner tonight?", app: .bigtable)) }
        if settings.canRead(.suffice) { result.append(Suggestion(text: "How much did we spend this week?", app: .suffice)) }
        if settings.canRead(.caloma) {
            result.append(Suggestion(text: hour < 12 ? "What’s on the calendar today?" : "Did the kids finish their chores?", app: .caloma))
        }
        if context.foodLog != nil { result.append(Suggestion(text: "How many calories do I have left?", app: .sated)) }
        if context.reading != nil { result.append(Suggestion(text: "What’s my reading today?", app: .hearken)) }
        if result.count < 3 { result.append(Suggestion(text: "Add milk to the grocery list", app: .bigtable)) }
        if result.count < 3 { result.append(Suggestion(text: "Set a timer for 10 minutes")) }
        return Array(result.prefix(3))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(EmberTheme.text)
            .accessibilityAddTraits(.isHeader)
    }

    private func bottomFade(height: CGFloat) -> some View {
        LinearGradient(colors: [EmberTheme.coal.opacity(0), EmberTheme.coal.opacity(0.92)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
            .frame(height: height)
            .allowsHitTesting(false)
    }

    // MARK: Listening

    private func listening(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                EmberLiveDot()
                Text(conversation.isHolding ? "Listening while you hold" : "Listening")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(EmberTheme.ash)
            }
            .padding(.top, 24)
            Spacer().frame(height: size.height * 0.34 + 104)
            Text(conversation.transcript.isEmpty ? "Go ahead, I’m listening." : conversation.transcript)
                .font(.title2.weight(.semibold))
                .foregroundStyle(conversation.transcript.isEmpty ? EmberTheme.smoke : EmberTheme.text)
                .multilineTextAlignment(.center)
                .contentTransition(.interpolate)
                .animation(.smooth(duration: 0.35), value: conversation.transcript)
                .padding(.horizontal, 32)
                .accessibilityLabel(conversation.transcript.isEmpty ? "Listening" : conversation.transcript)
            Spacer()
            if let pending = conversation.pendingSend {
                EmberSendingBar(text: pending) { conversation.tapOrb() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            } else if conversation.isNoisyRoom, !conversation.isHolding {
                EmberNoisyHint()
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
            orbHint(conversation.isHolding ? "Let go to send" : "Tap the orb when you’re done")
            Button {
                conversation.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(EmberTheme.text)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Stop Listening")
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Thinking

    private func thinking(in size: CGSize) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: size.height * 0.34 + 112)
            Text("Looking across Hearth")
                .font(.headline)
                .foregroundStyle(EmberTheme.text)
            HStack(spacing: 8) {
                ForEach(Array(readingApps.enumerated()), id: \.element) { index, app in
                    EmberSourceChip(app: app, delay: Double(index) * 0.3)
                }
            }
            .padding(.horizontal, 20)
            Text("“\(conversation.question)”")
                .font(.callout)
                .foregroundStyle(EmberTheme.ash)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 4)
            Spacer()
            Button("Stop") { conversation.cancel() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(EmberTheme.text)
                .buttonStyle(.glass)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }

    /// The apps Ember can read (four at most, so the row fits).
    private var readingApps: [HearthApp] {
        let all = [HearthApp.bigtable, .suffice, .caloma, .sated, .hearken].filter { settings.canRead($0) }
        return Array(all.prefix(4))
    }

    // MARK: Answer

    private var shownTurn: EmberTurn? {
        guard !brain.isThinking else { return nil }
        return brain.latest
    }

    private var answer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(shownTurn?.question ?? conversation.question)
                    .font(.subheadline)
                    .foregroundStyle(EmberTheme.ash)
                    .padding(.top, 12)
                Text(shownTurn?.answer ?? conversation.liveAnswer)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(shownTurn?.isNotice == true ? EmberTheme.accentSoft : EmberTheme.text)
                    .contentTransition(.interpolate)
                    .animation(.smooth(duration: 0.4), value: conversation.liveAnswer)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                if let reply = conversation.localReply {
                    Text(reply)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(EmberTheme.accentSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                        .padding(.top, 12)
                }

                if let turn = shownTurn {
                    sourcesLine(turn).padding(.top, 14)
                    VStack(spacing: 14) {
                        ForEach(Array(turn.cards.enumerated()), id: \.element.id) { index, card in
                            EmberCardView(card: card)
                                .transition(.asymmetric(insertion: .offset(y: 30).combined(with: .scale(scale: 0.95)).combined(with: .opacity), removal: .opacity))
                                .animation(.spring(duration: 0.75, bounce: 0.25).delay(0.05 + Double(index) * 0.12), value: turn.id)
                        }
                    }
                    .padding(.top, 24)
                }

                if mode == .answer, conversation.phase == .idle, !followUps.isEmpty {
                    sectionHeader("Ask Next").padding(.top, 32)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(followUps, id: \.self) { suggestion in
                            Button(suggestion) { ask(suggestion) }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(EmberTheme.text)
                                .buttonStyle(.glass)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 140)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottom) {
            if !composerFocused {
                bottomFade(height: 140)
            }
        }
    }

    private func sourcesLine(_ turn: EmberTurn) -> some View {
        HStack(spacing: 8) {
            if !turn.sources.isEmpty {
                HStack(spacing: -4) {
                    ForEach(turn.sources, id: \.self) { app in
                        EmberAppTile(app: app, size: 20)
                    }
                }
                Text("From " + turn.sources.map(\.displayName).formatted(.list(type: .and)))
                    .font(.footnote)
                    .foregroundStyle(EmberTheme.ash)
            }
            if turn.tier.usedCloud {
                Button {
                    showsSent = true
                } label: {
                    Label(turn.tier == .claude ? "Claude helped" : "Private Cloud helped", systemImage: "cloud")
                        .font(.footnote)
                        .foregroundStyle(EmberTheme.ash)
                }
                .accessibilityHint("Shows exactly what was sent")
            }
        }
    }

    private var followUps: [String] {
        suggestions.map(\.text).filter { $0 != brain.latest?.question }.prefix(2).map { $0 }
    }

    // MARK: Composer (as in Ask Suffice)

    private var composer: some View {
        VStack(spacing: 10) {
            if mode == .answer, !composerFocused {
                orbHint("Tap the orb to ask a follow-up, or type below")
                    // The orb sits just above this line (see orbFrame).
                    .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(mode == .answer ? "Ask a follow-up" : "Ask Ember", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .frame(minHeight: Self.composerHeight)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.composerHeight / 2))

                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        .padding(.bottom, 8)
        .readableWidth()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        composerFocused = false
        guard !text.isEmpty else { return }
        ask(text)
    }

    private func ask(_ text: String) {
        conversation.ask(text)
    }
}


// MARK: - Pieces

private struct EmberGlanceCard: View {
    let glance: EmberContext.Glance
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let link = glance.link { openURL(link) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    EmberAppTile(app: glance.app, size: 26)
                    Text(glance.app.displayName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(EmberTheme.ash)
                }
                Spacer(minLength: 12)
                Text(glance.value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(EmberTheme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(glance.detail)
                    .font(.footnote)
                    .foregroundStyle(EmberTheme.ash)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .padding(16)
            .frame(width: 168, height: 136, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(EmberPressStyle())
        .emberGlass(cornerRadius: 24)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(glance.app.displayName)")
    }
}

private struct EmberSourceChip: View {
    let app: HearthApp
    let delay: Double
    @State private var glowing = false

    var body: some View {
        HStack(spacing: 7) {
            EmberAppTile(app: app, size: 22)
                .shadow(color: Color(red: 1, green: 0.55, blue: 0.24).opacity(glowing ? 0.6 : 0), radius: 8)
            Text(app.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(EmberTheme.text)
        }
        .padding(.leading, 7)
        .padding(.trailing, 12)
        .frame(height: 36)
        .emberGlass(cornerRadius: 18)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever().delay(delay)) { glowing = true }
        }
    }
}

struct EmberLiveDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(EmberTheme.accent)
            .frame(width: 7, height: 7)
            .shadow(color: EmberTheme.accent, radius: 5)
            .opacity(on ? 0.4 : 1)
            .scaleEffect(on ? 0.7 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = true } }
            .accessibilityHidden(true)
    }
}

/// A soft, springy press, like the prototype's taps.
struct EmberPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
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

/// A turn about to be sent in a noisy room: what was heard, a short countdown, and Stop.
struct EmberSendingBar: View {
    let text: String
    let stop: () -> Void
    @State private var progress = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sending…")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(EmberTheme.ash)
                Spacer()
                Button("Stop", action: stop)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glass)
                    .tint(.primary)
            }
            ProgressView(value: progress)
                .tint(EmberTheme.accent)
        }
        .padding(14)
        .emberGlass(cornerRadius: 20)
        .onAppear {
            withAnimation(.linear(duration: 1.2)) { progress = 1 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending “\(text)”")
        .accessibilityAction(named: "Stop", stop)
    }
}

/// Other voices keep reaching the microphone: holding the orb works better here.
struct EmberNoisyHint: View {
    var body: some View {
        Label("Noisy room · Hold the orb while you talk", systemImage: "waveform.badge.exclamationmark")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(EmberTheme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white.opacity(0.08), in: .capsule)
    }
}
