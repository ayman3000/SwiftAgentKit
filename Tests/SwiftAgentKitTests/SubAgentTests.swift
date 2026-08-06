//
//  SubAgentTests.swift
//  SwiftAgentKit
//
//  Unit tests for sub-agent delegation: events, spawner inheritance rules,
//  DelegateTaskTool behavior — no network calls.
//

import Testing
import Foundation
import LLMProviderKit
import LLMProviderKitOllama
@testable import SwiftAgentKit

// MARK: - SubAgentSpawner inheritance rules

actor GateCounter { private(set) var n = 0; func bump() { n += 1 } }

@Test func testChildInheritsToolsMinusExcluded() async throws {
    let agent = Agent(config: AgentConfig(
        provider: PlainAnswerProvider(text: "x"),
        tools: [EchoTool(), DangerousTool()]))
    let spawner = SubAgentSpawner(parent: agent)
    let child = await spawner.makeChild()

    #expect(await child.tools.contains("echo"))
    #expect(await child.tools.contains("delete_everything"))
    #expect(await child.tools.contains("delegate_task") == false)
    #expect(await child.tools.contains("remember") == false)
    #expect(await child.tools.contains("learn_skill") == false)
}

@Test func testChildInheritsGateNotVerifier() async throws {
    let agent = Agent(config: AgentConfig(provider: PlainAnswerProvider(text: "x")))
    let counter = GateCounter()
    var callbacks = AgentCallbacks()
    callbacks.onToolConfirmation = { _, _ in await counter.bump(); return false }
    callbacks.verifyCompletion = { _, _, _ in .satisfied }
    agent.callbacks = callbacks

    let child = await SubAgentSpawner(parent: agent).makeChild()

    let gate = try #require(child.callbacks?.onToolConfirmation)
    let call = AgentToolCall(name: "delete_everything")
    let context = ToolContext(callId: call.id, toolName: call.name, parameters: [:], state: child.state)
    let approved = await gate(call, context)
    #expect(approved == false)
    #expect(await counter.n == 1)                       // parent's handler ran
    #expect(child.callbacks?.verifyCompletion == nil)   // verifier NOT inherited
}

@Test func testChildFreshConversationAndCappedTurns() async throws {
    let agent = Agent(config: AgentConfig(
        provider: PlainAnswerProvider(text: "x"),
        systemPrompt: "You are Naseem.",
        maxTurns: 40))
    agent.conversation.append(.user("parent history"))
    let child = await SubAgentSpawner(parent: agent).makeChild()

    #expect(child.config.maxTurns == 15)
    #expect(child.config.enableSubAgents == false)
    #expect(child.conversation.messages.filter { $0.role == .user }.isEmpty)
    // Child system prompt keeps the parent base and adds the sub-agent preamble.
    #expect(child.config.systemPrompt?.contains("You are Naseem.") == true)
    #expect(child.config.systemPrompt?.contains("sub-agent") == true)
}

@Test func testChildContextManagerSharesArtifactStore() async throws {
    let parentCM = ContextManager()
    let agent = Agent(config: AgentConfig(
        provider: PlainAnswerProvider(text: "x"),
        contextManager: parentCM))
    let child = await SubAgentSpawner(parent: agent).makeChild()

    let childCM = try #require(child.config.contextManager)
    #expect(childCM !== parentCM)                                   // fresh manager
    #expect(childCM.store === parentCM.store)                       // shared store
    #expect(await child.tools.contains("artifact_read"))
}

@Test func testCancelAllCancelsTrackedChildren() async throws {
    let agent = Agent(config: AgentConfig(provider: PlainAnswerProvider(text: "x")))
    let spawner = SubAgentSpawner(parent: agent)
    let child = await spawner.makeChild()
    spawner.track(UUID(), child)

    spawner.cancelAll()
    #expect(child.isCancelled)
}

// MARK: - Event cases

