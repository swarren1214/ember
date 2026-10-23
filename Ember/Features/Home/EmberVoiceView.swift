import SwiftUI

// Talking with Ember, hands free: the orb (Liquid Glass with a living light inside) sits in the
// middle and shows what Ember is doing, what you say appears under it in large type, and a glass
// panel at the bottom holds the answer, its cards and the one control that fits. Tapping the orb
// does the obvious thing: sends what you said, stops Ember talking, or turns the microphone back
// on. Type hands over to the text field; Done closes.

struct EmberVoiceView: View {
    /// Called when the person taps Type: the composer takes over.
    var onType: () -> Void = {}

    @State private var conversation = EmberConversation.shared
    @State private var brain = EmberBrain.shared
    @State private var micMode = EmberAudio.microphoneModeName
    @Environment(\.dismiss) private var dismiss

    private var reply: EmberTurn? {
        guard let id = conversation.replyID else { return nil }
        return brain.turns.first { $0.id == id }
    }

    private var orbMode: EmberOrb.Mode {
        switch conversation.phase {
        case .starting, .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        case .idle, .paused, .failed: .idle
        }
    }

    /// An answer is on screen: the orb steps back to make room.
    private var showsAnswer: Bool { conversation.phase != .thinking && answerText != nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 8)
            hero
            Spacer(minLength: 8)
            panel
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .readableWidth(640)
        .background(Color(white: 0.04).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            await conversation.startVoice()
            micMode = EmberAudio.microphoneModeName
        }
        .onDisappear { conversation.stopVoice() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Back from Control Center, where the microphone mode is picked.
            micMode = EmberAudio.microphoneModeName
        }
        .sensoryFeedback(.impact(weight: .light), trigger: conversation.phase == .thinking)
    }

    // MARK: The orb and what you said

    private var hero: some View {
        VStack(spacing: 18) {
            Button(action: orbTapped) {
                EmberOrb(mode: orbMode, size: 196)
                    .padding(24)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .scaleEffect(showsAnswer ? 0.62 : 1)
            .frame(height: showsAnswer ? 150 : 244)
            .accessibilityLabel(orbLabel)

            VStack(spacing: 10) {
                Text(heading)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(EmberTheme.ash)
                transcript
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.5), value: showsAnswer)
    }

    private var orbLabel: String {
        switch conversation.phase {
        case .listening: conversation.transcript.isEmpty ? "Ember is listening" : "Send"
        case .thinking, .speaking: "Stop Ember"
        case .paused, .failed: "Turn the microphone on"
        case .idle, .starting: "Ember"
        }
    }

    private func orbTapped() {
        switch conversation.phase {
        case .listening where !conversation.transcript.isEmpty: conversation.finishSpeaking()
        case .thinking, .speaking: conversation.interrupt()
        case .paused, .failed: Task { await conversation.resume() }
        default: break
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button("Close", systemImage: "xmark") { close() }
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            Spacer()
            Label("Private by design", systemImage: "lock")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .glassEffect(.regular, in: .capsule)
            Spacer()
            Button {
                EmberAudio.showMicrophoneModes()
            } label: {
                Image(systemName: micMode == "Voice Isolation" ? "person.wave.2.fill" : "waveform.and.mic")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Microphone mode: \(micMode)")
            .accessibilityHint("Choose Voice Isolation to keep other voices out.")
        }
        .padding(.top, 8)
    }

    // MARK: What you said

    private var transcript: some View {
        Group {
            if conversation.isListening || conversation.phase == .starting {
                if conversation.transcript.isEmpty {
                    Text(conversation.question.isEmpty ? "Ask about your household, or anything at all." : "Go ahead, I’m listening.")
                        .foregroundStyle(EmberTheme.ash)
                } else {
                    let words = conversation.transcript.split(separator: " ")
                    let pendingCount = min(3, max(words.count - 1, 0))
                    let settled = words.dropLast(pendingCount).joined(separator: " ")
                    let pending = words.suffix(pendingCount).joined(separator: " ")
                    Text("\(settled)\(Text(pending.isEmpty ? "" : " " + pending + "…").foregroundStyle(EmberTheme.ash))")
                }
            } else if !conversation.question.isEmpty {
                Text("“\(conversation.question)”")
            }
        }
        .font(.system(size: showsAnswer ? 20 : 26, weight: .semibold))
        .foregroundStyle(EmberTheme.text)
        .multilineTextAlignment(.center)
        .lineLimit(showsAnswer ? 2 : 5)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: conversation.transcript)
        .padding(.horizontal, 12)
    }

    private var heading: String {
        switch conversation.phase {
        case .starting, .listening: "Listening"
        case .thinking, .speaking: "You asked"
        case .paused: "Paused"
        case .idle, .failed: "Ember"
        }
    }

    // MARK: The panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            status
            if conversation.phase != .thinking, let shown = answerText {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            EmberOrb(mode: conversation.phase == .speaking ? .speaking : .idle, size: 18)
                            Text("Ember")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(EmberTheme.ash)
                        }
                        Text(shown)
                            .font(.body)
                            .foregroundStyle(reply?.isNotice == true ? EmberTheme.accentSoft : EmberTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let localReply = conversation.localReply {
                            Text(localReply)
                                .font(.body.weight(.medium))
                                .foregroundStyle(EmberTheme.accentSoft)
                        }
                        if let reply {
                            ForEach(reply.cards) { card in
                                EmberCardView(card: card)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 36))
        .animation(.snappy, value: conversation.phase)
    }

    private var answerText: String? {
        if let reply { return reply.answer }
        return conversation.liveAnswer.isEmpty ? nil : conversation.liveAnswer
    }

    /// What's happening now, with the one control that fits it.
    @ViewBuilder
    private var status: some View {
        switch conversation.phase {
        case .idle, .starting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Starting…").foregroundStyle(EmberTheme.ash)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        case .listening:
            HStack {
                Text(conversation.transcript.isEmpty ? "Ember answers when you pause." : "Pause when you’re done, or tap Send.")
                    .font(.footnote)
                    .foregroundStyle(EmberTheme.ash)
                Spacer()
                if !conversation.transcript.isEmpty {
                    Button("Send", systemImage: "arrow.up") { conversation.finishSpeaking() }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(EmberTheme.accent, in: .circle)
                        .buttonStyle(.plain)
                }
            }
            .frame(minHeight: 36)
        case .thinking:
            HStack(spacing: 12) {
                Text("Thinking… keep talking to change your question.")
                    .font(.footnote)
                    .foregroundStyle(EmberTheme.ash)
                Spacer()
                stopButton
            }
        case .speaking:
            HStack(spacing: 12) {
                Text("Start talking to interrupt.")
                    .font(.footnote)
                    .foregroundStyle(EmberTheme.ash)
                Spacer()
                stopButton
            }
        case .paused:
            HStack(spacing: 12) {
                Image(systemName: "mic.slash")
                    .foregroundStyle(EmberTheme.ash)
                Text("The microphone is off.")
                    .foregroundStyle(EmberTheme.ash)
                Spacer()
                Button {
                    Task { await conversation.resume() }
                } label: {
                    Label("Resume", systemImage: "mic.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(EmberTheme.text)
                .background(.white.opacity(0.12), in: .capsule)
            }
        case .failed(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(EmberTheme.text)
        }
    }

    private var stopButton: some View {
        Button("Stop", systemImage: "stop.fill") { conversation.interrupt() }
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(EmberTheme.text)
            .frame(width: 36, height: 36)
            .background(.white.opacity(0.14), in: .circle)
            .buttonStyle(.plain)
            .accessibilityLabel("Stop Ember and listen")
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                close()
                onType()
            } label: {
                Text("Type").frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .font(.headline)
            .foregroundStyle(EmberTheme.text)
            .background(.white.opacity(0.12), in: .capsule)

            if case .failed = conversation.phase {
                Button {
                    Task { await conversation.resume() }
                } label: {
                    Label("Try Again", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(.white)
                .background(EmberTheme.accent, in: .capsule)
            } else {
                Button { close() } label: {
                    Text("Done").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(.white)
                .background(EmberTheme.accent, in: .capsule)
            }
        }
    }

    private func close() {
        conversation.stopVoice()
        conversation.isVoicePresented = false
        dismiss()
    }
}
