// HearthHouseholdServer.swift — keeps the Hearth API's side of the household (who shares the
// organizer's plan, and what each person may do with it) in step with the Hearth household in
// iCloud, from every Hearth app that talks to the API.
//
// Canonical copy: ~/Developer/hearthkit/HearthHouseholdServer.swift. Don't edit the copies inside
// the apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthHouseholdStore.swift
// and HearthPurchases.swift (which starts this, with the app's API address and sign-in).
//
// How it works
// - Each person's Hearth account goes on their household person (`appIDs["account"]`), written
//   by their own app while they're signed in. Kids' apps can't write to the household, so kids
//   may have none; that's fine.
// - The organizer's app puts the server's join code in the household (encrypted in iCloud).
//   Everyone else's app redeems it with their household role, which joins the organizer's plan.
// - The organizer's app sends each linked person's role (PUT /v1/household/members), so what
//   they can do follows their role: parents everything, adults the meal plan and AI, kids neither.
// - Someone the organizer deletes or archives loses the membership (the organizer's app removes
//   them). Someone who leaves the household, or is taken off its share, leaves it from their own
//   app.
// - Apps without the Hearth API (no access token) skip all of this; the other apps do it.

import Foundation
import Observation
import OSLog
import UIKit

@MainActor
enum HearthHouseholdServer {
    /// The key in `HearthMember.appIDs` for the person's Hearth account id.
    static let accountKey = "account"

    /// Posted when this account joined or left the organizer's plan, so the app can reload.
    static let membershipChanged = Notification.Name("HearthHouseholdMembershipChanged")

    private static let log = Logger(subsystem: "com.stephenwarren.hearth", category: "household-server")
    private static var started = false
    private static var isRunning = false
    private static var runAgain = false
    private static var pending: Task<Void, Never>?
    private static var observers: [NSObjectProtocol] = []

    /// The code this device redeemed, and for which account: [account, code].
    private static let joinedKey = "hearth.household.server.joined"
    /// The code the organizer's account last got from the server, per account.
    private static let confirmedCodeKey = "hearth.household.server.code"
    /// A code that can't be redeemed (already in another household, or the code's gone).
    private static let skippedKey = "hearth.household.server.skipped"
    /// The roles last sent, on the organizer's devices, per organizer account and household:
    /// [account: role].
    private static let sentRolesKey = "hearth.household.server.roles"

    private static var defaults: UserDefaults { .standard }

