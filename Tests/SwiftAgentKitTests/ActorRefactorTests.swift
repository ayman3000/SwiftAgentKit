import Foundation
import Testing
import LLMProviderKit
@testable import SwiftAgentKit

/// Provider that stalls until released — holds a run open so we can probe mid-run behavior.
private actor RunGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
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
    try? await Task.sleep(nanoseconds: 100_000_000)   // let the run reach the stalled provider

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
    try? await Task.sleep(nanoseconds: 100_000_000)
    await agent.setAutonomousMode(true)               // must not throw, must not deadlock
    await gate.release()
    _ = try await run.value
}
