import Foundation
import FoundationModels

// One definition per tool, used by both models:
//
// - Apple's on-device model gets it as a FoundationModels `Tool` whose arguments schema is built
//   at run time (DynamicGenerationSchema), so there's no hand-written @Generable struct per tool.
// - Claude gets the same name, description and parameters as JSON Schema, sent with each turn;
//   hearth-api checks the names against its allowlist (src/ember/tools.ts).
//
// Tools are grouped into domains. Each turn picks its domains first (EmberRouter) and offers only
// their tools: the small on-device model chooses well among a handful, badly among forty.

nonisolated enum EmberDomain: String, CaseIterable, Codable, Sendable {
    case money, meals, family, food, study, phone, places, general

    /// Said in the classifier's instructions.
    var meaning: String {
        switch self {
        case .money: "spending, budgets, bills, purchases, logging money spent (Suffice)"
        case .meals: "meal plans, dinner, recipes, the grocery list, allergies (BigTable)"
        case .family: "chores, approvals, the family calendar and events, allowance (Caloma)"
        case .food: "calories, protein, what someone ate, logging food (Sated)"
        case .study: "scripture reading and study plans (Hearken)"
        case .phone: "calling, texting or emailing someone, reminders, timers, alarms, the person's own calendar"
        case .places: "finding restaurants, stores, businesses or anything nearby, directions, hours and phone numbers of places"
        case .general: "general knowledge or small talk, nothing from the family's apps"
        }
    }
}

nonisolated struct EmberParam: Sendable {
    enum Kind: Sendable {
        case text
        case number
        case flag
        case choice([String])
    }

    var name: String
    var description: String
    var kind: Kind = .text
    var optional: Bool = false

    static func text(_ name: String, _ description: String, optional: Bool = false) -> EmberParam {
        EmberParam(name: name, description: description, kind: .text, optional: optional)
    }

    static func number(_ name: String, _ description: String, optional: Bool = false) -> EmberParam {
        EmberParam(name: name, description: description, kind: .number, optional: optional)
    }

    static func choice(_ name: String, _ description: String, _ values: [String], optional: Bool = false) -> EmberParam {
        EmberParam(name: name, description: description, kind: .choice(values), optional: optional)
    }
}

/// A tool's arguments, from either model.
nonisolated struct EmberArgs: Sendable {
    var values: [String: EmberJSON]

    func text(_ key: String) -> String {
        switch values[key] {
        case .string(let value): value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value): value.formatted()
        case .bool(let value): value ? "true" : "false"
        default: ""
        }
    }

    func number(_ key: String) -> Double? {
        switch values[key] {
        case .number(let value): value
        case .string(let value): Double(value.filter { $0.isNumber || $0 == "." || $0 == "-" })
        default: nil
        }
    }
}

struct EmberToolSpec {
    var name: String
    var description: String
    var domains: Set<EmberDomain>
    var params: [EmberParam] = []
    /// The Hearth app it reads, for the "From Suffice" line and the What Ember Knows switches.
    var app: HearthApp?
    var run: @MainActor @Sendable (EmberArgs) async -> String

    // MARK: For Claude

    /// `{ name, description, input_schema }`.
    var cloudDefinition: EmberJSON {
        var properties: [String: EmberJSON] = [:]
        for param in params {
            var schema: [String: EmberJSON] = ["description": .string(param.description)]
            switch param.kind {
            case .text: schema["type"] = .string("string")
            case .number: schema["type"] = .string("number")
            case .flag: schema["type"] = .string("boolean")
            case .choice(let values):
                schema["type"] = .string("string")
                schema["enum"] = .array(values.map { .string($0) })
            }
            properties[param.name] = .object(schema)
        }
        return .object([
            "name": .string(name),
            "description": .string(description),
            "input_schema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(params.filter { !$0.optional }.map { .string($0.name) }),
            ]),
        ])
    }

    // MARK: For Apple's on-device model

    func deviceTool() throws -> EmberDeviceTool {
        let properties = params.map { param -> DynamicGenerationSchema.Property in
            let schema: DynamicGenerationSchema = switch param.kind {
            case .text: DynamicGenerationSchema(type: String.self)
            case .number: DynamicGenerationSchema(type: Double.self)
            case .flag: DynamicGenerationSchema(type: Bool.self)
            case .choice(let values): DynamicGenerationSchema(name: "\(name)_\(param.name)", anyOf: values)
            }
            return DynamicGenerationSchema.Property(name: param.name, description: param.description, schema: schema, isOptional: param.optional)
        }
        let root = DynamicGenerationSchema(name: name, description: description, properties: properties)
        let schema = try GenerationSchema(root: root, dependencies: [])
        return EmberDeviceTool(name: name, description: description, parameters: schema, params: params, run: run)
    }
}

/// A tool as FoundationModels sees it. Arguments arrive as GeneratedContent and are read by name.
nonisolated struct EmberDeviceTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let params: [EmberParam]
    let run: @MainActor @Sendable (EmberArgs) async -> String

    func call(arguments: GeneratedContent) async throws -> String {
        var values: [String: EmberJSON] = [:]
        for param in params {
            switch param.kind {
            case .text, .choice:
                if let value = try? arguments.value(String.self, forProperty: param.name) { values[param.name] = .string(value) }
            case .number:
                if let value = try? arguments.value(Double.self, forProperty: param.name) { values[param.name] = .number(value) }
            case .flag:
                if let value = try? arguments.value(Bool.self, forProperty: param.name) { values[param.name] = .bool(value) }
            }
        }
        let args = EmberArgs(values: values)
        return await run(args)
    }
}