    /// From `HearthPurchases.configure`. Runs again whenever the household or the sign-in
    /// changes, and on coming to the foreground.
    static func start() {
        guard !started else { return }
        started = true
        for name in [Hearth.didChange, UIApplication.willEnterForegroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { scheduleUpdate() }
            })
        }
        observeStore()
        scheduleUpdate()
    }

    /// iCloud answering and the share loading don't post `Hearth.didChange`: watch them too.
    private static func observeStore() {
        withObservationTracking {
            let household = HearthHouseholdStore.shared
            _ = household.cloudLoaded
            _ = household.share
            _ = household.isMember
        } onChange: {
            Task { @MainActor in
                scheduleUpdate()
                observeStore()
            }
        }
    }

    /// Soon, once changes settle. Never cancels an update already under way (its calls would be
    /// cut off mid-flight); that one runs again when it's done instead.
    static func scheduleUpdate() {
        if isRunning {
            runAgain = true
            return
        }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await update()
        }
    }

    /// Changes only what's out of date. Safe to call often.
    static func update() async {
        guard !isRunning else {
            runAgain = true
            return
        }
        isRunning = true
        defer {
            isRunning = false
            if runAgain {
                runAgain = false
                scheduleUpdate()
            }
        }
        guard HearthPurchases.shared.hasHearthAPI,
              let account = HearthAccounts.session()?.userID.lowercased() else { return }
        let household = HearthHouseholdStore.shared
        guard household.cloudLoaded else { return }

        await leaveIfGone(account: account)
        guard household.exists || household.isMember else { return }
        linkMe(account: account)
        if household.isMember {
            await join(account: account)
        } else if household.share != nil {
            await organize(account: account)
        }
    }

    // MARK: Everyone

    /// Puts this person's Hearth account on their household person.
    private static func linkMe(account: String) {
        let household = HearthHouseholdStore.shared
        guard var me = household.me, me.appIDs[accountKey] != account, household.canEdit(me) else { return }
        me.appIDs[accountKey] = account
        household.save(me)
    }

    // MARK: Members

    private static func join(account: String) async {
        let household = HearthHouseholdStore.shared
        guard let code = household.info?.joinCode else { return }
        if defaults.stringArray(forKey: joinedKey) == [account, code] { return }
        if defaults.string(forKey: skippedKey) == code { return }
        var body: [String: Any] = ["code": code]
        if let role = household.me?.role { body["role"] = role.rawValue }
        guard let result = await HearthPurchases.shared.callHearthAPI("POST", "v1/household/join", body: body, as: account) else { return }
        switch result.status {
        case 200:
            defaults.set([account, code], forKey: joinedKey)
            defaults.removeObject(forKey: skippedKey)
            log.notice("Joined the household's plan")
            await membershipDidChange()
        case 404, 409:
            // The code's gone, or this account is already in a household (this one, through an
            // older invitation, or another): don't keep trying the same code.
            defaults.set(code, forKey: skippedKey)
            log.notice("Couldn't join the household's plan (\(result.status, privacy: .public))")
        default:
            log.error("Joining the household's plan failed (\(result.status, privacy: .public))")
        }
    }

    /// This device joined the organizer's plan, and is no longer in their household: leave it.
    private static func leaveIfGone(account: String) async {
        guard let joined = defaults.stringArray(forKey: joinedKey), joined.count == 2 else { return }
        let household = HearthHouseholdStore.shared
        if household.isMember { return }
        // Joined as another account: that one's membership isn't this sign-in's to end.
        guard joined[0] == account else {
            defaults.removeObject(forKey: joinedKey)
            return
        }
        guard let result = await HearthPurchases.shared.callHearthAPI("DELETE", "v1/household/members/\(account)", as: account) else { return }
        if result.status == 200 || result.status == 404 {
            defaults.removeObject(forKey: joinedKey)
            log.notice("Left the household's plan")
            await membershipDidChange()
        } else {
            log.error("Leaving the household's plan failed (\(result.status, privacy: .public))")
        }
    }

    // MARK: The organizer

    private static func organize(account: String) async {
        let household = HearthHouseholdStore.shared
        // The code in the household must be this account's: one minted by older BigTable builds,
        // or while signed in as someone else, is checked (and replaced) once per account.
        let confirmedKey = "\(confirmedCodeKey).\(account)"
        if household.info?.joinCode == nil || household.info?.joinCode != defaults.string(forKey: confirmedKey) {
            guard let result = await HearthPurchases.shared.callHearthAPI("POST", "v1/household/join-code", body: [:], as: account) else { return }
            if result.status == 200,
               let reply = try? JSONDecoder().decode(JoinCode.self, from: result.data) {
                defaults.set(reply.code, forKey: confirmedKey)
                if household.info?.joinCode != reply.code { household.updateInfo(joinCode: reply.code) }
            } else {
                // 409: this account is still a member of someone else's household on the server.
                log.error("Couldn't get the household's join code (\(result.status, privacy: .public))")
                return
            }
        }

        var roles: [String: String] = [:]
        for person in household.people {
            // Blank: their link was cleared (Stop Sharing), so they're no longer on the plan.
            guard let linked = person.appIDs[accountKey]?.lowercased(), !linked.isEmpty, linked != account else { continue }
            roles[linked] = person.role.rawValue
        }
        guard let householdID = household.info?.id else { return }
        let sentKey = "\(sentRolesKey).\(account).\(householdID)"
        let sent = defaults.dictionary(forKey: sentKey) as? [String: String] ?? [:]

        // People deleted or archived since (or now signed in as someone else).
        for gone in sent.keys where roles[gone] == nil {
            guard let result = await HearthPurchases.shared.callHearthAPI("DELETE", "v1/household/members/\(gone)", as: account) else { return }
            guard result.status == 200 || result.status == 404 else {
                log.error("Removing someone from the household's plan failed (\(result.status, privacy: .public))")
                return
            }
        }

        guard roles != sent else { return }
        let members = roles.map { ["accountId": $0.key, "role": $0.value] }
        guard let result = await HearthPurchases.shared.callHearthAPI("PUT", "v1/household/members", body: ["members": members], as: account) else { return }
        if result.status == 200 {
            defaults.set(roles, forKey: sentKey)
        } else {
            log.error("Updating the household's plan failed (\(result.status, privacy: .public))")
        }
    }

    private nonisolated struct JoinCode: Decodable {
        var code: String
    }

    private static func membershipDidChange() async {
        await HearthPurchases.shared.householdMembershipChanged()
        NotificationCenter.default.post(name: membershipChanged, object: nil)
    }
}
