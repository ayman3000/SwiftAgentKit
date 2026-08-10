import Foundation
import LLMProviderKit

/// Wraps a real provider, forwards each call, and records the response as a
/// `ScriptedTurn` so a live session can be captured into a replayable `Scenario`.
/// Recording is a developer action; it is never part of CI.
public final class RecordingProvider: LLMProvider, @unchecked Sendable {
    public static let name = "recording"
    public let configuration: LLMProviderConfiguration

    private let base: any LLMProvider
    private let lock = NSLock()
    private var turns: [ScriptedTurn] = []

    public init(wrapping base: any LLMProvider, name: String = "recording") {
        self.base = base
        self.configuration = base.configuration
    }

    private func record(_ response: LLMResponse) {
        lock.lock(); defer { lock.unlock() }
        turns.append(ScriptedTurn(
            text: response.text,
            reasoning: response.reasoning,
            finishReason: response.finishReason,
            toolCalls: response.toolCalls,
            usage: response.usage))
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let response = try await base.complete(request)
        record(response)
        return response
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        // For v1, recording captures the non-streaming shape by accumulating
        // chunks into one ScriptedTurn.
        AsyncThrowingStream { continuation in
            let task = Task {
                var text = ""
                var toolCalls: [LLMToolCall] = []
                var finish: LLMFinishReason?
                var usage: LLMUsage?
                do {
                    for try await chunk in base.stream(request) {
                        switch chunk {
                        case .text(let t): text += t
                        case .toolCall(let c): toolCalls.append(c)
                        case .finish(let r, let u): finish = r; usage = u
                        case .error(let e): throw e
                        }
                        continuation.yield(chunk)
                    }
                    lock.withLock {
                        turns.append(ScriptedTurn(text: text, finishReason: finish, toolCalls: toolCalls, usage: usage))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The responses captured so far, as a replayable scenario.
    public func scenario(named: String) -> Scenario {
        lock.lock(); defer { lock.unlock() }
        return Scenario(name: named, turns: turns)
    }

    /// Write the captured scenario to a JSON file.
    public func writeScenario(named: String, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(scenario(named: named)).write(to: url)
    }
}
