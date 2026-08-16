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

    /// Drives the loop through the `beforeModel` intercept path (not the main
    /// ReAct path) to verify loop detection works on BOTH dispatch paths.
    ///
    /// The `beforeModel` callback always returns the same tool-call response,
    /// so the LLM is never actually called. The `ReplayProvider` is a dummy
    /// with no scripted turns — it will never be reached.
    @Test func beforeModelInterceptPathNudgesThenStops() async throws {
        // Dummy provider; the beforeModel callback intercepts every turn so
        // the provider is never invoked.
        let scenario = Scenario(name: "empty", turns: [])
        let provider = ReplayProvider(scenario: scenario)

        let config = AgentConfig(
            provider: provider,
            maxTurns: 20,
            tools: [NoopTool()]
        )
        // Keep default loop detection (.default nudges at 3, stops at 5).
        // config.loopDetection is already set to .default by AgentConfig.init.

        let agent = Agent(config: config)

        // beforeModel always returns the same tool-call response — simulating a
        // model that is stuck calling `spin` with no arguments every turn.
        var callbacks = AgentCallbacks()
        callbacks.beforeModel = { _, _ in
            AgentLLMResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "c", name: "spin", parameters: [:])],
                finishReason: .toolCalls,
                providerName: "test"
            )
        }
        try await agent.setCallbacks(callbacks)

        // Collect events in a thread-safe way (same pattern as ReplayRun).
        final class EventCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var _events: [AgentEvent] = []
            func append(_ event: AgentEvent) { lock.lock(); _events.append(event); lock.unlock() }
            var events: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        }
        let collector = EventCollector()
        let observer = agent.onEvent { event in collector.append(event) }
        defer { agent.removeObserver(observer) }

        await #expect(throws: AgentError.self) {
            try await agent.run("do something via beforeModel")
        }

        // Must have nudged at least once…
        #expect(collector.events.contains {
            if case .loopDetected(_, _, .nudged) = $0 { return true }; return false
        })
        // …and must have stopped via the loop detector.
        #expect(collector.events.contains {
            if case .loopDetected(_, _, .stopped) = $0 { return true }; return false
        })
    }
}
