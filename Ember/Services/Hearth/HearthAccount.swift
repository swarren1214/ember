// HearthAccount.swift — the Account section every Hearth app shows in Settings: Sign in with
// Apple when no one is signed in; who's signed in, their Hearth apps, the app's own account rows,
// Sign Out and Delete Account when someone is.
//
// Canonical copy: ~/Developer/hearthkit/HearthAccount.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthShared.swift and
// HearthApps.swift (for `HearthApp`, its colors, `HearthAppIcon` and `HearthMark`), and in Debug
// builds HearthPurchases.swift (for the Copy RevenueCat ID row).
//
// Using it
// - Each app passes who's signed in (nil when no one is), its own Sign in with Apple button (which
//   keeps the app's own nonce and API calls), and what Sign Out and Delete Account do. Those two
//   closures only start the action: the app shows its own native confirmation alert, as it does
//   today (BigTable's "type DELETE" stays BigTable's).
//
//       Section {
//           HearthAccountSection(app: .sated, profile: account.profile) {
//               SatedAppleSignInButton()              // the app's SignInWithAppleButton
//           } rows: {
//               NavigationLink { PersonalInfoView() } label: {
//                   HearthAccountRow("Personal Information", systemImage: "person.text.rectangle")
//               }
//           } onSignOut: {
//               confirmSignOut = true
//           } onDeleteAccount: {
//               confirmDelete = true
//           }
//           .hearthAccountSectionRow()   // in a Form or List; leave it off in a ScrollView
//       }
//
// - The section sizes and clips the button (a 52 pt capsule), so pass the bare
//   SignInWithAppleButton with its style for the color scheme (.white in dark, .black in light).
// - Signed in, the section starts its group with Add / Change Profile Photo and Remove Photo for
//   "me" in the household (the one photo every Hearth app shows), so apps don't add their own.
// - `rows` is optional and follows the photo rows; each row is separated by a hairline. Use
//   `HearthAccountRow` for the label.
// - Pass `onDeleteAccount` whenever the person is signed in to a Hearth account (it calls the API's
//   `DELETE /v1/me`, which deletes the account for every Hearth app). Leave it nil when there's no
//   server account (Caloma, or an anonymous session), and `onSignOut` nil where signing out isn't offered.

import PhotosUI
import SwiftUI
import UIKit

// MARK: - Who's signed in

nonisolated struct HearthAccountProfile: Equatable, Sendable {
    var name: String?
    var email: String?
    /// A short extra line, such as the household's name.
    var detail: String?
    /// A JPEG of the person. Without one (or `photoURL`), the section looks for a photo another
    /// Hearth app shared under the same name, then falls back to an initial.
    var photo: Data?
    /// A photo to download when there's no JPEG at hand (BigTable's avatar URL).
    var photoURL: URL?
    var method: String = "Signed in with Apple"

    init(name: String? = nil, email: String? = nil, detail: String? = nil, photo: Data? = nil, photoURL: URL? = nil, method: String = "Signed in with Apple") {
        self.name = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.email = email.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.detail = detail.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.photo = photo
        self.photoURL = photoURL
        self.method = method
    }
}

// MARK: - The section

/// Who's signed in, shown the same way in every Hearth app.
@MainActor
enum HearthAccountIdentity {
    /// Their household name, else what the app knows.
    static func name(_ profile: HearthAccountProfile) -> String? {
        let household = HearthHouseholdStore.shared.me?.trimmedName ?? ""
        return household.isEmpty ? profile.name : household
    }

    /// The Hearth account's email (what Sign in with Apple gave the account, which may be a
    /// private relay address), else what the app knows.
    static func email(_ profile: HearthAccountProfile) -> String? {
        let shared = HearthAccounts.session()?.email?.trimmingCharacters(in: .whitespaces) ?? ""
        return shared.isEmpty ? profile.email : shared
    }
}

