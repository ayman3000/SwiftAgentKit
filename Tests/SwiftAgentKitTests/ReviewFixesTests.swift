//
//  ReviewFixesTests.swift
//  SwiftAgentKit
//
//  Covers the contract fixes from the external code review:
//  - Sequential-by-default tool dispatch with parallel opt-in
//  - RepairRetryPolicy.isRepairable actually filtering repairable errors
//  - ToolActions.shouldStop / shouldRetry propagating back to the loop
//  - stream(_:) running the full agent lifecycle (tools included)
//  - run(_:trackGoal:) persisting goals to the goal store
//

import Foundation
import Testing
import LLMProviderKit
@testable import SwiftAgentKit

// MARK: - Shared test plumbing

/// Thread-safe recorder shared between tools and assertions.
private final class ConcurrencyProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxConcurrent = 0
    private(set) var executions: [String] = []

    func enter(_ label: String) {
        lock.lock()
        current += 1
        maxConcurrent = max(maxConcurrent, current)
        executions.append(label)
        lock.unlock()
    }

    func exit() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}

/// Sleeps briefly so overlapping executions are observable, and records concurrency.
private struct ConcurrencyProbeTool: AgentTool {
    let name = "probe"
    let description = "Test probe"
    let parameters = ToolParameters(
        properties: ["n": ToolParameterProperty(type: "string", description: "probe number")],
        required: ["n"]
    )
    let recorder: ConcurrencyProbeRecorder

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        recorder.enter(parameters["n"] as? String ?? "?")
        try? await Task.sleep(nanoseconds: 100_000_000)
        recorder.exit()
        return .success(toolCallId: "", toolName: name, result: "probed")
    }
}

/// In-process provider: first call issues the given tool calls, every call after
/// a tool result answers based on whether a repair nudge was seen.
private struct ScriptedToolProvider: LLMProvider {
    static let name = "scripted-tools"
    let configuration = LLMProviderConfiguration(
        name: name, baseURL: URL(string: "inprocess://scripted")!, defaultModel: "mock"
    )
    let toolCalls: [LLMToolCall]

    private func respond(to request: LLMRequest) -> LLMResponse {
        if request.messages.contains(where: { $0.role == .tool }) {
            let sawRepairNudge = request.messages.contains {
                $0.role == .user && $0.content.contains("failed with errors")
            }
            return LLMResponse(
                text: sawRepairNudge ? "repaired" : "done",
                finishReason: .stop, request: request, providerName: Self.name
            )
        }
        return LLMResponse(
            text: "calling tools",
            finishReason: .toolCalls, toolCalls: toolCalls,
            request: request, providerName: Self.name
        )
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        respond(to: request)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let response = respond(to: request)
        return AsyncThrowingStream { continuation in
            if !response.toolCalls.isEmpty {
                for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                continuation.yield(.finish(reason: .toolCalls, usage: nil))
            } else {
                continuation.yield(.text(response.text))
                continuation.yield(.finish(reason: .stop, usage: nil))
            }
            continuation.finish()
        }
    }
}

// MARK: - Tool dispatch policy

@Test func testToolCallsRunSequentiallyByDefault() async throws {
    let recorder = ConcurrencyProbeRecorder()
    let provider = ScriptedToolProvider(toolCalls: [
        LLMToolCall(name: "probe", arguments: "{\"n\":\"1\"}"),
        LLMToolCall(name: "probe", arguments: "{\"n\":\"2\"}"),
    ])
    let agent = Agent(config: AgentConfig(provider: provider, tools: [ConcurrencyProbeTool(recorder: recorder)]))

    _ = try await agent.run("go")

    #expect(recorder.executions.count == 2)
    #expect(recorder.maxConcurrent == 1)
}

@Test func testParallelToolCallsIsAnOptIn() async throws {
    let recorder = ConcurrencyProbeRecorder()
    let provider = ScriptedToolProvider(toolCalls: [
        LLMToolCall(name: "probe", arguments: "{\"n\":\"1\"}"),
        LLMToolCall(name: "probe", arguments: "{\"n\":\"2\"}"),
    ])
    var config = AgentConfig(provider: provider, tools: [ConcurrencyProbeTool(recorder: recorder)])
    config.parallelToolCalls = true
    let agent = Agent(config: config)

    _ = try await agent.run("go")

    #expect(recorder.executions.count == 2)
    #expect(recorder.maxConcurrent == 2)
}

// MARK: - RepairRetryPolicy.isRepairable wiring

private struct AlwaysFailTool: AgentTool {
    let name = "fail_tool"
    let description = "Always fails"
    let parameters = ToolParameters(properties: [:], required: [])

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .error(toolCallId: "", toolName: name, message: "simulated failure boom")
    }
}