@Test func testSubAgentEventCasesExist() {
    let id = UUID()
    let started = AgentEvent.subAgentStarted(id: id, label: "research task")
    let wrapped = AgentEvent.subAgentEvent(id: id, event: .started(query: "inner"))
    let finished = AgentEvent.subAgentFinished(id: id, summary: "done")

    if case .subAgentStarted(let eid, let label) = started {
        #expect(eid == id)
        #expect(label == "research task")
    } else { Issue.record("expected subAgentStarted") }

    if case .subAgentEvent(let eid, let inner) = wrapped {
        #expect(eid == id)
        if case .started(let query) = inner { #expect(query == "inner") }
        else { Issue.record("expected wrapped .started") }
    } else { Issue.record("expected subAgentEvent") }

    if case .subAgentFinished(let eid, let summary) = finished {
        #expect(eid == id)
        #expect(summary == "done")
    } else { Issue.record("expected subAgentFinished") }
}

// MARK: - DelegateTaskTool registration & recursion guard

@Test func testEnableSubAgentsRegistersDelegateTool() async throws {
    let agent = Agent(config: AgentConfig(
        provider: PlainAnswerProvider(text: "x"),
        tools: [EchoTool()],
        enableSubAgents: true))
    // Registration goes through Agent.register (fire-and-forget); flush the
    // pending registration tasks so the registry check is deterministic.
    await agent.flushRegistrations()
    #expect(await agent.tools.contains("delegate_task"))

    let child = await (try #require(agent.subAgentSpawner)).makeChild()
    #expect(child.config.enableSubAgents == false)
    #expect(await child.tools.contains("delegate_task") == false)
    #expect(child.subAgentSpawner == nil)
}

@Test func testDelegateToolRequiresBothParameters() async throws {
    let agent = Agent(config: AgentConfig(
        provider: PlainAnswerProvider(text: "x"), enableSubAgents: true))
    let spawner = try #require(agent.subAgentSpawner)
    let tool = DelegateTaskTool(spawner: spawner, emit: { _ in })

    let missing = try await tool.execute(parameters: ["description": "only a label"])
    #expect(missing.isError)
    #expect(missing.result.contains("required"))
}

@Test func testParentCancelReachesLiveChildren() async throws {
    let agent = Agent(config: AgentConfig(
        provider: PlainAnswerProvider(text: "x"), enableSubAgents: true))
    let spawner = try #require(agent.subAgentSpawner)
    let child = await spawner.makeChild()
    spawner.track(UUID(), child)

    agent.cancel()
    #expect(child.isCancelled)
}

// MARK: - End-to-end (scripted provider)

/// Returns scripted responses in order. Parent and child share the instance;
/// calls are sequential (parent turn → child turns → parent turn), so a flat
/// script drives the whole nested run.
final class SequenceProvider: LLMProvider, @unchecked Sendable {
    enum Step { case text(String); case toolCall(name: String, arguments: String) }

    static let name = "sequence-mock"
    static let providerName = "sequence-mock"
    let configuration = LLMProviderConfiguration(
        name: SequenceProvider.providerName, baseURL: URL(string: "inproc://x")!)

    private let lock = NSLock()
    private var steps: [Step]

    init(steps: [Step]) { self.steps = steps }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let step: Step = lock.withLock {
            steps.isEmpty ? Step.text("(script exhausted)") : steps.removeFirst()
        }
        switch step {
        case .text(let text):
            return LLMResponse(text: text, finishReason: .stop,
                               request: request, providerName: Self.providerName)
        case .toolCall(let name, let arguments):
            return LLMResponse(
                text: "", finishReason: .toolCalls,
                toolCalls: [LLMToolCall(id: UUID().uuidString, name: name, arguments: arguments)],
                request: request, providerName: Self.providerName)
        }
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let response = try await self.complete(request)
                if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                continuation.yield(.finish(reason: .stop, usage: nil))
                continuation.finish()
            }
        }
    }
}

