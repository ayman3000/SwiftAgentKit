import Testing
import Foundation
import LLMProviderKit
import SwiftAgentKit
@testable import SwiftAgentKitReplay

struct LoopDetectorReplayTests {
    /// A tool the scripted model "calls" every turn with identical args.
    struct NoopTool: AgentTool {
        let name = "spin"
        let description = "test tool"
        let parameters = ToolParameters(properties: [:], required: [])
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            .success(toolCallId: "", toolName: name, result: "still spinning")
        }
    }

    private func spinTurn() -> ScriptedTurn {
        ScriptedTurn(text: "", finishReason: .toolCalls,
                     toolCalls: [LLMToolCall(id: "c", name: "spin", arguments: "{}")])
    }

    @Test func repeatedIdenticalCallNudgesThenStops() async throws {
        // 8 identical spin turns is more than enough to cross nudge(3) then stop(5).
        let scenario = Scenario(name: "spin-loop", turns: Array(repeating: spinTurn(), count: 8))
        let run = ReplayRun(scenario: scenario, tools: [NoopTool()], maxTurns: 20)

        await #expect(throws: AgentError.self) {
            try await run.run("do something")
        }
        // Nudged before it stopped…
        #expect(run.events.contains {
            if case .loopDetected(_, _, .nudged) = $0 { return true }; return false
        })
        // …and stopped via the loop detector, NOT maxTurns (only ~5 turns used).
        #expect(run.events.contains {
            if case .loopDetected(_, _, .stopped) = $0 { return true }; return false
        })
    }
}
