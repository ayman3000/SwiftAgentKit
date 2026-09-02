import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// A provider whose stream interleaves separated reasoning with the answer,
/// the way Ollama's `thinking` field / OpenAI `reasoning_content` arrive.
private struct ReasoningStreamProvider: LLMProvider {
    static let name = "reasoning-stream"
    let configuration = LLMProviderConfiguration(
        name: name, baseURL: URL(string: "inprocess://reasoning")!, defaultModel: "mock"
    )

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "final", reasoning: "thought", finishReason: .stop, request: request, providerName: Self.name)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoning("let me "))
            continuation.yield(.reasoning("think"))
            continuation.yield(.text("fin"))
            continuation.yield(.text("al"))
            continuation.yield(.finish(reason: .stop, usage: nil))
            continuation.finish()
        }
    }
}

@Suite struct StreamedReasoningTests {
    @Test func reasoningDeltasAreTaggedAndKeptOutOfText() async throws {
        let agent = Agent(config: AgentConfig(provider: ReasoningStreamProvider(), maxTurns: 3))
        var reasoning = ""
        var text = ""
        var completed: [String] = []
        for try await ev in agent.runStreamingTagged("go") {
            switch ev {
            case .reasoningDelta(let r): reasoning += r
            case .delta(let t): text += t
            case .turnCompleted(let t, _): completed.append(t)
            }
        }
        #expect(reasoning == "let me think")
        #expect(text == "final")
        #expect(completed == ["final"])
    }

    @Test func plainRunStreamingIgnoresReasoning() async throws {
        let agent = Agent(config: AgentConfig(provider: ReasoningStreamProvider(), maxTurns: 3))
        var text = ""
        for try await chunk in agent.runStreaming("go") { text += chunk }
        #expect(text == "final")
    }
}
