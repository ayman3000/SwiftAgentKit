import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// The level a user chooses is worth nothing unless it reaches the provider.
/// This closes the middle link: configuration → the request the agent builds.
/// The provider records what it was actually handed, rather than the test
/// asserting against a value it made up.
private final class RecordingProvider: LLMProvider, @unchecked Sendable {
    static let name = "recording"
    let configuration = LLMProviderConfiguration(
        name: name, baseURL: URL(string: "inprocess://recording")!, defaultModel: "mock")

    private let lock = NSLock()
    private var _seen: [LLMRequest] = []
    var seen: [LLMRequest] { lock.lock(); defer { lock.unlock() }; return _seen }

    private func record(_ request: LLMRequest) {
        lock.lock(); _seen.append(request); lock.unlock()
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        record(request)
        return LLMResponse(text: "done", finishReason: .stop, request: request, providerName: Self.name)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        record(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("done"))
            continuation.yield(.finish(reason: .stop, usage: nil))
            continuation.finish()
        }
    }
}

struct ReasoningEffortPassthroughTests {
    private func run(effort: LLMReasoningEffort?) async throws -> LLMRequest {
        let provider = RecordingProvider()
        let agent = Agent(config: AgentConfig(
            provider: provider, model: "mock", reasoningEffort: effort, maxTurns: 1))
        _ = try await agent.run("hello")
        let seen = provider.seen
        #expect(!seen.isEmpty, "the provider was never called")
        return try #require(seen.first)
    }

    @Test func theConfiguredLevelReachesTheRequest() async throws {
        for level in LLMReasoningEffort.ladder {
            let request = try await run(effort: level)
            #expect(request.reasoningEffort == level, "\(level.rawValue) did not reach the request")
        }
    }

    /// The default path: an agent nobody configured a level on must send none,
    /// so every existing caller keeps the provider's own behaviour.
    @Test func noConfiguredLevelSendsNone() async throws {
        let request = try await run(effort: nil)
        #expect(request.reasoningEffort == nil)
    }
}
