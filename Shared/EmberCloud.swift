import Foundation

// Ember's call to Claude through hearth-api: POST /v1/ember/turn, streamed back as Server-Sent
// Events. Compiled into the iPhone and the Watch apps (a standalone Watch calls it directly).
//
// The device runs every tool: when Claude asks for one, the stream ends with `toolUse` events,
// the device runs them and calls the route again with the results appended. The server never
// sees Hearth data beyond what a tool returned for this turn, already de-identified.
//
// Plain HTTP (`URLSession.bytes`), no WebSockets: watchOS keeps low-level networking for
// audio-streaming apps.

/// A value in a tool's input, as JSON.
nonisolated enum EmberJSON: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([EmberJSON])
    case object([String: EmberJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([EmberJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: EmberJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }
}

/// One block of a message, in the shape the Messages API uses.
nonisolated struct EmberCloudBlock: Codable, Sendable {
    /// "text", "tool_use" or "tool_result".
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var input: [String: EmberJSON]?
    var toolUseID: String?
    var content: String?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content
        case toolUseID = "tool_use_id"
    }

    static func text(_ text: String) -> EmberCloudBlock {
        EmberCloudBlock(type: "text", text: text)
    }

    static func toolUse(id: String, name: String, input: [String: EmberJSON]) -> EmberCloudBlock {
        EmberCloudBlock(type: "tool_use", id: id, name: name, input: input)
    }

    static func toolResult(id: String, content: String) -> EmberCloudBlock {
        EmberCloudBlock(type: "tool_result", toolUseID: id, content: content)
    }
}

nonisolated struct EmberCloudMessage: Codable, Sendable {
    /// "user" or "assistant".
    var role: String
    var content: [EmberCloudBlock]
}

/// Everything one request carries. No account id, device id, name or location: the server
/// gets the account from the bearer token only to check the plan, and forwards none of it.
nonisolated struct EmberCloudRequest: Codable, Sendable {
    /// "quick" for ordinary questions, "plan" for planning across apps or days.
    var profile: String
    /// "iphone" or "watch".
    var client: String
    var locale: String
    var timeZone: String
    /// The device's local date and time, "Thursday, October 22, 2026, 5:40 PM".
    var now: String
    /// The household as tokens, roles and age bands.
    var roster: [EmberRosterEntry]
    var messages: [EmberCloudMessage]
    /// The tools the device will run this turn, by name. Each must be on the server's allowlist.
    var tools: [String]
    /// Their definitions ({ name, description, input_schema }), so the device and Claude agree on
    /// one description of each tool. The server checks every name against its allowlist and
    /// falls back to its own definition for a name it knows but wasn't sent.
    var toolDefs: [EmberJSON]? = nil
    /// Claude's web search, only for general-knowledge questions the device marked as such.
    var allowWebSearch: Bool
}

nonisolated enum EmberCloudEvent: Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: EmberJSON])
    case done(stopReason: String)
}

nonisolated enum EmberCloudError: LocalizedError, Sendable {
    case offline
    case notAllowed
    case needsPlan
    case rateLimited
    case refused
    case failed

    var errorDescription: String? {
        switch self {
        case .offline: "Ember needs a connection for that one."
        case .notAllowed: "Cloud help is turned off in What Ember Knows."
        case .needsPlan: "That one needs Ember Plus or Hearth+."
        case .rateLimited: "Ember’s had a lot of questions today. Try again in a little while."
        case .refused: "Ember kept that private and didn’t send it."
        case .failed: "Ember couldn’t answer just now. Try again in a moment."
        }
    }
}

nonisolated struct EmberCloudClient: Sendable {
    var baseURL: URL
    var session: URLSession = .shared

    /// One request to the route. Retry once with a fresh token on 401 at the call site.
    func turn(_ request: EmberCloudRequest, accessToken: String) -> AsyncThrowingStream<EmberCloudEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: baseURL.appending(path: "v1/ember/turn"), timeoutInterval: 30)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    urlRequest.httpBody = try JSONEncoder().encode(request)

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw EmberCloudError.failed }
                    switch http.statusCode {
                    case 200: break
                    case 401: throw URLError(.userAuthenticationRequired)
                    case 402: throw EmberCloudError.needsPlan
                    case 422: throw EmberCloudError.refused
                    case 429: throw EmberCloudError.rateLimited
                    default: throw EmberCloudError.failed
                    }

                    // `lines` drops blank lines, so each event is handled at its `data:` line.
                    // The server always sends `event:` then one `data:` line.
                    var event = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if event == "error" { throw Self.error(from: data) }
                            let parsed = Self.parse(event: event, data: data)
                            event = ""
                            guard let parsed else { continue }
                            continuation.yield(parsed)
                            if case .done = parsed { break }
                        }
                    }
                    continuation.finish()
                } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost].contains(error.code) {
                    continuation.finish(throwing: EmberCloudError.offline)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated struct TextEvent: Decodable { var text: String }
    private nonisolated struct ToolEvent: Decodable { var id: String; var name: String; var input: [String: EmberJSON] }
    private nonisolated struct DoneEvent: Decodable { var stopReason: String? }
    private nonisolated struct ErrorEvent: Decodable { var code: String? }

    /// The server's mid-stream failure: `{"code":"PRIVACY_GUARD"}`, `{"code":"UPSTREAM_FAILED"}`.
    static func error(from data: String) -> EmberCloudError {
        switch (try? JSONDecoder().decode(ErrorEvent.self, from: Data(data.utf8)))?.code {
        case "PRIVACY_GUARD": .refused
        case "RATE_LIMITED": .rateLimited
        default: .failed
        }
    }

    static func parse(event: String, data: String) -> EmberCloudEvent? {
        let bytes = Data(data.utf8)
        let decoder = JSONDecoder()
        switch event {
        case "text":
            return (try? decoder.decode(TextEvent.self, from: bytes)).map { .text($0.text) }
        case "tool_use":
            return (try? decoder.decode(ToolEvent.self, from: bytes)).map { .toolUse(id: $0.id, name: $0.name, input: $0.input) }
        case "done":
            return .done(stopReason: (try? decoder.decode(DoneEvent.self, from: bytes))?.stopReason ?? "end_turn")
        default:
            return nil
        }
    }
}

/// Splits streamed text into sentences as they finish, so the voice can start on the first one
/// while the rest is still arriving.
nonisolated struct EmberSentenceSplitter: Sendable {
    private var buffer = ""

    /// Finished sentences in what's arrived so far.
    mutating func feed(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let end = Self.sentenceEnd(in: buffer) {
            let sentence = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    /// Whatever's left at the end of the reply.
    mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// The index just after a sentence's closing punctuation, when it's followed by a space (so
    /// "$1.50" and "5:40" don't split).
    private static func sentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if ".!?".contains(character), next < text.endIndex, text[next].isWhitespace {
                return next
            }
            index = next
        }
        return nil
    }
}
