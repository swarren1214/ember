// HearthHouseholdInvites.swift — inviting someone to the household and joining one, the same
// in every Hearth app.
//
// Canonical copy: ~/Developer/hearthkit/HearthHouseholdInvites.swift. Don't edit the copies
// inside the apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs
// HearthHouseholdStore.swift, HearthHouseholdViews.swift, HearthPurchases.swift and each app's
// DesignSystem/SheetButtons.swift (`SheetCancelButton`, `SheetDoneButton`).
// Design: the "Household invites" page of the Hearth Ship canvas (the redesign rows).
//
// How it works
// - An invitation belongs to a person. It starts on their page (or Household › Invite
//   Someone): their Apple Account's email or phone, and their role. HearthKit adds that Apple
//   Account to the household's iCloud share, so only they can open the link, however it's
//   sent: Messages, Mail, a copied link, or the code they scan with their iPhone's Camera.
// - Everyone's page shows where they stand: joined, invited (Show Code, Resend, Cancel
//   Invitation), or not invited.
// - Opening the invitation shows one join sheet in every app (inline during onboarding): who
//   invited them, what they get, and the family's plan with Sign in with Apple. Joining makes
//   them the person the invitation was for: nothing to pick.

import CloudKit
import Contacts
import ContactsUI
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - Links that open the app they came from

/// Every Hearth app uses the same iCloud container, so iOS opens an iCloud invitation link in
/// whichever Hearth app it picks (Suffice, for an invitation sent from Caloma). Invitations go
/// out as `https://api.hearthapps.com/<app>/household/join?share=<the iCloud link>` instead:
/// the Hearth API's apple-app-site-association gives each app its own `/<app>/household/*`
/// paths, so iOS opens the app the invitation was made in. Without that app, the page there
/// passes them on to the iCloud invitation, which any Hearth app (or iCloud.com) opens.
///
/// Each app's `.onOpenURL` starts with `if HearthInviteLink.open(url) { return }`; its
/// `<app>://household/join?share=` form works the same way.
enum HearthInviteLink {
    static let host = "api.hearthapps.com"

    static func url(for share: URL, from app: HearthApp) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(app.rawValue)/household/join"
        components.queryItems = [URLQueryItem(name: "share", value: share.absoluteString)]
        return components.url ?? share
    }

    /// The iCloud invitation inside a Hearth invitation link, or nil for any other link.
    static func shareURL(from url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path
        let isLink: Bool
        if components.scheme == "https" {
            isLink = components.host == host && path.hasSuffix("/household/join")
        } else {
            // caloma://household/join?share=…
            isLink = components.host == "household" && path == "/join"
        }
        guard isLink, let value = components.queryItems?.first(where: { $0.name == "share" })?.value,
              let share = URL(string: value), share.scheme == "https",
              let shareHost = share.host(), shareHost == "icloud.com" || shareHost.hasSuffix(".icloud.com") else { return nil }
        return share
    }

    /// For the app's `.onOpenURL`: true when `url` was a household invitation (it's opening).
    @MainActor @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let share = shareURL(from: url) else { return false }
        Task {
            // Opened from the link at launch: the store may not have started yet.
            for _ in 0..<50 where HearthHouseholdStore.shared.cloudContainer == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await HearthHouseholdStore.shared.openInvitation(share)
        }
        return true
    }
}

// MARK: - Status

extension HearthHouseholdStore {
    /// A short line for someone's row in Household, for the organizer: Joined, Invited or Not
    /// Invited. Nil where it says nothing useful (you, the organizer, a member's own view, kids
    /// no one has invited).
    func inviteLine(_ member: HearthMember) -> String? {
        guard !isMember, member.id != me?.id, member.id != info?.organizerID else { return nil }
        switch inviteStatus(member) {
        case .joined: return "Joined"
        case .invited: return "Invited"
        case .notInvited: return member.role == .kid ? nil : "Not Invited"
        }
    }
}

