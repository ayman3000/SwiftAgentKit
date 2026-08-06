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
    // TODO(Task 3): #expect(child.config.enableSubAgents == false)
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
