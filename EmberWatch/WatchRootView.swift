import AuthenticationServices
import SwiftUI

// The Watch screens (the "Apple Watch · Raise to speak" artboard, minus the raise gesture,
// which belongs to Siri): the orb and a glance; tap and dictate; the answer, spoken, with at
// most two buttons; a check when something's handed off.

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @State private var signedIn = true
    @State private var nonce = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [Color(red: 1, green: 0.44, blue: 0.16).opacity(glow), .clear], center: .center, startRadius: 0, endRadius: 150)
                .ignoresSafeArea()
                .animation(.smooth(duration: 0.8), value: model.phase)

            switch model.phase {
            case .face: face
            case .thinking(let question): thinking(question)
            case .answer(let reply): answer(reply)
            case .failed(let message): Text(message).multilineTextAlignment(.center)
            }
        }
        .animation(.spring(duration: 0.7, bounce: 0.2), value: model.phase)
        .task { signedIn = await WatchAccount.shared.isSignedIn }
    }

    private var glow: Double {
        switch model.phase {
        case .face: 0.3
        case .thinking: 0.45
        case .answer: 0.12
        case .failed: 0.1
        }
    }

    // MARK: Face

    private var face: some View {
        VStack(spacing: 8) {
            // Tapping the orb opens dictation; what's said is sent when it closes.
            TextFieldLink(prompt: Text("Ask Ember")) {
                EmberOrb(mood: .idle)
                    .frame(width: 92, height: 92)
            } onSubmit: { text in
                model.ask(text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Talk to Ember")

            Text("Tap to talk")
                .font(.headline)
            if let glance = model.glances.first {
                Text("\(glance.detail): \(glance.title)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.08), in: .capsule)
            }
            if !model.isIPhoneReachable && !signedIn {
                SignInWithAppleButton(.signIn) { request in
                    nonce = WatchAccount.prepare(request)
                } onCompletion: { result in
                    guard case .success(let authorization) = result,
                          let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
                    let currentNonce = nonce
                    Task {
                        try? await WatchAccount.shared.signIn(identityToken: credential.identityToken, nonce: currentNonce)
                        signedIn = await WatchAccount.shared.isSignedIn
                    }
                }
                .frame(height: 40)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    // MARK: Thinking

    private func thinking(_ question: String) -> some View {
        VStack(spacing: 10) {
            EmberOrb(mood: .thinking)
                .frame(width: 100, height: 100)
            Text(question)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .transition(.opacity)
    }

    // MARK: Answer

    private func answer(_ reply: EmberWatchReply) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    EmberOrb(mood: .answering)
                        .frame(width: 24, height: 24)
                    if reply.tier.usedCloud {
                        Image(systemName: "cloud")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Answered with cloud help")
                    }
                }
                Text(reply.text)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(reply.actions) { action in
                    if let url = action.url.flatMap(URL.init(string:)) {
                        Link(destination: url) {
                            Text(action.title).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 1, green: 0.478, blue: 0.184))
                    } else if let followUp = action.followUp {
                        Button(action.title) { model.ask(followUp) }
                    }
                }
                Button("Done") { model.dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .transition(.opacity.combined(with: .offset(y: 16)))
    }
}
