import Foundation
import LLMProviderKit

/// An `LLMProvider` that never touches the network: it returns the scenario's
/// scripted responses in order (Nth call → Nth turn) and records every incoming
/// request so tests can assert on what the agent loop built.
///
/// **Single-use**: the internal cursor advances once per call and never resets.
/// Create a fresh `ReplayProvider` for each test run.
public final class ReplayProvider: LLMProvider, @unchecked Sendable {
    public static let name = "replay"
    public let configuration: LLMProviderConfiguration

    private let scenario: Scenario
    private let lock = NSLock()
    private var cursor = 0
    private var _capturedRequests: [LLMRequest] = []

    public init(scenario: Scenario) {
        self.scenario = scenario
        self.configuration = LLMProviderConfiguration(
            name: Self.name,
            baseURL: URL(string: "replay://local")!
        )
    }

    /// Requests seen so far, in call order. `capturedRequests[0]` is the first
    /// LLM call the loop made, `[1]` the second, etc.
    public var capturedRequests: [LLMRequest] {
        lock.lock(); defer { lock.unlock() }
        return _capturedRequests
    }

    private func nextResponse(for request: LLMRequest) throws -> LLMResponse {
        lock.lock(); defer { lock.unlock() }
        _capturedRequests.append(request)
        guard cursor < scenario.turns.count else {
            throw ReplayError.ranOutOfResponses(callIndex: cursor, scripted: scenario.turns.count)
        }
        let turn = scenario.turns[cursor]
        cursor += 1
        return LLMResponse(
            text: turn.text,
            reasoning: turn.reasoning,
            finishReason: turn.finishReason,
            usage: turn.usage,
            toolCalls: turn.toolCalls,
            request: request,
            providerName: Self.name
        )
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try nextResponse(for: request)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            do {
                let response = try nextResponse(for: request)
                if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                continuation.yield(.finish(reason: response.finishReason, usage: response.usage))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

public enum ReplayError: Error, CustomStringConvertible {
    case ranOutOfResponses(callIndex: Int, scripted: Int)

    public var description: String {
        switch self {
        case .ranOutOfResponses(let callIndex, let scripted):
            return "ReplayProvider ran out of scripted responses: the loop made LLM call #\(callIndex + 1) but the scenario only scripts \(scripted). Add more turns to the scenario."
        }
    }
}
