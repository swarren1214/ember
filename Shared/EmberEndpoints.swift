import Foundation

/// The Hearth services both Ember apps talk to (the same for every Hearth app).
nonisolated enum EmberEndpoints {
    static let apiBaseURL = URL(string: "https://api.hearthapps.com")!
    static let supabaseURL = URL(string: "https://kvhvsztvfpydhfpzicyy.supabase.co")!
    static let supabasePublishableKey = "sb_publishable_j0eyoaQiN3fogFINKooaDA_V0yjXkgY"
}
