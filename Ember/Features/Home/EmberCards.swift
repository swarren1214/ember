import SwiftUI

// The cards under an answer: what Ember read, from which app, with a way to open it there.
// They spring in one after another once the spoken answer has started.

struct EmberCardView: View {
    let card: EmberCard
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let app = card.app {
                HStack(spacing: 7) {
                    EmberAppTile(app: app, size: 20)
                    Text(app.displayName.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(EmberTheme.ash)
                }
            }
            content
            if let link = card.link, let title = card.actionTitle {
                Button {
                    openURL(link)
                } label: {
                    Label(title, systemImage: link.scheme == "tel" ? "phone.fill" : "arrow.up.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(EmberTheme.text)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .emberGlass(cornerRadius: 24)
    }

    @ViewBuilder
    private var content: some View {
        switch card.kind {
        case .meal(let title, let detail, let imageURL, let fits):
            if let imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.white.opacity(0.06))
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(EmberTheme.text)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(EmberTheme.ash)
            }
            if let fits {
                Label(fits ? "Fits everyone’s allergies" : "Doesn’t fit everyone’s allergies",
                      systemImage: fits ? "checkmark" : "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(fits ? Color(red: 0.94, green: 0.77, blue: 0.42) : Color(red: 1, green: 0.55, blue: 0.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.06), in: .capsule)
            }

        case .answer(let answer):
            EmberAnswerView(answer: answer)

        case .action(let id, let title, let detail, let symbol):
            EmberActionView(id: id, title: title, detail: detail, symbol: symbol)

        case .reading(let lines):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines, id: \.self) { line in
                    HStack(spacing: 12) {
                        Image(systemName: line.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(line.isDone ? EmberTheme.success : EmberTheme.smoke)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.title).font(.body.weight(.semibold)).foregroundStyle(EmberTheme.text)
                            Text(line.plan).font(.footnote).foregroundStyle(EmberTheme.ash)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(line.isDone ? "Done" : "Not yet")
                }
            }

        case .people(let names):
            HStack(spacing: -8) {
                ForEach(names.prefix(6), id: \.self) { name in
                    Text(String(name.prefix(1)))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(EmberTheme.text)
                        .frame(width: 34, height: 34)
                        .background(Color(red: 0.23, green: 0.17, blue: 0.15), in: .circle)
                        .overlay(Circle().stroke(EmberTheme.coal, lineWidth: 2))
                }
            }
            .accessibilityLabel(names.formatted(.list(type: .and)))

        case .allowance(let lines):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.body).foregroundStyle(EmberTheme.text)
                }
            }

        case .call(let name, let detail, let logo):
            HStack(spacing: 12) {
                EmberLogoTile(logo: logo, name: name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body.weight(.semibold)).foregroundStyle(EmberTheme.text)
                    if !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(EmberTheme.ash).lineLimit(2)
                    }
                }
            }
            .accessibilityElement(children: .combine)

        case .handoff(let title, let detail, let symbol):
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(EmberTheme.text)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(EmberTheme.text)
                    Text(detail).font(.footnote).foregroundStyle(EmberTheme.ash).lineLimit(2)
                }
            }
        }
    }
}

/// A Hearth app's tile: its icon from Assets (Hearth/<app>), or a tile in its color.
struct EmberAppTile: View {
    let app: HearthApp
    var size: CGFloat = 24

    var body: some View {
        Group {
            if UIImage(named: "Hearth/\(app.rawValue)") != nil {
                Image("Hearth/\(app.rawValue)")
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size * 0.28)
                    .fill(EmberTheme.color(app))
                    .overlay(Image(systemName: app.info.symbol).font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.28))
        .accessibilityHidden(true)
    }
}

/// The budget's progress, filling with a spring.
struct EmberBudgetBar: View {
    var fraction: Double
    @State private var shown = 0.0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(fraction > 1 ? Color(red: 1, green: 0.42, blue: 0.36) : Color(red: 0.18, green: 0.64, blue: 0.42))
                    .frame(width: proxy.size.width * min(max(shown, 0), 1))
            }
        }
        .frame(height: 10)
        .onAppear {
            withAnimation(.spring(duration: 0.9, bounce: 0.2).delay(0.2)) { shown = fraction }
        }
        .accessibilityElement()
        .accessibilityLabel("Spent")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

/// A business's logo from Logo.dev on a white tile (logos are drawn for light backgrounds), or
/// a person's initial when there's no logo.
struct EmberLogoTile: View {
    let logo: URL?
    let name: String
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let logo {
                AsyncImage(url: logo, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .padding(size * 0.12)
                            .frame(width: size, height: size)
                            .background(.white)
                    default:
                        initial
                    }
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.26))
        .accessibilityHidden(true)
    }

    private var initial: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(EmberTheme.text)
            .frame(width: size, height: size)
            .background(.white.opacity(0.08))
    }
}

/// Figures Ember worked out: a big value, a line under it, a bar for a budget, and rows.
struct EmberAnswerView: View {
    let answer: EmberAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(answer.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(EmberTheme.ash)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(answer.value)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(EmberTheme.text)
                        .contentTransition(.numericText())
                    if !answer.subtitle.isEmpty {
                        Text(answer.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(EmberTheme.ash)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if let fraction = answer.fraction {
                EmberBudgetBar(fraction: fraction)
            }
            if !answer.rows.isEmpty {
                VStack(spacing: 8) {
                    ForEach(answer.rows) { row in
                        HStack(spacing: 10) {
                            if let done = row.done {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(done ? EmberTheme.success : EmberTheme.smoke)
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(.body).foregroundStyle(EmberTheme.text).lineLimit(1)
                                if !row.detail.isEmpty {
                                    Text(row.detail).font(.footnote).foregroundStyle(EmberTheme.ash).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(row.value)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(EmberTheme.text)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(row.done == true ? "Done" : "")
                    }
                }
            }
        }
    }
}

/// A change Ember is making: Confirm and Cancel while it waits, then what happened, with Undo
/// for a couple of minutes.
struct EmberActionView: View {
    let id: UUID
    let title: String
    let detail: String
    let symbol: String

    @State private var actions = EmberActions.shared
    @State private var conversation = EmberConversation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(EmberTheme.text)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(EmberTheme.text)
                    if !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(EmberTheme.ash).lineLimit(3)
                    }
                }
            }
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch actions.states[id] {
        case .waiting:
            HStack(spacing: 10) {
                Button {
                    Task { conversation.speakResult(await actions.confirm(id)) }
                } label: {
                    Label("Confirm", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(EmberTheme.accent)
                Button("Cancel") { _ = actions.cancel(id) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glass)
                    .tint(.primary)
            }
        case .working:
            ProgressView().tint(EmberTheme.text)
        case .done:
            if actions.canUndo(id) {
                HStack {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(EmberTheme.success)
                    Spacer()
                    Button {
                        Task { conversation.speakResult(await actions.undo(id)) }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(EmberTheme.text)
                    }
                    .buttonStyle(.glass)
                }
            } else {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(EmberTheme.success)
            }
        case .undone:
            Label("Undone", systemImage: "arrow.uturn.backward.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(EmberTheme.ash)
        case .cancelled:
            Label("Not done", systemImage: "xmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(EmberTheme.ash)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
        case nil:
            EmptyView()
        }
    }
}