/// Thread-safe event recorder.
final class EventRecorder: AgentObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AgentEvent] = []
    var events: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func onEvent(_ event: AgentEvent) { lock.lock(); _events.append(event); lock.unlock() }
}

private let delegateArgs = #"{"description": "echo task", "prompt": "answer the sub-question"}"#

@Test func testDelegateTaskEndToEnd() async throws {
    let provider = SequenceProvider(steps: [
        .toolCall(name: "delegate_task", arguments: delegateArgs),  // parent turn 1
        .text("CHILD ANSWER"),                                      // child turn 1
        .text("final: composed from child")                         // parent turn 2
    ])
    let agent = Agent(config: AgentConfig(
        provider: provider, maxTurns: 6, tools: [EchoTool()], enableSubAgents: true))
    let recorder = EventRecorder()
    agent.addObserver(recorder)

    let answer = try await agent.run("do the big task")
    #expect(answer.contains("final: composed from child"))

    var startedLabel: String?
    var finishedSummary: String?
    var wrappedCount = 0
    for event in recorder.events {
        switch event {
        case .subAgentStarted(_, let label): startedLabel = label
        case .subAgentFinished(_, let summary): finishedSummary = summary
        case .subAgentEvent: wrappedCount += 1
        default: break
        }
    }
    #expect(startedLabel == "echo task")
    #expect(finishedSummary == "CHILD ANSWER")
    #expect(wrappedCount > 0)   // child lifecycle events were forwarded
}

@Test func testDelegateTaskEmptyAnswerIsToolError() async throws {
    let provider = SequenceProvider(steps: [
        .toolCall(name: "delegate_task", arguments: delegateArgs),  // parent turn 1
        .text(""),                                                  // child: empty answer (creates tool error)
        .text("first reply after tool error"),                      // parent turn 2 (no tool calls) — repair-retry sees the tool error and nudges
        .toolCall(name: "delegate_task", arguments: delegateArgs),  // parent turn 3 — retries after repair nudge
        .text("CHILD ANSWER AFTER RETRY"),                          // child: second attempt
        .text("recovered WITH the child")                           // parent turn 4 — final answer after retry succeeds
    ])
    let agent = Agent(config: AgentConfig(
        provider: provider, maxTurns: 6,
        tools: [EchoTool()], enableSubAgents: true))
    let recorder = EventRecorder()
    agent.addObserver(recorder)

    let answer = try await agent.run("do it")
    #expect(answer.contains("recovered"))

    let errorResults = recorder.events.compactMap { event -> AgentToolResult? in
        if case .toolExecutionFinished(let call, let result) = event,
           call.name == "delegate_task" { return result }
        return nil
    }
    #expect(errorResults.first?.isError == true)
    #expect(errorResults.first?.result.contains("no answer") == true)
}

// MARK: - Live integration (SAK_LIVE_TESTS=1, local Ollama with glm-5.2:cloud)

@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func liveDelegateTask() async throws {
    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "glm-5.2:cloud"))
    let agent = Agent(config: AgentConfig(
        provider: provider,
        model: "glm-5.2:cloud",
        systemPrompt: "You are a helpful assistant. Use delegate_task for the research step.",
        maxTurns: 8,
        tools: [EchoTool()],
        enableSubAgents: true))
    let recorder = EventRecorder()
    agent.addObserver(recorder)

    let answer = try await agent.run(
        "Delegate this to a sub-agent: use the echo tool to echo the word " +
        "'pineapple', then report what it returned. Then tell me the sub-agent's answer.")

    #expect(answer.lowercased().contains("pineapple"))
    let sawStart = recorder.events.contains { if case .subAgentStarted = $0 { return true }; return false }
    let sawFinish = recorder.events.contains { if case .subAgentFinished = $0 { return true }; return false }
    #expect(sawStart)
    #expect(sawFinish)
}
