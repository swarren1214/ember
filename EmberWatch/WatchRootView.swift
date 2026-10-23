import AuthenticationServices
import SwiftUI

// The Watch screens, from the "Ember Redesign" canvas:
//
//   Face      the orb (Liquid Glass with the living light) and one glance
//   Thinking  the orb's colors swirl around its white heart
//   Answer    the answer, spoken, with a small orb pulsing; at most two buttons; Done
//
// The orb is the talk button: tapping it opens dictation, and what's said is sent when it closes.

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @State private var signedIn = true
    @State private var nonce = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.phase {
            case .face: face
            case .thinking(let question): thinking(question)
            case .answer(let reply): answer(reply)
            case .failed(let message):
                ScrollView {
                    VStack(spacing: 10) {
                        Text(message).multilineTextAlignment(.center)
                        Button("Done") { model.dismiss() }
                    }
                }
            }
        }
        .animation(.snappy, value: model.phase)
        .task { signedIn = await WatchAccount.shared.isSignedIn }
    }

    // MARK: Face

    private var face: some View {
        ScrollView {
            VStack(spacing: 8) {
                TextFieldLink(prompt: Text("Ask Ember")) {
                    // A filled circle under the orb, so the whole button takes the tap.
                    ZStack {
                        Circle().fill(Color.black.opacity(0.001))
                        EmberOrb(mode: .idle, size: 92)
                    }
                    .frame(width: 108, height: 108)
                    .contentShape(.circle)
                } onSubmit: { text in
                    model.ask(text)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask Ember")

                Text("Tap to ask")
                    .font(.headline)
                if let glance = model.glances.first {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: glance.app))
                            .frame(width: 8, height: 8)
                        Text("\(glance.detail): \(glance.title)")
                            .lineLimit(1)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.1), in: .capsule)
                }
                // Signing in lets the Watch answer by itself (faster, and without the iPhone),
                // when Cloud Help with Claude is on.
                if !signedIn, model.context?.allowsClaude == true {
                    Text("Sign in to ask without your iPhone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
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
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .transition(.opacity)
    }

    private func color(for app: String) -> Color {
        switch app {
        case "bigtable": EmberPalette.colors[0]
        case "sated": EmberPalette.colors[1]
        case "suffice": EmberPalette.colors[2]
        case "hearken": EmberPalette.colors[3]
        case "caloma": EmberPalette.colors[4]
        default: .orange
        }
    }

    // MARK: Thinking

    private func thinking(_ question: String) -> some View {
        VStack(spacing: 14) {
            EmberOrb(mode: .thinking, size: 84)
            Text("“\(question)”")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .transition(.opacity)
    }

    // MARK: Answer

    private func answer(_ reply: EmberWatchReply) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    EmberOrb(mode: model.isSpeaking ? .speaking : .idle, size: 30)
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
                        .tint(url.scheme == "tel" ? .green : Color(red: 0.93, green: 0.35, blue: 0.11))
                    } else if let followUp = action.followUp {
                        Button(action.title) { model.ask(followUp) }
                    }
                }
                Button("Done") { model.dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .transition(.opacity.combined(with: .offset(y: 12)))
    }
}
