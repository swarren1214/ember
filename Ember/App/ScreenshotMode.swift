import Foundation

/// Screenshot mode, for marketing screenshots (scripts/screenshots.sh).
///
/// Launched with `-Screenshots`, Ember shows the demo household (Daniel and Maya, as in the other
/// Hearth apps' screenshots) with a line from each Hearth app, never signs in, calls the API,
/// reads iCloud or asks for the microphone, and skips the splash and the Cloud Help choice.
/// Adding `-Screen <name>` opens one screen (see `Screen`). Debug builds only: Release ignores the
/// arguments, so none of this can be reached in the App Store build.
nonisolated enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The screens the script captures, by the name passed after `-Screen`, in order.
    nonisolated enum Screen: String, CaseIterable {
        /// The orb, the greeting and a line from each app.
        case home
        /// A conversation: dinner from BigTable, then the grocery budget from Suffice.
        case conversation
        /// The voice screen, listening.
        case voice
        /// The voice screen with Ember's answer and its card.
        case voiceanswer
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }()
}

#if DEBUG
/// Daniel and Maya's household and their day, made up for the screenshots.
@MainActor
enum ScreenshotSeed {
    static let daniel = "screenshots-daniel"

    /// Before anything starts: the household, then the screen's conversation.
    static func stage() {
        guard ScreenshotMode.isOn else { return }
        HearthHouseholdStore.shared.showForScreenshots(household, me: daniel)
        switch ScreenshotMode.screen ?? .home {
        case .home:
            break
        case .conversation:
            EmberBrain.shared.showForScreenshots([dinner, groceries])
        case .voice:
            EmberConversation.shared.showForScreenshots(phase: .listening, transcript: "Which bills are due this week", question: "")
            EmberLevelMeter.shared.value = 0.45
        case .voiceanswer:
            EmberBrain.shared.showForScreenshots([bills])
            EmberConversation.shared.showForScreenshots(phase: .speaking, transcript: "", question: bills.question, replyID: bills.id)
        }
    }

    static let household = HearthHouseholdSnapshot(
        info: HearthHouseholdInfo(name: "The Carters", organizerID: daniel),
        members: [
            HearthMember(id: daniel, name: "Daniel Carter", role: .parent, colorHex: 0x3B82F6, sortOrder: 0),
            HearthMember(id: "screenshots-maya", name: "Maya Carter", role: .parent, colorHex: 0xE0457B, sortOrder: 1),
            HearthMember(id: "screenshots-ava", name: "Ava", role: .kid, colorHex: 0x8B5CF6, birthday: "2014-04-12", sortOrder: 2),
            HearthMember(id: "screenshots-leo", name: "Leo", role: .kid, colorHex: 0x10B981, birthday: "2018-09-03", sortOrder: 3),
        ]
    )

    /// "Right now", in the order a day runs.
    static var glances: [EmberContext.Glance] {
        let four = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: .now) ?? .now
        return [
            .init(app: .caloma, value: "Ava’s piano lesson", detail: "At \(four.formatted(date: .omitted, time: .shortened))",
                  link: nil, question: "What’s on the family calendar today?"),
            .init(app: .bigtable, value: "Sheet-Pan Chicken Fajitas", detail: "Tonight’s dinner", link: nil, question: "What’s for dinner tonight?"),
            .init(app: .bigtable, value: "7 items", detail: "On the grocery list", link: nil, question: "What’s on the grocery list?"),
            .init(app: .suffice, value: "$1,240 left", detail: "Budgets this month", link: nil, question: "How are our budgets doing this month?"),
            .init(app: .sated, value: "860 calories left", detail: "Today", link: nil, question: "How many calories do I have left today?"),
            .init(app: .hearken, value: "Alma 32", detail: "To read today", link: nil, question: "What’s my reading today?"),
        ]
    }

    static let dinner = EmberTurn(
        question: "What’s for dinner tonight?",
        answer: "Sheet-pan chicken fajitas, from BigTable’s plan. It takes about 35 minutes and works for everyone, Leo’s no-spice included.",
        cards: [EmberCard(app: .bigtable, kind: .meal(title: "Sheet-Pan Chicken Fajitas", detail: "35 min · Serves 4", imageURL: nil, fitsEveryone: true))],
        sources: [.bigtable]
    )

    static let groceries = EmberTurn(
        question: "How much is left for groceries?",
        answer: "You have $214 left of your $600 grocery budget this month. Most of the $386 went to Costco.",
        cards: [EmberCard(app: .suffice, kind: .answer(EmberAnswer(
            facts: "", title: "Groceries", value: "$214 left", subtitle: "$386 of $600 spent this month",
            rows: [
                EmberRow(title: "Costco", value: "$212", detail: "2 trips"),
                EmberRow(title: "Smith’s", value: "$118", detail: "4 trips"),
                EmberRow(title: "Harmons", value: "$56", detail: "1 trip"),
            ],
            fraction: 386.0 / 600.0)))],
        sources: [.suffice]
    )

    static let bills = EmberTurn(
        question: "Which bills are due this week?",
        answer: "Two: Rocky Mountain Power on Thursday and the internet on Saturday. Both are on autopay, so there’s nothing to do.",
        cards: [EmberCard(app: .suffice, kind: .answer(EmberAnswer(
            facts: "", title: "Due this week", value: "$214", subtitle: "2 bills, both on autopay",
            rows: [
                EmberRow(title: "Rocky Mountain Power", value: "$128", detail: "Thursday", done: false),
                EmberRow(title: "Internet", value: "$86", detail: "Saturday", done: false),
            ])))],
        sources: [.suffice]
    )
}
#endif