@Test func testRepairRetrySkipsErrorsTheCustomPolicyMarksUnrepairable() async throws {
    let provider = ScriptedToolProvider(toolCalls: [LLMToolCall(name: "fail_tool", arguments: "{}")])
    let agent = Agent(config: AgentConfig(provider: provider, tools: [AlwaysFailTool()]))
    agent.repairRetryPolicy = RepairRetryPolicy(isRepairable: { _ in false })

    let answer = try await agent.run("go")

    // With nothing repairable, no nudge must be sent — the model's plain answer wins.
    #expect(answer == "done")
}

@Test func testRepairRetryStillTriggersForRepairableErrors() async throws {
    let provider = ScriptedToolProvider(toolCalls: [LLMToolCall(name: "fail_tool", arguments: "{}")])
    let agent = Agent(config: AgentConfig(provider: provider, tools: [AlwaysFailTool()]))

    let answer = try await agent.run("go")

    // Default policy treats the failure as repairable → nudge → model "repairs".
    #expect(answer == "repaired")
}

// MARK: - ToolActions propagation

private struct StopSignalTool: AgentTool {
    let name = "stop_tool"
    let description = "Signals the loop to stop"
    let parameters = ToolParameters(properties: [:], required: [])

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "work complete")
    }

    func execute(context: ToolContext) async throws -> AgentToolResult {
        context.actions.shouldStop = true
        return try await execute(parameters: context.parameters)
    }
}

@Test func testToolShouldStopEndsTheLoopAfterItsTurn() async throws {
    let provider = ScriptedToolProvider(toolCalls: [LLMToolCall(name: "stop_tool", arguments: "{}")])
    let agent = Agent(config: AgentConfig(provider: provider, tools: [StopSignalTool()]))

    let answer = try await agent.run("go")

    // The loop must NOT go back to the model after the stop signal —
    // the tool-calling turn's text is the final answer.
    #expect(answer == "calling tools")
}

private struct RetrySignalTool: AgentTool {
    let name = "retry_tool"
    let description = "Succeeds but requests a retry"
    let parameters = ToolParameters(properties: [:], required: [])

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "output was incomplete")
    }

    func execute(context: ToolContext) async throws -> AgentToolResult {
        context.actions.shouldRetry = true
        return try await execute(parameters: context.parameters)
    }
}

@Test func testToolShouldRetryTriggersRepairEvenWithoutAnError() async throws {
    let provider = ScriptedToolProvider(toolCalls: [LLMToolCall(name: "retry_tool", arguments: "{}")])
    let agent = Agent(config: AgentConfig(provider: provider, tools: [RetrySignalTool()]))

    let answer = try await agent.run("go")

    // The successful-but-flagged result must flow into repair-retry.
    #expect(answer == "repaired")
}

// MARK: - stream(_:) runs the full lifecycle

@Test func testStreamExecutesToolsLikeTheRealLoop() async throws {
    let recorder = ConcurrencyProbeRecorder()
    let provider = ScriptedToolProvider(toolCalls: [LLMToolCall(name: "probe", arguments: "{\"n\":\"1\"}")])
    let agent = Agent(config: AgentConfig(provider: provider, tools: [ConcurrencyProbeTool(recorder: recorder)]))

    var streamed = ""
    for try await chunk in agent.stream("go") { streamed += chunk }

    #expect(recorder.executions == ["1"])       // the tool actually ran
    #expect(streamed.contains("done"))          // and the post-tool answer streamed
}

// MARK: - run(_:trackGoal:)

private actor InMemoryGoalStore: AgentGoalStore {
    private var goals: [String: AgentGoal] = [:]

    func save(_ goal: AgentGoal) async throws { goals[goal.id] = goal }
    func load(id: String) async throws -> AgentGoal? { goals[id] }
    func loadAll() async throws -> [AgentGoal] { Array(goals.values) }
    func delete(id: String) async throws { goals[id] = nil }
}

private struct PlainAnswerOnlyProvider: LLMProvider {
    static let name = "plain-answer"
    let configuration = LLMProviderConfiguration(
        name: name, baseURL: URL(string: "inprocess://plain")!, defaultModel: "mock"
    )

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "the answer", finishReason: .stop, request: request, providerName: Self.name)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("the answer"))
            continuation.yield(.finish(reason: .stop, usage: nil))
            continuation.finish()
        }
    }
}

@Test func testRunTrackGoalPersistsCompletedGoal() async throws {
    let store = InMemoryGoalStore()
    let agent = Agent(config: AgentConfig(provider: PlainAnswerOnlyProvider()))
    agent.goalStore = store

    let answer = try await agent.run("summarize the project", trackGoal: true)

    let goals = try await store.loadAll()
    #expect(answer == "the answer")
    #expect(goals.count == 1)
    #expect(goals.first?.query == "summarize the project")
    #expect(goals.first?.status == .completed)
    #expect(goals.first?.summary == "the answer")
}
