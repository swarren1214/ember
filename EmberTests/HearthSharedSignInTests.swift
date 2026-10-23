import Foundation
import Testing
@testable import Ember

/// The shared sign-in must stay readable when another Hearth app wrote it, including one this
/// build doesn't know yet. (Ember's "updatedBy": "ember" used to make it unreadable here, which
/// read as "signed out in another app", so every app dropped its session.)
struct HearthSharedSignInTests {
    @Test func readsASessionWrittenByAnAppThisBuildDoesNotKnow() throws {
        let json = #"{"accessToken":"a","refreshToken":"r","expiresAt":1800000000,"userID":"u","email":"e@example.com","updatedBy":"someFutureApp"}"#
        let session = try JSONDecoder().decode(HearthSharedSession.self, from: Data(json.utf8))
        #expect(session.refreshToken == "r")
        #expect(session.userID == "u")
        #expect(session.updatedBy == nil)
    }

    @Test func readsAnAppleIDWrittenByAnAppThisBuildDoesNotKnow() throws {
        let json = #"{"userID":"apple","fullName":"Steve Warren","updatedBy":"someFutureApp"}"#
        let identity = try JSONDecoder().decode(HearthSharedAppleID.self, from: Data(json.utf8))
        #expect(identity.userID == "apple")
        #expect(identity.fullName == "Steve Warren")
    }

    @Test func roundTripsAKnownApp() throws {
        let session = HearthSharedSession(accessToken: "a", refreshToken: "r", expiresAt: 1, userID: "u", email: nil, updatedBy: .ember)
        let decoded = try JSONDecoder().decode(HearthSharedSession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
    }
}
