import Testing
import Foundation
import LLMProviderKit
import SwiftAgentKit
@testable import SwiftAgentKitReplay

struct ContextChurnGuardTests {
    struct UITool: AgentTool {
        let name = "sim_ui"
        let description = "snapshot UI"
        let parameters = ToolParameters(
            properties: ["bundle_id": ToolParameterProperty(type: "string", description: "app")],
            required: ["bundle_id"])
        // Returns a distinct marker per call so we can tell snapshots apart.
        final class Marker: @unchecked Sendable { var n = 0 }
        let counter = Marker()
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            counter.n += 1
            return .success(toolCallId: "", toolName: name,
                            result: "SNAP\(counter.n) " + String(repeating: "u", count: 500))
        }
    }

    @Test func latestStructuredReadStaysInlineOverBudget() async throws {
        // Three sim_ui snapshots of the same app, then a final answer.
        // At the 4th request (for the final answer), the history contains:
        //   SNAP1 exchange (fully completed, old) → will be externalized
        //   SNAP2 exchange (fully completed, middle) → protected as latest-per-target
        //   SNAP3 exchange (active) → kept inline
        // With a tiny inline budget, SNAP1 is externalized while SNAP2/SNAP3 stay.
        //
        // Loop detector: 3 identical sim_ui calls will trip a *nudge* (threshold 3).
        // We disable detection to avoid it—a nudge injects a user message that corrupts
        // activeExchangeStart's boundary detection, making it protect SNAP3 instead of
        // SNAP2, which breaks the test's sifting assertions.
        let ui = { LLMToolCall(id: UUID().uuidString, name: "sim_ui", arguments: "{\"bundle_id\":\"com.x\"}") }
        let scenario = Scenario(name: "ui-churn", turns: [
            ScriptedTurn(text: "", finishReason: .toolCalls, toolCalls: [ui()]),
            ScriptedTurn(text: "", finishReason: .toolCalls, toolCalls: [ui()]),
            ScriptedTurn(text: "", finishReason: .toolCalls, toolCalls: [ui()]),
            ScriptedTurn(text: "done", finishReason: .stop, toolCalls: []),
        ])
        let cm = ContextManager(
            inlineBudgetChars: 300,   // force sifting — two 500-char results blow the budget
            readToolNames: ["sim_ui"],
            readIdentityParams: ["sim_ui": "bundle_id"]
        )
        // Disable loop detection: 3 identical sim_ui calls would trip a nudge
        // (nudgeThreshold=3) which injects a user message that disrupts the active-
        // exchange boundary the ContextManager uses. With detection off the scenario
        // structure is clean and we can assert the full sifting behaviour.
        let run = ReplayRun(scenario: scenario, tools: [UITool()], maxTurns: 10,
                            contextManager: cm, loopDetection: nil)
        _ = try await run.run("drive the app")

        // The LAST request the loop built must carry the newest snapshots as tool
        // results and must NOT carry the oldest one's result as one: SNAP1 is
        // evicted, and its receipt (which may quote its first characters)
        // stands in its step's place as an assistant message.
        let last = try #require(run.capturedRequests.last)
        let toolText = last.messages
            .filter { $0.role == .tool }
            .map { $0.content }
            .joined(separator: "\n")
        #expect(toolText.contains("SNAP3"))    // active exchange kept inline
        #expect(toolText.contains("SNAP2"))    // newest completed read protected inline
        #expect(!toolText.contains("SNAP1"))   // oldest evicted
        #expect(last.messages.contains { $0.role == .assistant && $0.content.contains(ContextManager.receiptHeader) })
    }
}
