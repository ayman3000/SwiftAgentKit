//
//  ParallelSubAgentTests.swift
//  SwiftAgentKit
//
//  Several delegate_task calls in one reply run side by side, up to the
//  host's limit; a reply that mixes them with a tool that acts runs in order.
//

import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// Counts how many children are talking to the model at the same moment.
actor ConcurrencyMeter {
    private(set) var now = 0
    private(set) var peak = 0
    func enter() { now += 1; peak = max(peak, now) }
    func leave() { now -= 1 }
}

/// The parent asks for `calls` in one reply, then answers once the results
/// are back. Each child holds the model for a moment so overlaps show.
final class FanOutProvider: LLMProvider, @unchecked Sendable {
    static let name = "fan-out-mock"
    static let providerName = "fan-out-mock"
    let configuration = LLMProviderConfiguration(
        name: FanOutProvider.providerName, baseURL: URL(string: "inproc://x")!)

    let calls: [LLMToolCall]
    let meter: ConcurrencyMeter

    init(calls: [LLMToolCall], meter: ConcurrencyMeter) {
        self.calls = calls
        self.meter = meter
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let isChild = request.messages.contains {
            $0.role == .system && $0.content.contains("You are a sub-agent")
        }
        if isChild {
            await meter.enter()
            try await Task.sleep(nanoseconds: 150_000_000)
            await meter.leave()
            return LLMResponse(text: "child done", finishReason: .stop,
                               request: request, providerName: Self.providerName)
        }
        if request.messages.contains(where: { $0.role == .tool }) {
            return LLMResponse(text: "all done", finishReason: .stop,
                               request: request, providerName: Self.providerName)
        }
        return LLMResponse(text: "", finishReason: .toolCalls, toolCalls: calls,
                           request: request, providerName: Self.providerName)
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

private func delegateCall(_ n: Int) -> LLMToolCall {
    LLMToolCall(id: "d\(n)", name: "delegate_task",
                arguments: #"{"description": "task \#(n)", "prompt": "research topic \#(n)"}"#)
}

/// A tool that acts (not read-only): its presence keeps a batch in order.
private struct ActTool: AgentTool {
    let name = "act"
    let description = "Changes something."
    let parameters = ToolParameters.empty
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "acted")
    }
}

private func peakChildren(calls: [LLMToolCall], limit: Int) async throws -> Int {
    let meter = ConcurrencyMeter()
    let provider = FanOutProvider(calls: calls, meter: meter)
    let agent = Agent(config: AgentConfig(
        provider: provider, maxTurns: 6, tools: [ActTool()], enableSubAgents: true,
        maxSubAgentConcurrency: limit, parallelToolCalls: true))
    let answer = try await agent.run("do three things")
    #expect(answer.contains("all done"))
    return await meter.peak
}

@Test func severalSubAgentsInOneReplyRunTogether() async throws {
    let peak = try await peakChildren(calls: [delegateCall(1), delegateCall(2), delegateCall(3)], limit: 3)
    #expect(peak == 3)
}

@Test func theHostsLimitStillCapsThem() async throws {
    let peak = try await peakChildren(calls: [delegateCall(1), delegateCall(2), delegateCall(3)], limit: 2)
    #expect(peak == 2)
}

@Test func aReplyThatAlsoActsRunsInOrder() async throws {
    let act = LLMToolCall(id: "a1", name: "act", arguments: "{}")
    let peak = try await peakChildren(calls: [delegateCall(1), delegateCall(2), act], limit: 3)
    #expect(peak == 1)
}

@Test func onlyObservingToolsAndDelegationRunAlongsideOthers() async throws {
    #expect(ActTool().isConcurrencySafe == false)
    #expect(EchoTool().isConcurrencySafe == EchoTool().isReadOnly)
    let agent = Agent(config: AgentConfig(
        provider: PlainAnswerProvider(text: "x"), enableSubAgents: true))
    await agent.flushRegistrations()
    let delegate = try #require(await agent.tools.tool(named: "delegate_task"))
    #expect(delegate.isConcurrencySafe)
}

@Test func theToolTellsTheModelWhenToRunTasksTogether() async throws {
    let agent = Agent(config: AgentConfig(
        provider: PlainAnswerProvider(text: "x"), enableSubAgents: true))
    await agent.flushRegistrations()
    let text = try #require(await agent.tools.tool(named: "delegate_task")).description
    #expect(text.contains("in parallel"))
    #expect(text.contains("one after another"))   // the series case is spelled out too
}

/// Records which agent was running when it was called.
private final class WhoAmITool: AgentTool, @unchecked Sendable {
    let name = "whoami"
    let description = "Reports the caller."
    let parameters = ToolParameters.empty
    private let lock = NSLock()
    private var _seen: [UUID?] = []
    var seen: [UUID?] { lock.withLock { _seen } }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let id = FileStateRegistry.currentAgent
        lock.withLock { _seen.append(id) }
        return .success(toolCallId: "", toolName: name, result: "ok")
    }
}

@Test func eachAgentRunsUnderItsOwnIdentity() async throws {
    let who = WhoAmITool()
    let provider = SequenceProvider(steps: [
        .toolCall(name: "whoami", arguments: "{}"),                                          // parent
        .toolCall(name: "delegate_task", arguments: #"{"description": "d", "prompt": "p"}"#), // parent
        .toolCall(name: "whoami", arguments: "{}"),                                          // child
        .text("child answer"),                                                               // child
        .text("done"),                                                                       // parent
    ])
    let agent = Agent(config: AgentConfig(
        provider: provider, maxTurns: 6, tools: [who], enableSubAgents: true))
    _ = try await agent.run("go")
    let seen = who.seen
    #expect(seen.count == 2)
    #expect(seen.allSatisfy { $0 != nil })
    #expect(seen[0] != seen[1])
}
