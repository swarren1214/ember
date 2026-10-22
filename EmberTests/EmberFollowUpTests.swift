import Foundation
import Testing
@testable import Ember

// Earlier turns reach the model only for real follow-ups, so a new question isn't answered
// as if it were the last one.

@MainActor
struct EmberFollowUpTests {
    let last = EmberTurn(question: "How much did we spend this week?", answer: "$412 this week.", askedAt: .now)

    @Test func newQuestionsStandAlone() {
        #expect(!EmberBrain.isFollowUp("What's for dinner tonight?", after: last))
        #expect(!EmberBrain.isFollowUp("Set a timer for 10 minutes", after: last))
        #expect(!EmberBrain.isFollowUp("Did the kids finish their chores?", after: last))
        #expect(!EmberBrain.isFollowUp("What time is it", after: last))
    }

    @Test func followUpsCarryOn() {
        #expect(EmberBrain.isFollowUp("And last month?", after: last))
        #expect(EmberBrain.isFollowUp("What about groceries", after: last))
        #expect(EmberBrain.isFollowUp("Text her that", after: last))
        #expect(EmberBrain.isFollowUp("yes", after: last))
    }

    @Test func oldTurnsExpire() {
        let old = EmberTurn(question: "How much did we spend?", answer: "$412.", askedAt: .now.addingTimeInterval(-600))
        #expect(!EmberBrain.isFollowUp("And last month?", after: old))
        #expect(!EmberBrain.isFollowUp("And last month?", after: nil))
    }

    @Test func answeringEmbersQuestionCounts() {
        var asked = last
        asked.asksBack = true
        #expect(EmberBrain.isFollowUp("The one on Main Street", after: asked))
        #expect(EmberBrain.isFollowUp("Springville", after: asked))
    }
}
