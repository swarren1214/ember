import AuthenticationServices
import CryptoKit
import Foundation
import OSLog
import Security

// The Watch's own Hearth session, so a standalone Watch can call hearth-api with no iPhone in
// reach (implementation plan › Apple Watch › Auth). It never reuses the iPhone's refresh token:
// Supabase rotates refresh tokens, and one token spent on two devices signs one of them out.
//
// The person signs in with Apple on the Watch once; the session then refreshes itself over
// Wi-Fi or cellular. (Linking from a nearby iPhone with a one-time code is the next step:
// POST /v1/auth/device-link in hearth-api.)

actor WatchAccount {
    static let shared = WatchAccount()

    nonisolated struct Session: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
        }
    }

    nonisolated enum AccountError: Error {
        case signedOut
        case failed
    }

    private static let service = "com.stephenwarren.ember.watch.supabase"
    private var session: Session?
    private var renewal: Task<Session, Error>?
    private let log = Logger(subsystem: "com.stephenwarren.ember.watch", category: "account")

    init() {
        session = Self.load()
    }

    var isSignedIn: Bool { session != nil }

    /// A token good for at least a minute.
    func accessToken() async throws -> String {
        guard let current = session else { throw AccountError.signedOut }
        if current.expiresAt > Int(Date.now.timeIntervalSince1970) + 60 { return current.accessToken }
        if let renewal { return try await renewal.value.accessToken }
        let task = Task { try await refresh(current.refreshToken) }
        renewal = task
        defer { renewal = nil }
        return try await task.value.accessToken
    }

    /// Sign in with Apple, on the Watch.
    func signIn(identityToken: Data?, nonce: String) async throws {
        guard let identityToken, let token = String(data: identityToken, encoding: .utf8) else { throw AccountError.failed }
        let body = try JSONSerialization.data(withJSONObject: ["provider": "apple", "id_token": token, "nonce": nonce])
        store(try await auth(path: "auth/v1/token", query: "grant_type=id_token", body: body))
    }

    func signOut() {
        session = nil
        Self.delete()
    }

    private func refresh(_ refreshToken: String) async throws -> Session {
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        do {
            let refreshed = try await auth(path: "auth/v1/token", query: "grant_type=refresh_token", body: body)
            store(refreshed)
            return refreshed
        } catch AccountError.signedOut {
            signOut()
            throw AccountError.signedOut
        }
    }

    private func auth(path: String, query: String, body: Data) async throws -> Session {
        var components = URLComponents(url: EmberEndpoints.supabaseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.query = query
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(EmberEndpoints.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            log.error("Sign-in service HTTP \(status)")
            throw (400..<500).contains(status) ? AccountError.signedOut : AccountError.failed
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }

    private func store(_ new: Session) {
        session = new
        guard let data = try? JSONEncoder().encode(new) else { return }
        Self.delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "session",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func load() -> Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session",
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// A nonce for Sign in with Apple: the request gets its hash, Supabase gets the nonce.
    nonisolated static func prepare(_ request: ASAuthorizationAppleIDRequest) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        request.requestedScopes = []
        return nonce
    }
}
