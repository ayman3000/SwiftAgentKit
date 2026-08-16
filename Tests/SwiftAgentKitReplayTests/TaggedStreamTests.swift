import Testing
import Foundation
import LLMProviderKit
import SwiftAgentKit
@testable import SwiftAgentKitReplay

struct TaggedStreamTests {
    struct NoopTool: AgentTool {
        let name = "step"; let description = "test"
        let parameters = ToolParameters(properties: [:], required: [])
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            .success(toolCallId: "", toolName: name, result: "did a step")
        }
    }
    private func collect(_ scenario: Scenario, tools: [any AgentTool]) async throws -> [AgentStreamEvent] {
        let provider = ReplayProvider(scenario: scenario)
        let agent = Agent(config: AgentConfig(provider: provider, maxTurns: 10, tools: tools))
        var events: [AgentStreamEvent] = []
        for try await ev in agent.runStreamingTagged("go") { events.append(ev) }
        return events
    }
    private func completed(_ events: [AgentStreamEvent]) -> [(String, Bool)] {
        events.compactMap { if case .turnCompleted(let t, let w) = $0 { return (t, w) }; return nil }
    }

    @Test func tagsToolTurnsThenFinalAnswer() async throws {
        let t1 = ScriptedTurn(text: "Let me do a step.", finishReason: .toolCalls,
                              toolCalls: [LLMToolCall(id: "c1", name: "step", arguments: "{}")])
        let t2 = ScriptedTurn(text: "Another step.", finishReason: .toolCalls,
                              toolCalls: [LLMToolCall(id: "c2", name: "step", arguments: "{}")])
        let ans = ScriptedTurn(text: "## Summary\nAll done.", finishReason: .stop, toolCalls: [])
        let c = completed(try await collect(Scenario(name: "t", turns: [t1, t2, ans]), tools: [NoopTool()]))
        #expect(c.count == 3)
        #expect(c[0] == ("Let me do a step.", true))
        #expect(c[1] == ("Another step.", true))
        #expect(c[2].1 == false && c[2].0.contains("All done"))
    }

    @Test func singleAnswerYieldsOneFinalTurn() async throws {
        let ans = ScriptedTurn(text: "just answering", finishReason: .stop, toolCalls: [])
        let c = completed(try await collect(Scenario(name: "s", turns: [ans]), tools: [NoopTool()]))
        #expect(c.count == 1 && c[0].1 == false)
    }

    @Test func afterAgentModifiedStillFiresFinal() async throws {
        // A registered afterAgent callback that returns a modified string must
        // still cause exactly one .turnCompleted(wasToolCallTurn:false) to be
        // yielded, and its text must be the MODIFIED text, not the original.
        let ans = ScriptedTurn(text: "original answer", finishReason: .stop, toolCalls: [])
        let scenario = Scenario(name: "afterAgent", turns: [ans])
        let provider = ReplayProvider(scenario: scenario)
        let agent = Agent(config: AgentConfig(provider: provider, maxTurns: 10, tools: [NoopTool()]))
        var afterAgentCallbacks = AgentCallbacks()
        afterAgentCallbacks.afterAgent = { text, _ in
            return "modified: \(text)"
        }
        try await agent.setCallbacks(afterAgentCallbacks)

        var events: [AgentStreamEvent] = []
        for try await ev in agent.runStreamingTagged("go") { events.append(ev) }

        let turnCompletedEvents = events.compactMap { ev -> (String, Bool)? in
            if case .turnCompleted(let t, let w) = ev { return (t, w) }
            return nil
        }
        #expect(turnCompletedEvents.count == 1)
        #expect(turnCompletedEvents[0].1 == false)
        #expect(turnCompletedEvents[0].0 == "modified: original answer")
    }

    @Test func blockedVerificationStillFiresFinal() async throws {
        // A blocked completion verdict must still cause exactly one
        // .turnCompleted(wasToolCallTurn:false) to be yielded.
        let ans = ScriptedTurn(text: "attempting answer", finishReason: .stop, toolCalls: [])
        let scenario = Scenario(name: "blockedVerification", turns: [ans])
        let provider = ReplayProvider(scenario: scenario)
        let agent = Agent(config: AgentConfig(provider: provider, maxTurns: 10, tools: [NoopTool()]))
        var blockedCallbacks = AgentCallbacks()
        blockedCallbacks.verifyCompletion = { _, _, _ in
            .blocked(reason: "not allowed")
        }
        try await agent.setCallbacks(blockedCallbacks)

        var events: [AgentStreamEvent] = []
        for try await ev in agent.runStreamingTagged("go") { events.append(ev) }

        let turnCompletedEvents = events.compactMap { ev -> (String, Bool)? in
            if case .turnCompleted(let t, let w) = ev { return (t, w) }
            return nil
        }
        #expect(turnCompletedEvents.count == 1)
        #expect(turnCompletedEvents[0].1 == false)
        #expect(turnCompletedEvents[0].0.contains("blocked: not allowed"))
    }
}