// MARK: - On someone's page

/// The "On their own iPhone" part of someone's page, for the organizer: invite them, or show
/// their code again, resend, or cancel.
struct HearthPersonInviteSection: View {
    var member: HearthMember
    var accent: Color
    @State private var store = HearthHouseholdStore.shared
    @State private var inviting = false
    @State private var showsCode = false
    @State private var confirmsCancel = false

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        // One Group carries the sheets, so they stay up when the status changes under them
        // (creating the invitation makes it Invited).
        Group {
            if store.canInvite, member.id != store.info?.organizerID, member.id != store.me?.id {
                switch store.inviteStatus(member) {
                case .joined:
                    EmptyView()
                case .notInvited:
                    notInvited
                case .invited(let at):
                    invited(at)
                }
            }
        }
        .sheet(isPresented: $inviting) {
            HearthInviteSheet(member: member, accent: accent)
        }
        .sheet(isPresented: $showsCode) {
            NavigationStack {
                ScrollView {
                    HearthInviteSendView(member: member, accent: accent)
                        .padding(20)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Invite \(member.firstName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        SheetDoneButton { showsCode = false }
                    }
                }
            }
            .tint(accent)
        }
        .alert("Cancel \(member.firstName)'s Invitation?", isPresented: $confirmsCancel) {
            Button("Cancel Invitation", role: .destructive) {
                Task { await store.cancelInvite(member.id) }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Their link and code stop working. You can invite them again any time.")
        }
    }

    private var notInvited: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On their own \(device)").font(.headline)
                        Text("Not invited yet").font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone")
                }
                .foregroundStyle(.primary)
                Text("Invite \(member.firstName), and they'll see the family in every Hearth app they use, as themselves. Your plan comes with it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { inviting = true } label: {
                    Text("Invite \(member.firstName)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(accent)
            }
            .padding(.vertical, 6)
        } footer: {
            if member.role == .kid {
                Text("Kids without their own Apple Account don't need an invitation.")
            }
        }
    }

    private func invited(_ at: Date?) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invited").font(.headline)
                    Text(invitedLine(at)).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "clock")
            }
            .foregroundStyle(.primary)
            if let url = store.invitationURL {
                Button { showsCode = true } label: {
                    Label("Show Code", systemImage: "qrcode")
                        .foregroundStyle(.primary)
                }
                ShareLink(item: url, subject: Text(HearthInviteSendView.subject(store)), message: Text(HearthInviteSendView.message(store, member: member))) {
                    Label("Resend", systemImage: "arrow.clockwise")
                        .foregroundStyle(.primary)
                }
            }
            Button(role: .destructive) { confirmsCancel = true } label: {
                Label("Cancel Invitation", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
            .disabled(store.isWorking)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let problem = store.problem { Text(problem).foregroundStyle(.red) }
                Text("Canceling makes their link and code stop working. Their details stay in the household.")
            }
        }
    }

    private func invitedLine(_ at: Date?) -> String {
        var parts: [String] = []
        if let contact = store.invitedContact(member) { parts.append(contact) }
        if let at { parts.append(at.formatted(.relative(presentation: .named))) }
        return parts.isEmpty ? "Waiting for them to join" : parts.joined(separator: " · ")
    }
}

// MARK: - Inviting

/// Inviting one person: who they are in the household (picked, or someone new), their Apple
/// Account, their role, then the invitation to send or show.
struct HearthInviteSheet: View {
    var accent: Color
    @State private var store = HearthHouseholdStore.shared
    @State private var memberID: String?
    @State private var newName = ""
    @State private var contact = ""
    @State private var role: HearthRole = .adult
    @State private var created = false
    @Environment(\.dismiss) private var dismiss

    /// `member`: who's being invited; nil asks first (someone already in the household, or
    /// someone new).
    init(member: HearthMember? = nil, accent: Color) {
        self.accent = accent
        _memberID = State(initialValue: member?.id)
        _role = State(initialValue: member?.role ?? .adult)
    }

