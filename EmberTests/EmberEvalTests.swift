import Foundation
import FoundationModels
import Testing
@testable import Ember

// The evaluation set (implementation plan › Dependability 3): 150 real household questions,
// each with the area it's about and the tool that should answer it (EmberTests/Eval/
// ember-eval.json). Two checks:
//
// - Routing (always runs): the words of every question lead to its area, or to every area
//   when they don't settle it (then the model decides), never to the wrong area alone.
// - Tool choice (runs where Apple Intelligence is available): Apple's on-device model, given the
//   routed tools, calls the expected one first. Tools are stubs here; nothing is read or changed.
//   The bar for a release is 90% (the plan's 95% is for answers end to end, with Claude).

struct EvalCase: Decodable {
    var question: String
    var domain: String
    var tool: String
}

private final class BundleToken {}

enum EmberEval {
    static func cases() throws -> [EvalCase] {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: "ember-eval", withExtension: "json"))
        return try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: url))
    }
}

@MainActor
final class ToolSpy {
    var called: [String] = []
}

struct EmberEvalTests {
    @Test func hasOneHundredFiftyCases() throws {
        let cases = try EmberEval.cases()
        #expect(cases.count == 150)
        let names = Set(EmberToolbox.shared.allowedTools.map(\.name))
        for item in cases where !item.tool.isEmpty {
            #expect(names.contains(item.tool), "Unknown tool \(item.tool) in “\(item.question)”")
        }
    }

    @Test @MainActor func routingNeverPicksOnlyTheWrongArea() async throws {
        let cases = try EmberEval.cases()
        var specific = 0
        for item in cases {
            let decision = await EmberRouter.decide(item.question, onDevice: false)
            let expected = try #require(EmberDomain(rawValue: item.domain))
            #expect(decision.domains.contains(expected) || expected == .general,
                    "“\(item.question)” routed to \(decision.domains.map(\.rawValue).sorted()) instead of \(item.domain)")
            if decision.domains.count < EmberDomain.allCases.count { specific += 1 }
            // The tool it needs is on offer.
            if !item.tool.isEmpty {
                let offered = EmberToolbox.shared.tools(for: decision.domains).map(\.name)
                #expect(offered.contains(item.tool), "“\(item.question)” doesn't offer \(item.tool)")
            }
        }
        // Words alone settle most questions; the model only classifies the rest.
        #expect(Double(specific) / Double(cases.count) > 0.75)
    }

    @Test(.enabled(if: EmberBrain.onDeviceAvailable), .timeLimit(.minutes(30)))
    @MainActor func onDeviceModelPicksTheRightTool() async throws {
        let cases = try EmberEval.cases().filter { !$0.tool.isEmpty }
        var right = 0
        var misses: [String] = []
        for item in cases {
            let decision = await EmberRouter.decide(item.question, onDevice: true)
            let spy = ToolSpy()
            let tools: [any Tool] = EmberToolbox.shared.tools(for: decision.domains).compactMap { spec in
                var stub = spec
                stub.run = { _ in
                    spy.called.append(spec.name)
                    return "Done (evaluation stub)."
                }
                return try? stub.deviceTool()
            }
            let session = LanguageModelSession(tools: tools, instructions: EmberPrompt.instructions(recent: []))
            _ = try? await session.respond(to: item.question, options: GenerationOptions(temperature: 0))
            if spy.called.first == item.tool {
                right += 1
            } else {
                misses.append("\(item.question) → \(spy.called.first ?? "no tool") (expected \(item.tool))")
            }
        }
        let score = Double(right) / Double(cases.count)
        print("On-device tool choice: \(right)/\(cases.count) (\(Int(score * 100))%)\n" + misses.joined(separator: "\n"))
        #expect(score >= 0.9, "On-device tool choice \(Int(score * 100))% is under the 90% bar")
    }
}
