// HearthSync.swift — the iCloud Sync card every Hearth app shows in Settings: whether iCloud sync
// is working, when it last synced, who the data is shared with, and a Sync Now button.
//
// Canonical copy: ~/Developer/hearthkit/HearthSync.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthShared.swift and
// HearthApps.swift (for `HearthApp` and its colors).
//
// Using it
// - Each app keeps a `HearthSyncSnapshot` up to date from its own sync engine and passes it in,
//   with what syncs ("Your food log and goals") and the action that syncs now:
//
//       Section("iCloud") {
//           HearthSyncCard(app: .sated, snapshot: monitor.snapshot, summary: "Your food log and goals") {
//               await CloudRefresh.refresh()
//           }
//           .hearthSyncCardRow()          // in a Form or List; leave it off in a ScrollView
//       }
//
// - The card works out the rest itself: offline (from the network), syncing while the action
//   runs, the relative "Last synced" time, and Open Settings when iCloud is off.

import Network
import Observation
import SwiftUI
import UIKit

// MARK: - What the app reports

nonisolated struct HearthSyncSnapshot: Equatable, Sendable {
    nonisolated enum Account: Equatable, Sendable {
        /// Still asking iCloud.
        case checking
        case available
        /// Signed out, restricted, or iCloud turned off for the app. The text says why, when known.
        case unavailable(String?)
    }

    var account: Account = .checking
    /// The engine is sending or fetching right now.
    var isSyncing = false
    /// The last time a sync finished without an error.
    var lastSynced: Date?
    /// Changes saved here that haven't gone up yet; nil when the engine can't tell.
    var pendingChanges: Int?
    /// The last sync's error, in words a person can act on. Clear it when a sync succeeds.
    var errorMessage: String?
}

/// Who the data is shared with, for apps that share (Suffice, Caloma, Hearken's study groups).
nonisolated struct HearthSyncSharing: Equatable, Sendable {
    nonisolated struct Person: Equatable, Sendable, Identifiable {
        var id: String
        /// One letter.
        var initial: String
        /// 0xRRGGBB.
        var colorHex: UInt32
    }

    /// "Your partner", "Your family", "2 study groups".
    var label: String
    var people: [Person] = []
}

// MARK: - Network

/// Whether the device is online, for "Waiting to sync".
@MainActor @Observable
final class HearthNetworkStatus {
    static let shared = HearthNetworkStatus()

    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        // Runs on the monitor's queue. It sets the shared instance rather than capturing self,
        // which Swift 6 won't allow across threads.
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in
                HearthNetworkStatus.shared.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.stephenwarren.hearth.network"))
    }
}

// MARK: - The card

struct HearthSyncCard: View {
    let app: HearthApp
    let snapshot: HearthSyncSnapshot
    /// What syncs, as the start of a sentence: "Your food log and goals".
    let summary: String
    var sharing: HearthSyncSharing? = nil
    /// Syncs now (send, then fetch) and returns when it's done. Never throws; report errors
    /// through the snapshot.
    let syncNow: () async -> Void

    @Environment(\.openURL) private var openURL
    @State private var isRunning = false

    private var info: HearthAppInfo { app.info }
    private var network: HearthNetworkStatus { .shared }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    private enum Phase: Equatable {
        case checking, off, syncing, failed, waiting, upToDate
    }