struct HearthAccountSection<SignInButton: View, Rows: View>: View {
    let app: HearthApp
    /// Who's signed in; nil shows the Sign in with Apple pitch.
    let profile: HearthAccountProfile?
    /// What signing in does in this app, under the headline. Defaults to the Hearth-wide line.
    var pitch: String?
    let signInButton: SignInButton
    let rows: Rows
    var onSignOut: (() -> Void)?
    var onDeleteAccount: (() -> Void)?

    init(
        app: HearthApp,
        profile: HearthAccountProfile?,
        pitch: String? = nil,
        @ViewBuilder signInButton: () -> SignInButton,
        @ViewBuilder rows: () -> Rows,
        onSignOut: (() -> Void)? = nil,
        onDeleteAccount: (() -> Void)? = nil
    ) {
        self.app = app
        self.profile = profile
        self.pitch = pitch
        self.signInButton = signInButton()
        self.rows = rows()
        self.onSignOut = onSignOut
        self.onDeleteAccount = onDeleteAccount
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var installed: Set<HearthApp> = []
    @State private var photoItem: PhotosPickerItem?

    private var info: HearthAppInfo { app.info }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(alignment: .leading, spacing: 18) {
            if let profile {
                signedIn(profile)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                signedOut
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            #if DEBUG
            HearthRevenueCatIDRow()
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: shape)
        .clipShape(shape)
        .animation(.snappy, value: profile)
        .sensoryFeedback(.success, trigger: profile != nil) { old, new in !old && new }
        .task { installed = HearthInstalledApps.current(including: app) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { installed = HearthInstalledApps.current(including: app) }
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HearthMark()
                    .frame(width: 30, height: 26)
                    .frame(width: 52, height: 52)
                    .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 15, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hearth Account")
                        .font(.footnote.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text("Not signed in")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 8) {
                Text("One account for all your Hearth apps")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(pitch ?? "Sign in once and your Hearth apps know it’s you, so they can work together. Your data stays in your iCloud.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            appGrid(showsStatus: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Works with " + HearthApp.allCases.map(\.displayName).formatted(.list(type: .and)))

            VStack(spacing: 12) {
                signInButton
                    .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
                    .clipShape(Capsule())
                Text("You can hide your email from us. By continuing you agree to the [Terms](https://hearthapps.com/terms) and [Privacy Policy](https://hearthapps.com/privacy).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .tint(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Signed in

    private func signedIn(_ profile: HearthAccountProfile) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                HearthAccountAvatar(app: app, profile: profile, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(HearthAccountIdentity.name(profile) ?? "Your Hearth Account")
                        .font(.title3.bold())
                        .lineLimit(2)
                    if let email = HearthAccountIdentity.email(profile) {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Label {
                        Text(profile.method)
                    } icon: {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                    }
                    .labelStyle(HearthAccountTightLabel())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    if let detail = profile.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your Hearth apps")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text("\(installed.count) of \(HearthApp.allCases.count) on this \(device)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                appGrid(showsStatus: true)
            }

            Group(subviews: groupRows) { subviews in
                if !subviews.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(subviews) { subview in
                            if subview.id != subviews.first?.id {
                                Divider().padding(.leading, 14)
                            }
                            subview
                        }
                    }
                    .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
                }
            }

            if onSignOut != nil || onDeleteAccount != nil {
                VStack(spacing: 2) {
                    if let onSignOut {
                        Button(role: .destructive) {
                            onSignOut()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .tint(.red)
                    }
                    if let onDeleteAccount {
                        Button {
                            onDeleteAccount()
                        } label: {
                            Text("Delete Account…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Profile photo

    /// The photo rows, then the app's own rows, as one group.
    @ViewBuilder
    private var groupRows: some View {
        photoRows
        rows
    }

    /// Add / Change Profile Photo and Remove Photo, for "me" in the household: the one photo
    /// every Hearth app shows (HearthHouseholdStore). Hidden until the household has loaded.
    @ViewBuilder
    private var photoRows: some View {
        if let me = HearthHouseholdStore.shared.me {
            PhotosPicker(selection: $photoItem, matching: .images) {
                HearthAccountRow(me.photo == nil ? "Add Profile Photo" : "Change Profile Photo", systemImage: "camera", showsChevron: false)
            }
            .buttonStyle(.plain)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       HearthHouseholdStore.shared.setPhoto(data, for: me.id) {
                        HearthAccountPhotoRemoval.clear(for: me.id)
                    }
                    photoItem = nil
                }
            }
            if me.photo != nil {
                Button {
                    if HearthHouseholdStore.shared.setPhoto(nil, for: me.id) {
                        HearthAccountPhotoRemoval.mark(for: me.id)
                    }
                } label: {
                    HearthAccountRow("Remove Photo", systemImage: "trash", showsChevron: false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Apps

    private func appGrid(showsStatus: Bool) -> some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(HearthApp.allCases, id: \.self) { other in
                if showsStatus {
                    appTile(other)
                } else {
                    tileContent(other, status: nil, dimmed: false)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func appTile(_ other: HearthApp) -> some View {
        if other == app {
            tileContent(other, status: Text("This app").foregroundStyle(.secondary), dimmed: false)
                .accessibilityElement(children: .combine)
        } else if installed.contains(other) {
            Button {
                if let url = other.info.openURL { openURL(url) }
            } label: {
                tileContent(other, status: Text("Open").foregroundStyle(.secondary), dimmed: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(other.displayName)")
        } else {
            let onAppStore = other.info.isOnAppStore
            Button {
                openURL(other.info.getURL)
            } label: {
                tileContent(other, status: Text(onAppStore ? "Get" : "Beta").fontWeight(.semibold).foregroundStyle(Color.primary), dimmed: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(onAppStore ? "Get \(other.displayName) on the App Store" : "Join the \(other.displayName) beta")
        }
    }

    private func tileContent(_ other: HearthApp, status: Text?, dimmed: Bool) -> some View {
        VStack(spacing: 5) {
            HearthAppIcon(app: other, size: 48)
                .opacity(dimmed ? 0.5 : 1)
            Text(other.displayName)
                .font(.caption2)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let status {
                status.font(.caption2)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
}

extension HearthAccountSection where Rows == EmptyView {
    init(
        app: HearthApp,
        profile: HearthAccountProfile?,
        pitch: String? = nil,
        @ViewBuilder signInButton: () -> SignInButton,
        onSignOut: (() -> Void)? = nil,
        onDeleteAccount: (() -> Void)? = nil
    ) {
        self.init(app: app, profile: profile, pitch: pitch, signInButton: signInButton, rows: { EmptyView() }, onSignOut: onSignOut, onDeleteAccount: onDeleteAccount)
    }
}

// MARK: - Rows

/// A row inside the signed-in section's group: a title, an optional symbol and value, and a
/// chevron. Wrap it in a NavigationLink or Button with `.buttonStyle(.plain)`.
struct HearthAccountRow: View {
    let title: String
    var systemImage: String?
    var value: String?
    var showsChevron = true

    init(_ title: String, systemImage: String? = nil, value: String? = nil, showsChevron: Bool = true) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let value {
                Text(value).foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .contentShape(.rect)
    }
}

// MARK: - Avatar

/// The signed-in person's photo: the one set on them in the Hearth household when there is one,
/// otherwise the app's own photo, another Hearth app's photo of them, or their initial.
struct HearthAccountAvatar: View {
    let app: HearthApp
    let profile: HearthAccountProfile
    var size: CGFloat = 60

    /// "Me" in the household: every Hearth app shows this same photo.
    private var householdImage: UIImage? {
        guard let name = HearthHouseholdStore.shared.me?.photo else { return nil }
        return Hearth.photo(named: name).flatMap(UIImage.init(data:))
    }

    private var ownImage: UIImage? {
        profile.photo.flatMap(UIImage.init(data:))
    }

    /// Another Hearth app's photo of someone with the same name.
    private var sharedImage: UIImage? {
        guard let name = profile.name else { return nil }
        return Hearth.sharedPhoto(forName: name, excluding: app).flatMap(UIImage.init(data:))
    }

    /// Someone in the household: their household photo is the only one (or their initial).
    /// Without one, this app's own photo, then any other Hearth app's.
    private var isInHousehold: Bool { HearthHouseholdStore.shared.me != nil }

    var body: some View {
        Group {
            if isInHousehold {
                if let image = householdImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            } else if let image = ownImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let url = profile.photoURL {
                AsyncImage(url: url) { phase in
                    if let downloaded = phase.image {
                        downloaded.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else if let image = sharedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
        .task(id: adoptionKey) { await adoptOlderPhoto() }
    }

    private var adoptionKey: String {
        "\(HearthHouseholdStore.shared.cloudLoaded)|\(HearthHouseholdStore.shared.me?.id ?? "")|\(profile.photo?.count ?? 0)|\(profile.photoURL?.absoluteString ?? "")"
    }

    /// Photos used to live in each app (Hearken's profile photo, BigTable's server avatar). The
    /// first one found for someone with no household photo becomes it, in every app; after that
    /// only choosing a new photo changes it.
    private func adoptOlderPhoto() async {
        let store = HearthHouseholdStore.shared
        guard let me = store.me, me.photo == nil, !HearthAccountPhotoRemoval.isMarked(for: me.id) else { return }
        if let data = profile.photo, store.adoptPhoto(data, for: me.id) { return }
        guard let url = profile.photoURL,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              UIImage(data: data) != nil else { return }
        store.adoptPhoto(data, for: me.id)
    }

    @ViewBuilder
    private var placeholder: some View {
        Group {
            if let initial = HearthAccountIdentity.name(profile)?.first {
                Text(String(initial).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(app.info.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(app.info.color.opacity(0.16))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(app.info.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(app.info.color.opacity(0.16))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// Remove Photo, remembered: an app's older photo (Hearken's, BigTable's server avatar) isn't
/// adopted again for someone who removed theirs. Kept in the Hearth app group, so every app on
/// this device respects it; choosing a new photo clears it.
nonisolated enum HearthAccountPhotoRemoval {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: Hearth.appGroupID) }
    private static func key(_ memberID: String) -> String { "hearth.photoRemoved.\(memberID)" }

    static func mark(for memberID: String) { defaults?.set(true, forKey: key(memberID)) }
    static func clear(for memberID: String) { defaults?.removeObject(forKey: key(memberID)) }
    static func isMarked(for memberID: String) -> Bool { defaults?.bool(forKey: key(memberID)) ?? false }
}

private struct HearthAccountTightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Form rows

extension View {
    /// Shows a `HearthAccountSection` edge to edge in a Form or List row, so its own card is the row.
    func hearthAccountSectionRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

// MARK: - Previews

#Preview("Account") {
    @Previewable @State var profile: HearthAccountProfile? = nil
    ScrollView {
        VStack(spacing: 20) {
            HearthAccountSection(app: .sated, profile: profile) {
                Button("Sign in with Apple") {
                    profile = HearthAccountProfile(name: "Steve", email: "steve@privaterelay.appleid.com")
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
            } rows: {
                Button {} label: { HearthAccountRow("Personal Information", systemImage: "person.text.rectangle") }
                    .buttonStyle(.plain)
                Button {} label: { HearthAccountRow("Sign-In & Security", systemImage: "lock") }
                    .buttonStyle(.plain)
                Button {} label: { HearthAccountRow("Export My Data", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.plain)
            } onSignOut: {
                profile = nil
            } onDeleteAccount: {}
        }
        .padding(16)
    }
    .background(Color(.systemGroupedBackground))
}
