import Foundation

/// App-wide settings. The Hearth API, Supabase and RevenueCat values are the same for every
/// Hearth app (see Sated's AppConfig).
enum AppConfig {
    nonisolated static let apiBaseURL = EmberEndpoints.apiBaseURL
    nonisolated static let supabaseURL = EmberEndpoints.supabaseURL
    nonisolated static let supabasePublishableKey = EmberEndpoints.supabasePublishableKey

    /// RevenueCat's public Apple key for the one "Hearth" project (Ember Plus and Hearth+).
    nonisolated static let revenueCatAPIKey = "appl_bovDymdeWTsHzyTTNITRaqLGvro"
    nonisolated static var purchasesConfigured: Bool { revenueCatAPIKey != "REVENUECAT_PUBLIC_KEY" }

    static let supportEmailURL = URL(string: "mailto:support@hearthapps.com")!
    static let supportURL = URL(string: "https://hearthapps.com/support")!
    static let privacyURL = URL(string: "https://hearthapps.com/privacy")!
    static let termsURL = URL(string: "https://hearthapps.com/terms")!
}