    private var phase: Phase {
        switch snapshot.account {
        case .checking: return .checking
        case .unavailable: return .off
        case .available: break
        }
        if snapshot.isSyncing || isRunning { return .syncing }
        if snapshot.errorMessage != nil { return .failed }
        if !network.isOnline || (snapshot.pendingChanges ?? 0) > 0 { return .waiting }
        return .upToDate
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(alignment: .leading, spacing: 16) {
            header
            details
            if let note {
                Text(note)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(noteTint.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
            }
            button
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, -4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: shape)
        .overlay(alignment: .top) {
            if phase == .syncing {
                HearthSyncBar(color: info.color)
                    .transition(.opacity)
            }
        }
        .clipShape(shape)
        .animation(.snappy, value: phase)
        .animation(.snappy, value: snapshot.pendingChanges)
        .sensoryFeedback(.success, trigger: snapshot.lastSynced)
        .sensoryFeedback(.error, trigger: snapshot.errorMessage) { _, new in new != nil }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(info.color, in: .rect(cornerRadius: 15, style: .continuous))
                badge
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(statusColor, in: .circle)
                    .padding(3)
                    .background(Color(.secondarySystemGroupedBackground), in: .circle)
                    .offset(x: 8, y: 8)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("iCloud Sync")
                    .font(.headline)
                HStack(spacing: 7) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(statusColor)
                        .symbolEffect(.pulse, options: .repeat(.continuous), isActive: phase == .syncing)
                    Text(statusText)
                        .contentTransition(.opacity)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusInk)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("iCloud Sync")
        .accessibilityValue(statusText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Details

    private var details: some View {
        VStack(spacing: 0) {
            row("Last synced") {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(lastSyncedText(now: context.date))
                        .contentTransition(.numericText())
                }
            }
            if let pending = snapshot.pendingChanges, pending > 0, phase != .off {
                Divider()
                row("Waiting to upload") {
                    Text(pending == 1 ? "1 change" : "\(pending) changes")
                        .contentTransition(.numericText())
                }
            }
            if let sharing, phase != .off {
                Divider()
                row("Shared with") {
                    HStack(spacing: 8) {
                        if !sharing.people.isEmpty {
                            HStack(spacing: -7) {
                                ForEach(sharing.people.prefix(3)) { person in
                                    Text(person.initial)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .background(hearthSyncColor(person.colorHex), in: .circle)
                                        .overlay(Circle().stroke(Color(.tertiarySystemGroupedBackground), lineWidth: 2))
                                }
                            }
                            .accessibilityHidden(true)
                        }
                        Text(sharing.label)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value()
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func lastSyncedText(now: Date) -> String {
        if phase == .syncing { return "Syncing now" }
        guard let date = snapshot.lastSynced else { return phase == .off ? "Never" : "Not yet" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Just now" }
        if elapsed < 60 * 60 { return date.formatted(.relative(presentation: .named)) }
        if Calendar.current.isDateInToday(date) { return "Today at \(date.formatted(date: .omitted, time: .shortened))" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday at \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Button

    private var button: some View {
        Button {
            act()
        } label: {
            Label(buttonTitle, systemImage: phase == .off ? "gearshape" : "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: phase == .syncing)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        // Steve's call: a light wash of the app's color with the icon and text in the app's color.
        // An approved exception to the app-color rules in AGENT.md; keep it.
        .tint(info.color)
        .disabled(phase == .syncing || phase == .checking)
        .accessibilityHint(phase == .off ? "Opens Settings" : "Syncs \(app.displayName) with iCloud now")
    }

    private var buttonTitle: String {
        switch phase {
        case .off: "Open Settings"
        case .syncing: "Syncing…"
        case .failed: "Try Again"
        case .checking, .waiting, .upToDate: "Sync Now"
        }
    }

    private func act() {
        if phase == .off {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        guard !isRunning else { return }
        isRunning = true
        Task {
            await syncNow()
            isRunning = false
        }
    }

    // MARK: Words and colors

    private var statusText: String {
        switch phase {
        case .checking: "Checking iCloud…"
        case .off: "iCloud is off"
        case .syncing: "Syncing…"
        case .failed: "Couldn’t sync"
        case .waiting: "Waiting to sync"
        case .upToDate: "Up to date"
        }
    }

    /// The status badge. Only the syncing arrows spin; every other symbol is its own view, so
    /// a spin can never carry over to the checkmark (or stop it mid-turn, tilted).
    @ViewBuilder private var badge: some View {
        if phase == .syncing {
            Image(systemName: badgeSymbol)
                .symbolEffect(.rotate, options: .repeat(.continuous))
                .transition(.opacity)
        } else {
            Image(systemName: badgeSymbol)
                .contentTransition(.symbolEffect(.replace))
                .transition(.opacity)
        }
    }

    private var badgeSymbol: String {
        switch phase {
        case .checking: "ellipsis"
        case .off: "xmark"
        case .syncing: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark"
        case .waiting: "clock"
        case .upToDate: "checkmark"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .checking, .off: Color(.systemGray)
        case .syncing: info.color
        case .failed: Color(.systemRed)
        case .waiting: Color(.systemOrange)
        case .upToDate: Color(.systemGreen)
        }
    }

    /// The status line's text: quiet when all is well, colored when it needs attention.
    private var statusInk: Color {
        switch phase {
        case .checking, .off, .upToDate: .secondary
        case .syncing: .secondary
        case .failed: Color(.systemRed)
        case .waiting: Color(.systemOrange)
        }
    }

    private var note: String? {
        switch phase {
        case .failed:
            return snapshot.errorMessage
        case .waiting where !network.isOnline:
            return "You’re offline. Your changes are saved on this \(device) and go up to iCloud as soon as you’re back online."
        case .off:
            if case .unavailable(let reason?) = snapshot.account { return reason }
            return "Sign in to iCloud, or turn on iCloud for \(app.displayName), to keep it on all your devices."
        default:
            return nil
        }
    }

    private var noteTint: Color {
        switch phase {
        case .failed: Color(.systemRed)
        case .waiting: Color(.systemOrange)
        default: Color(.systemGray)
        }
    }

    private var footnote: String {
        "\(summary) syncs on its own with your private iCloud\(sharing == nil ? "" : " and everyone it’s shared with"). Pull down on any screen to check for changes."
    }
}

// MARK: - Form rows

extension View {
    /// Shows a `HearthSyncCard` edge to edge in a Form or List row, so its own card is the row.
    func hearthSyncCardRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

// MARK: - Pieces

/// The thin bar that slides across the top of the card while syncing.
private struct HearthSyncBar: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(color)
                .frame(width: proxy.size.width * 0.4, height: 3)
                .offset(x: moving ? proxy.size.width : -proxy.size.width * 0.4)
        }
        .frame(height: 3)
        .background(color.opacity(0.15))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) {
                moving = true
            }
        }
        .accessibilityHidden(true)
    }
}

nonisolated private func hearthSyncColor(_ hex: UInt32) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255
    )
}

#Preview("iCloud Sync") {
    ScrollView {
        VStack(spacing: 20) {
            HearthSyncCard(app: .sated, snapshot: HearthSyncSnapshot(account: .available, lastSynced: .now.addingTimeInterval(-3_600 * 3)), summary: "Your food log and goals") {
                try? await Task.sleep(for: .seconds(2))
            }
            HearthSyncCard(
                app: .suffice,
                snapshot: HearthSyncSnapshot(account: .available, lastSynced: .now.addingTimeInterval(-600), pendingChanges: 3),
                summary: "Your budget",
                sharing: HearthSyncSharing(label: "Your partner", people: [.init(id: "a", initial: "S", colorHex: 0x1E9E6A), .init(id: "b", initial: "M", colorHex: 0x7B61FF)])
            ) {}
            HearthSyncCard(app: .hearken, snapshot: HearthSyncSnapshot(account: .available, errorMessage: "iCloud storage is full, so new changes can’t be saved there."), summary: "Your highlights, notes and progress") {}
            HearthSyncCard(app: .caloma, snapshot: HearthSyncSnapshot(account: .unavailable(nil)), summary: "The family’s chores, calendar and rewards") {}
        }
        .padding(16)
    }
    .background(Color(.systemGroupedBackground))
}
