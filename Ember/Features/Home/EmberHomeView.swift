import SwiftUI

// Ember's one screen (the "iPhone · Talk to Ember" artboard): the orb moves between four
// layouts as the conversation moves, and everything else crossfades around it.
//
//   idle       greeting, what each Hearth app has today, things to try; orb low, ready
//   listening  your words appear as you say them; orb rises and grows
//   thinking   the apps Ember is reading light up; orb spins
//   answer     the spoken answer, then cards from each app; orb shrinks to the bottom

struct EmberHomeView: View {
    @State private var conversation = EmberConversation.shared
    @State private var brain = EmberBrain.shared
    @State private var context = EmberContext.shared
    @State private var settings = EmberSettings.shared
    /// The answer the person closed with Done (the idle screen shows again).
    @State private var dismissedTurn: UUID?
    @State private var isTyping = false
    @State private var typed = ""
    @State private var showsSent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                EmberTheme.coal.ignoresSafeArea()
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

                orbButton(in: size)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.85, bounce: 0.18), value: mode)
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(weight: .light), trigger: mode)
        .alert("Ask Ember", isPresented: $isTyping) {
            TextField("What’s for dinner?", text: $typed)
            Button("Ask") {
                let text = typed
                typed = ""
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { conversation.ask(text) }
            }
            Button("Cancel", role: .cancel) { typed = "" }
        }
        .sheet(isPresented: $showsSent) {
            EmberSentSheet(turn: brain.latest)
        }
    }

    // MARK: The orb

    private func orbFrame(in size: CGSize) -> (center: CGPoint, diameter: CGFloat) {
        let width = size.width
        switch mode {
        case .idle: return (CGPoint(x: width / 2, y: size.height - 120), 124)
        case .listening: return (CGPoint(x: width / 2, y: size.height * 0.32), min(236, width * 0.6))
        case .thinking: return (CGPoint(x: width / 2, y: size.height * 0.32), 164)
        case .answer: return (CGPoint(x: width / 2, y: size.height - 70), 64)
        }
    }

    private func orbButton(in size: CGSize) -> some View {
        let frame = orbFrame(in: size)
        return Button {
            if mode == .answer, conversation.phase == .idle { dismissedTurn = brain.latest?.id }
            conversation.tapOrb()
        } label: {
            EmberOrb(mood: orbMood, level: conversation.level, speaking: EmberSpeaker.shared.isSpeaking)
                .frame(width: frame.diameter, height: frame.diameter)
                .contentShape(.circle)
        }
        .buttonStyle(EmberPressStyle())
        .position(frame.center)
        .accessibilityLabel(mode == .listening ? "Done talking" : "Talk to Ember")
        .accessibilityHint(mode == .listening ? "Sends what you said" : "Ember listens and answers out loud")
    }

    private func ambient(in size: CGSize) -> some View {
        let frame = orbFrame(in: size)
        let radius: CGFloat = mode == .listening ? 380 : mode == .answer ? 180 : 280
        let strength: Double = mode == .listening ? 1 : mode == .thinking ? 0.8 : mode == .answer ? 0.35 : 0.55
        return RadialGradient(
            colors: [Color(red: 1, green: 0.44, blue: 0.16).opacity(0.26 * strength), Color(red: 1, green: 0.31, blue: 0.12).opacity(0.1 * strength), .clear],
            center: UnitPoint(x: frame.center.x / max(size.width, 1), y: frame.center.y / max(size.height, 1)),
            startRadius: 0, endRadius: radius
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Idle

    private var idle: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 9) {
                    Circle()
                        .fill(RadialGradient(colors: [Color(red: 1, green: 0.886, blue: 0.69), EmberTheme.accent, Color(red: 0.78, green: 0.2, blue: 0.16)], center: UnitPoint(x: 0.36, y: 0.34), startRadius: 0, endRadius: 14))
                        .frame(width: 22, height: 22)
                        .shadow(color: EmberTheme.accent.opacity(0.55), radius: 7)
                    Text("Ember").font(.title3.weight(.semibold)).foregroundStyle(EmberTheme.text)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                HearthProfileButton(overHeader: false)
            }
            .padding(.top, 8)

            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(EmberTheme.ash)
                .padding(.top, 24)
            Text(greeting)
                .font(.largeTitle.bold())
                .foregroundStyle(EmberTheme.text)
                .padding(.top, 4)
            Text(context.glances.isEmpty ? "Ask me anything about your household." : "Here’s your household today.")
                .font(.body)
                .foregroundStyle(EmberTheme.ash)
                .padding(.top, 4)

            if !context.glances.isEmpty {
                sectionLabel("ACROSS HEARTH").padding(.top, 28)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(context.glances) { glance in
                            EmberGlanceCard(glance: glance)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
                .padding(.top, 10)
            }

            sectionLabel("TRY ASKING").padding(.top, 28)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        conversation.ask(suggestion)
                    } label: {
                        HStack {
                            Text(suggestion).font(.body.weight(.medium)).foregroundStyle(EmberTheme.text)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(EmberTheme.text.opacity(0.5))
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .contentShape(.rect)
                    }
                    .buttonStyle(EmberPressStyle())
                    .emberGlass(cornerRadius: 16)
                }
            }
            .padding(.top, 10)

            if case .failed(let message) = conversation.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(EmberTheme.accentSoft)
                    .padding(.top, 12)
            }

            Spacer(minLength: 210)
        }
        .padding(.horizontal, 20)
        .readableWidth()
        .overlay(alignment: .bottom) {
            bottomBar(hint: "Tap to talk · Hold the Action button anywhere", trailing: nil)
                .padding(.bottom, 24)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        if let name = context.myFirstName { return "\(part), \(name)." }
        return "\(part)."
    }

    private var suggestions: [String] {
        var result: [String] = []
        if context.mealPlan != nil { result.append("What’s for dinner tonight?") }
        if context.groceryBudget != nil, !context.isKid { result.append("How’s the grocery budget?") }
        if context.reading != nil { result.append("What’s my reading today?") }
        if result.count < 3 { result.append("Who’s in our household?") }
        if result.count < 3, context.groceries != nil { result.append("How much is left on the grocery list?") }
        return Array(result.prefix(3))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(EmberTheme.ash)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Listening

    private func listening(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                EmberLiveDot()
                Text("LISTENING").font(.footnote.weight(.semibold)).tracking(0.8).foregroundStyle(EmberTheme.ash)
            }
            .padding(.top, 40)
            Spacer().frame(height: size.height * 0.32 + 120)
            Text(conversation.transcript.isEmpty ? " " : conversation.transcript)
                .font(.title.weight(.semibold))
                .foregroundStyle(EmberTheme.text)
                .multilineTextAlignment(.center)
                .contentTransition(.interpolate)
                .animation(.smooth(duration: 0.35), value: conversation.transcript)
                .padding(.horizontal, 28)
                .accessibilityLabel(conversation.transcript.isEmpty ? "Listening" : conversation.transcript)
            Spacer()
            Text("Tap the orb when you’re done")
                .font(.footnote)
                .foregroundStyle(EmberTheme.smoke)
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
            .accessibilityLabel("Stop listening")
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Thinking

    private func thinking(in size: CGSize) -> some View {
        VStack(spacing: 14) {
            Spacer().frame(height: size.height * 0.32 + 120)
            Text("Looking across Hearth")
                .font(.headline)
                .foregroundStyle(EmberTheme.text)
            HStack(spacing: 8) {
                ForEach(Array(readingApps.enumerated()), id: \.element) { index, app in
                    EmberSourceChip(app: app, delay: Double(index) * 0.3)
                }
            }
            Text("“\(conversation.question)”")
                .font(.callout)
                .foregroundStyle(EmberTheme.smoke)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var readingApps: [HearthApp] {
        [HearthApp.bigtable, .suffice, .caloma, .hearken].filter { settings.canRead($0) && !(context.isKid && $0 == .suffice) }
    }

    // MARK: Answer

    private var shownTurn: EmberTurn? {
        guard !brain.isThinking else { return nil }
        return brain.latest
    }

    private var answer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(shownTurn?.question ?? conversation.question)
                    .font(.callout)
                    .foregroundStyle(EmberTheme.smoke)
                Text(shownTurn?.answer ?? conversation.liveAnswer)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(shownTurn?.isNotice == true ? EmberTheme.accentSoft : EmberTheme.text)
                    .contentTransition(.interpolate)
                    .animation(.smooth(duration: 0.4), value: conversation.liveAnswer)
                    .fixedSize(horizontal: false, vertical: true)

                if let turn = shownTurn {
                    sourcesLine(turn)
                    ForEach(Array(turn.cards.enumerated()), id: \.element.id) { index, card in
                        EmberCardView(card: card)
                            .transition(.asymmetric(insertion: .offset(y: 30).combined(with: .scale(scale: 0.95)).combined(with: .opacity), removal: .opacity))
                            .animation(.spring(duration: 0.75, bounce: 0.25).delay(0.05 + Double(index) * 0.12), value: turn.id)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 200)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) {
            VStack(spacing: 14) {
                followUps
                bottomBar(hint: "Tap to ask a follow-up", trailing: {
                    dismissedTurn = brain.latest?.id
                })
            }
            .padding(.bottom, 24)
            .background(alignment: .bottom) {
                LinearGradient(colors: [EmberTheme.coal.opacity(0), EmberTheme.coal], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
                    .frame(height: 220)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }

    private func sourcesLine(_ turn: EmberTurn) -> some View {
        HStack(spacing: 6) {
            ForEach(turn.sources, id: \.self) { app in
                Circle().fill(EmberTheme.color(app)).frame(width: 8, height: 8)
            }
            if !turn.sources.isEmpty {
                Text("From " + turn.sources.map(\.displayName).formatted(.list(type: .and)))
                    .font(.footnote)
                    .foregroundStyle(EmberTheme.smoke)
            }
            if turn.tier.usedCloud {
                Button {
                    showsSent = true
                } label: {
                    Label(turn.tier == .claude ? "Claude helped" : "Private Cloud helped", systemImage: "cloud")
                        .font(.footnote)
                        .foregroundStyle(EmberTheme.smoke)
                }
                .accessibilityHint("Shows exactly what was sent")
            }
        }
    }

    private var followUps: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestions.filter { $0 != brain.latest?.question }.prefix(2), id: \.self) { suggestion in
                    Button(suggestion) { conversation.ask(suggestion) }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(EmberTheme.text)
                        .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Bottom bar

    private func bottomBar(hint: String, trailing: (() -> Void)?) -> some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    isTyping = true
                } label: {
                    Image(systemName: "keyboard")
                        .foregroundStyle(EmberTheme.text)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Type Instead")
                Spacer()
                if let trailing {
                    Button(action: trailing) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(EmberTheme.text)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Done")
                }
            }
            .padding(.horizontal, 34)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(EmberTheme.smoke)
        }
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
            VStack(alignment: .leading) {
                HStack(spacing: 7) {
                    EmberAppTile(app: glance.app, size: 24)
                    Text(glance.app.displayName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(EmberTheme.ash)
                }
                Spacer(minLength: 10)
                Text(glance.value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(EmberTheme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(glance.detail)
                    .font(.footnote)
                    .foregroundStyle(EmberTheme.ash)
            }
            .padding(14)
            .frame(width: 156, height: 124, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(EmberPressStyle())
        .emberGlass(cornerRadius: 22)
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
