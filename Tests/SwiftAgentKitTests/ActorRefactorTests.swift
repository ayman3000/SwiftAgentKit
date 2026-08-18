import Foundation
import Testing
import LLMProviderKit
@testable import SwiftAgentKit

/// Provider that stalls until released — holds a run open so we can probe mid-run behavior.
private actor RunGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasEntered = false

    func wait() async {
        hasEntered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { waiters.append($0) }
    }
    func awaitEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() { waiters.forEach { $0.resume() }; waiters.removeAll() }
}

private struct StallingProvider: LLMProvider {
    static let name = "stalling"
    let configuration = LLMProviderConfiguration(
        name: name, baseURL: URL(string: "inprocess://stall")!, defaultModel: "mock")
    let gate: RunGate

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        await gate.wait()
        return LLMResponse(text: "done", finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Test func settersWorkWhenIdle() async throws {
    let agent = Agent(config: AgentConfig(provider: StallingProvider(gate: RunGate())))
    try await agent.setRepairRetryPolicy(RepairRetryPolicy(maxAttempts: 1))
    let policy = await agent.repairRetryPolicy
    #expect(policy.maxAttempts == 1)
}

@Test func settersThrowDuringAnActiveRun() async throws {
    let gate = RunGate()
    let agent = Agent(config: AgentConfig(provider: StallingProvider(gate: gate)))

    let run = Task { try await agent.run("hold") }
    await gate.awaitEntered()   // deterministic: wait until the run has reached the stalled provider

    await #expect(throws: AgentError.self) {
        try await agent.setCallbacks(AgentCallbacks())
    }

    await gate.release()
    _ = try await run.value
    // Idle again — setter succeeds now.
    try await agent.setCallbacks(AgentCallbacks())
}

@Test func autonomousModeIsAllowedMidRun() async throws {
    let gate = RunGate()
    let agent = Agent(config: AgentConfig(provider: StallingProvider(gate: gate)))

    let run = Task { try await agent.run("hold") }
    await gate.awaitEntered()   // deterministic: wait until the run has reached the stalled provider
    await agent.setAutonomousMode(true)               // must not throw, must not deadlock
    await gate.release()
    _ = try await run.value
}

// MARK: - Retry classification

@Test func connectionRefusedIsNotRetryable() {
    // "Nothing is listening" (Ollama not launched) must fail fast — retrying
    // burns ~40 silent seconds against a server that isn't there.
    #expect(Agent.isRetryableLLMError(LLMError.networkError("Could not connect to the server.")) == false)
    #expect(Agent.isRetryableLLMError(LLMError.networkError("Connection refused")) == false)
}

@Test func transientNetworkErrorsStillRetry() {
    #expect(Agent.isRetryableLLMError(LLMError.networkError("The network connection was lost.")) == true)
    #expect(Agent.isRetryableLLMError(LLMError.networkError("The request timed out.")) == true)
    #expect(Agent.isRetryableLLMError(LLMError.httpError(503, nil)) == true)
    #expect(Agent.isRetryableLLMError(LLMError.httpError(400, nil)) == false)
}