    private var member: HearthMember? { store.member(memberID) }
    private var contactIsValid: Bool { HearthHouseholdStore.inviteKey(forContact: contact) != nil }

    var body: some View {
        NavigationStack {
            Group {
                if created, let member {
                    ScrollView {
                        HearthInviteSendView(member: member, accent: accent)
                            .padding(20)
                    }
                    .background(Color(.systemGroupedBackground))
                } else if let member {
                    form(member)
                } else {
                    picker
                }
            }
            .navigationTitle(member.map { "Invite \($0.firstName)" } ?? "Invite Someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if created {
                    ToolbarItem(placement: .confirmationAction) {
                        SheetDoneButton { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetCancelButton { dismiss() }
                    }
                }
            }
        }
        .tint(accent)
    }

    // Who

    /// Everyone not on their own device yet, and someone new.
    private var invitable: [HearthMember] {
        store.people.filter { $0.id != store.me?.id && $0.id != store.info?.organizerID && store.inviteStatus($0) != .joined }
    }

    private var picker: some View {
        List {
            if !invitable.isEmpty {
                Section("Who are you inviting?") {
                    ForEach(invitable) { person in
                        Button {
                            role = person.role
                            contact = store.invitedContact(person) ?? ""
                            memberID = person.id
                        } label: {
                            HStack(spacing: 12) {
                                HearthMemberAvatar(member: person, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.trimmedName).foregroundStyle(.primary)
                                    if let line = store.inviteLine(person) {
                                        Text(line).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            Section {
                TextField("Their name", text: $newName)
                    .textContentType(.name)
                    .submitLabel(.next)
                    .onSubmit(addNewPerson)
                Button("Continue", action: addNewPerson)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .tint(.primary)
            } header: {
                Text("Someone New")
            } footer: {
                Text("They're added to the household, then invited. Kids without their own Apple Account don't need an invitation; add them in Household instead.")
            }
        }
    }

    private func addNewPerson() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let color = HearthPalette.colors[store.people.count % HearthPalette.colors.count].hex
        let person = HearthMember(name: name, role: .adult, colorHex: color)
        store.save(person)
        role = .adult
        memberID = person.id
    }

    // Their account and role

    private func form(_ member: HearthMember) -> some View {
        List {
            Section {
                VStack(spacing: 8) {
                    HearthMemberAvatar(member: member, size: 72)
                    Text("Invite \(member.firstName) to \(store.info?.name ?? "your household")")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                HStack(spacing: 10) {
                    TextField("Email or phone number", text: $contact)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        HearthContactPicker.pick { picked in contact = picked }
                    } label: {
                        Image(systemName: "person.crop.square")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose from Contacts")
                }
            } header: {
                Text("Their Apple Account")
            } footer: {
                Text("The email or phone number they sign in to iCloud with. Only that Apple Account can open the invitation, however you send it.")
            }
            Section {
                Picker("Role", selection: $role) {
                    ForEach(HearthRole.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("\(member.firstName) joins as")
            } footer: {
                Text(Self.roleNote(role))
            }
            Section("What they get") {
                Label("\(store.info?.name ?? "The household") in every Hearth app, already set up as \(member.firstName).", systemImage: HearthHouseholdLabel.symbol)
                Label("Your plan, once they sign in with Apple.", systemImage: "star")
                Label("Their own notes and data stay theirs.", systemImage: "lock")
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            if let problem = store.problem {
                Section { Text(problem).foregroundStyle(.red).font(.footnote) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    if await store.invite(member.id, contact: contact, role: role) != nil { created = true }
                }
            } label: {
                HStack {
                    if store.isWorking { ProgressView().tint(.white) }
                    Text("Create Invitation")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(accent)
            .disabled(!contactIsValid || store.isWorking)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onAppear {
            if contact.isEmpty { contact = store.invitedContact(member) ?? "" }
        }
    }

    static func roleNote(_ role: HearthRole) -> String {
        switch role {
        case .parent: "Can add, edit and remove anyone, and invite people. Gets everything on your plan."
        case .adult: "Edits their own details, like a grandparent or an older kid. Gets the meal plan and AI on your plan."
        case .kid: "Sees the family; parents manage their details. No AI on your plan."
        }
    }
}

/// The invitation, ready: its code to scan with the iPhone's Camera, and sending or copying
/// its link.
struct HearthInviteSendView: View {
    var member: HearthMember
    var accent: Color
    @State private var store = HearthHouseholdStore.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("\(member.firstName)'s invitation is ready")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Send it, or let them scan this with their iPhone's Camera.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let url = store.invitationURL {
                VStack(spacing: 12) {
                    if let code = HearthQRCode.image(for: url) {
                        Image(uiImage: code)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .accessibilityLabel("Code for \(member.firstName)'s invitation")
                    }
                    if let contact = store.invitedContact(member) {
                        Text("Only \(contact) can open it")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(22)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))

                HStack(spacing: 12) {
                    ShareLink(item: url, subject: Text(Self.subject(store)), message: Text(Self.message(store, member: member))) {
                        Label("Send", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(accent)
                    Button {
                        UIPasteboard.general.url = url
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glass)
                    .tint(.primary)
                }
            }
            Text("You'll find it on \(member.firstName)'s page until they join: show the code again, resend it, or cancel it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    static func subject(_ store: HearthHouseholdStore) -> String {
        "Join \(store.info?.name ?? "our household")"
    }

    static func message(_ store: HearthHouseholdStore, member: HearthMember) -> String {
        "\(member.firstName), here's your invitation to \(store.info?.name ?? "our household") in the Hearth apps. Open it on your iPhone."
    }
}

/// A QR code for a link, sharp at any size.
enum HearthQRCode {
    static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Picks an email address or phone number from Contacts (no permission needed: the person
/// chooses in Apple's picker).
@MainActor
final class HearthContactPicker: NSObject, CNContactPickerDelegate {
    private static var current: HearthContactPicker?
    private var completion: ((String) -> Void)?

    static func pick(_ completion: @escaping (String) -> Void) {
        let helper = HearthContactPicker()
        helper.completion = completion
        current = helper
        let picker = CNContactPickerViewController()
        picker.delegate = helper
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey, CNContactPhoneNumbersKey]
        // Choosing a contact shows their addresses and numbers to pick one.
        picker.predicateForSelectionOfContact = NSPredicate(value: false)
        UIApplication.shared.hearthTopViewController?.present(picker, animated: true)
    }

    nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
        let value: String? = (contactProperty.value as? String) ?? (contactProperty.value as? CNPhoneNumber)?.stringValue
        MainActor.assumeIsolated {
            if let value { completion?(value) }
            Self.current = nil
        }
    }

    nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        MainActor.assumeIsolated { Self.current = nil }
    }
}

// MARK: - Joining

/// Whether a household screen (onboarding) is showing the join card itself, so the join sheet
/// doesn't show over it too.
@MainActor @Observable
final class HearthJoinPresentation {
    static let shared = HearthJoinPresentation()
    var inlineScreens = 0
    private init() {}
}

/// The one join screen: the invitation (who, what they get, the family's plan and Sign in
/// with Apple), then "You're in". In a sheet from `.hearthHouseholdInvitations()`, and inline
/// in onboarding.
struct HearthJoinView: View {
    var accent: Color
    /// Inline (onboarding): no Done button; the screen's own Continue moves on.
    var isInline = false
    /// Join was tapped (before the household arrives).
    var onJoin: () -> Void = {}
    /// Done, or Not Now.
    var onFinish: () -> Void = {}

    @State private var store = HearthHouseholdStore.shared
    @State private var purchases = HearthPurchases.shared
    @State private var tappedJoin = false
    /// Kept from the invitation, which is gone once joined.
    @State private var inviter = ""
    @State private var householdName = ""
    @State private var signedIn = HearthAccounts.session() != nil

    var body: some View {
        Group {
            if store.pendingInvite != nil {
                invitation
            } else if tappedJoin {
                if store.isMember && store.exists {
                    joined
                } else {
                    joining
                }
            }
        }
        .onAppear(perform: rememberInvitation)
        .onChange(of: store.pendingInvite?.share.recordID) { _, _ in rememberInvitation() }
        .onReceive(NotificationCenter.default.publisher(for: Hearth.didChange)) { _ in
            signedIn = HearthAccounts.session() != nil
        }
    }

    private func rememberInvitation() {
        guard store.pendingInvite != nil else { return }
        inviter = store.inviterName
        householdName = store.pendingHouseholdName ?? "their household"
    }

    private var firstName: String {
        inviter.split(separator: " ").first.map(String.init) ?? inviter
    }

    // The invitation

    private var invitation: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 64, height: 64)
                    .background(accent.opacity(0.14), in: .rect(cornerRadius: 18))
                    .accessibilityHidden(true)
                Text("\(inviter) invited you to \(householdName)")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(invitationLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                point("house", "The same people in every Hearth app on this \(UIDevice.current.localizedModel), with the family's recipes, chores and budget.")
                point("lock", "What you have now stays in your iCloud and comes back if you leave.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))

            plan(joined: false)

            if let problem = store.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 4) {
                Button {
                    tappedJoin = true
                    onJoin()
                    Task {
                        await store.acceptInvite()
                        // Didn't go through: the invitation stays, with what went wrong.
                        if store.pendingInvite != nil { tappedJoin = false }
                    }
                } label: {
                    Group {
                        if store.isWorking { ProgressView() } else { Text("Join") }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(accent)
                .disabled(store.isWorking)
                Button {
                    store.pendingInvite = nil
                    onFinish()
                } label: {
                    Text("Not Now")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .tint(.primary)
                .disabled(store.isWorking)
            }
        }
    }

    private var invitationLine: String {
        var parts: [String] = []
        if let contact = store.pendingInviteContact { parts.append("For \(contact)") }
        parts.append(store.pendingInviteCanEdit ? "You can make changes" : "You can see everything; parents make changes")
        return parts.joined(separator: " · ")
    }

    /// The family's plan, and Sign in with Apple to get it.
    @ViewBuilder
    private func plan(joined: Bool) -> some View {
        let hasIt = joined && purchases.membership?.source == .household
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hasIt ? "\(firstName)'s Hearth+ is on" : "\(firstName)'s plan comes with it")
                        .font(.subheadline.weight(.semibold))
                    Text(planLine(hasIt: hasIt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: hasIt ? "checkmark.seal.fill" : "star")
            }
            .foregroundStyle(.primary)
            if !signedIn, let signInButton = purchases.signInButton {
                signInButton()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(accent.opacity(0.4), lineWidth: 1.5))
    }

    private func planLine(hasIt: Bool) -> String {
        if hasIt { return "Plus features are unlocked in every Hearth app." }
        if signedIn { return "If they have Hearth+ or an app's Plus, it unlocks in every Hearth app once you've joined." }
        return "If they have Hearth+ or an app's Plus, sign in with Apple to unlock it in every Hearth app. You can also do it later in Profile."
    }

    // Joining and joined

    private var joining: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Bringing in \(householdName)…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var joined: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                if let me = store.me {
                    HearthMemberAvatar(member: me, size: 88)
                } else {
                    HStack(spacing: -12) {
                        ForEach(store.people.prefix(5)) { person in
                            HearthMemberAvatar(member: person, size: 48, ring: false)
                                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 3))
                        }
                    }
                }
                Text("You're in \(store.info?.name ?? householdName)")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(store.me.map { "Every Hearth app knows you as \($0.trimmedName)." } ?? (store.shareLoaded ? "One more thing: which one is you?" : "Finding you in the household…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if store.me == nil && !store.shareLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if store.me == nil {
                // An invitation from before they were invited by name: they pick.
                VStack(spacing: 0) {
                    ForEach(unclaimed) { person in
                        Button { store.claim(person.id) } label: {
                            HStack(spacing: 12) {
                                HearthMemberAvatar(member: person, size: 36)
                                Text(person.trimmedName).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if person.id != unclaimed.last?.id { Divider().padding(.leading, 64) }
                    }
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    check("The household, in every Hearth app on this \(UIDevice.current.localizedModel)")
                    check("Your photo, birthday, diet and allergies are already there")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
            }

            plan(joined: true)

            if !isInline {
                Button(action: onFinish) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(accent)
            }
        }
    }

    /// The people who could be them: not the organizer, not anyone already on their own device.
    private var unclaimed: [HearthMember] {
        store.people.filter { $0.appleUserID == nil && $0.id != store.info?.organizerID }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(.primary)
    }

    private func check(_ text: String) -> some View {
        Label {
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
        }
        .foregroundStyle(.primary)
    }
}

/// Waiting for an invitation, in onboarding: paste the link, scan the code with the Camera,
/// or open it from Messages (this screen moves on by itself).
struct HearthJoinWaitingView: View {
    var accent: Color
    var onBack: () -> Void
    @State private var store = HearthHouseholdStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join your family")
                .font(.title3.bold())
            Text("Use the invitation they made for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            PasteButton(payloadType: URL.self) { urls in
                guard let url = urls.first else { return }
                Task { @MainActor in await HearthHouseholdStore.shared.openInvitation(url) }
            }
            .buttonBorderShape(.capsule)
            .tint(accent)

            Label {
                Text("Or scan their code with your \(UIDevice.current.localizedModel)'s Camera, or open the invitation from Messages or Mail. This screen moves on by itself.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "camera.viewfinder")
            }
            .foregroundStyle(.primary)

            HStack(spacing: 10) {
                ProgressView()
                Text(store.isWorking ? "Opening the invitation…" : "Waiting for the invitation…")
                    .foregroundStyle(.secondary)
            }

            if let problem = store.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text("No invitation yet? Ask whoever set up your household to open your page in Household and tap Invite.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onBack) {
                Text("Back")
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .tint(.primary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }
}

extension View {
    /// Shows the join sheet when someone opens a household invitation. Put it on each app's
    /// root view, once.
    func hearthHouseholdInvitations(accent: Color = .accentColor) -> some View {
        modifier(HearthHouseholdInvitationSheet(accent: accent))
    }
}

private struct HearthHouseholdInvitationSheet: ViewModifier {
    var accent: Color
    @State private var store = HearthHouseholdStore.shared
    @State private var presentation = HearthJoinPresentation.shared
    @State private var presented = false

    /// Someone without a household gets the household step (onboarding), which shows the
    /// invitation itself; so does any screen already showing it.
    private var shows: Bool {
        store.pendingInvite != nil && store.exists && presentation.inlineScreens == 0
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $presented, onDismiss: {
                // Swiped away: the same as Not Now (unless onboarding took the invitation over).
                if store.pendingInvite != nil && !store.isWorking && presentation.inlineScreens == 0 {
                    store.pendingInvite = nil
                }
            }) {
                NavigationStack {
                    ScrollView {
                        HearthJoinView(accent: accent, onFinish: { presented = false })
                            .padding(20)
                            .frame(maxWidth: 520)
                            .frame(maxWidth: .infinity)
                    }
                    .navigationBarTitleDisplayMode(.inline)
                }
                .tint(accent)
                .interactiveDismissDisabled(store.isWorking)
            }
            .onChange(of: shows, initial: true) { _, shows in
                if shows { presented = true }
            }
            .onChange(of: presentation.inlineScreens) { _, count in
                // Onboarding took over: it shows the invitation inline.
                if count > 0 && store.pendingInvite != nil { presented = false }
            }
    }
}
