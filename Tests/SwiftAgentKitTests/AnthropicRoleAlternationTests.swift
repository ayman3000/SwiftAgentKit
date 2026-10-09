import Testing
import Foundation
import LLMProviderKit
import LLMProviderKitAnthropic
@testable import SwiftAgentKit

/// Regression for the Anthropic 400 flagged in the task-14 review: a
/// tool-result turn followed, on the very next call, by a STORED
/// "stop reasoning, act now" nudge AND a transient progress note used to put
/// three consecutive `user`-mapped entries on the wire (tool_result, the
/// stored nudge, the trailing note) — all three built as `.user` messages by
/// `Agent`, none of them merged. Anthropic rejects consecutive same-role
/// messages with HTTP 400.
///
/// LLMProviderKit 0.1.0-alpha.41 fixes this in the adapter itself
/// (`AnthropicProvider.mergingConsecutiveRoles` merges any run of one role,
/// not just tool-result blocks). This test builds the actual wire body via
/// `AnthropicProvider.prepareRequest` — not `ScriptedProvider` at the
/// `LLMMessage` level — so a future regression in either SwiftAgentKit's
/// message ordering or the adapter's merge would fail here.
struct AnthropicRoleAlternationTests {
    private struct EchoTool: AgentTool {
        let name = "echo"
        let description = "Echo."
        let parameters = ToolParameters(properties: [
            "n": ToolParameterProperty(type: "integer", description: "which"),
        ], required: ["n"])
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            .success(toolCallId: "", toolName: name, result: "echoed")
        }
    }

    /// Call 1: a tool call (produces a stored tool-result turn). Call 2:
    /// reasons past `maxReasoningSeconds` without acting — stored as the
    /// "stop reasoning, act now" nudge. Call 3: answers plainly, and is also
    /// the turn `nudgeTurns(maxTurns: 4, fractions: [0.75])` picks (turn 3),
    /// so its request carries both the stored nudge from call 2 AND the
    /// transient progress note — the exact collision the review flagged.
    private final class ToolThenStalledReasoningThenDoneProvider: LLMProvider, @unchecked Sendable {
        static let name = "tool-then-stalled-reasoning"
        let configuration = LLMProviderConfiguration(
            name: name, baseURL: URL(string: "inprocess://t")!, defaultModel: "mock")
        private let lock = NSLock()
        private var calls = 0
        private var requests: [LLMRequest] = []
        var captured: [LLMRequest] { lock.withLock { requests } }

        func complete(_ request: LLMRequest) async throws -> LLMResponse {
            LLMResponse(text: "done", finishReason: .stop, request: request, providerName: Self.name)
        }

        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
            let n: Int = lock.withLock { calls += 1; requests.append(request); return calls }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    switch n {
                    case 1:
                        continuation.yield(.toolCall(LLMToolCall(id: "e1", name: "echo", arguments: #"{"n":1}"#)))
                        continuation.yield(.finish(reason: .toolCalls, usage: nil))
                    case 2:
                        for _ in 0..<200 {   // stopped early by maxReasoningSeconds
                            if Task.isCancelled { break }
                            continuation.yield(.reasoning("hmm "))
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        continuation.yield(.finish(reason: .stop, usage: nil))
                    default:
                        continuation.yield(.text("done"))
                        continuation.yield(.finish(reason: .stop, usage: nil))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// The `messages` array of the wire body `AnthropicProvider.prepareRequest`
    /// would send for `request`.
    private static func anthropicMessages(_ request: LLMRequest) throws -> [[String: Any]] {
        let provider = AnthropicProvider(configuration: AnthropicProvider.anthropic(apiKey: "k", model: "claude-sonnet-4-6"))
        let body = try #require(try provider.prepareRequest(request, stream: false).httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return try #require(object?["messages"] as? [[String: Any]])
    }

    @Test func rolesAlternateWithTheNoteLastOnTheCollisionTurn() async throws {
        let provider = ToolThenStalledReasoningThenDoneProvider()
        let agent = Agent(config: AgentConfig(
            provider: provider, model: "mock", systemPrompt: "BASE", maxTurns: 4,
            tools: [EchoTool()], contextManager: nil, loopDetection: nil,
            progressNudgeFractions: [0.75], maxReasoningSeconds: 0.15))
        var text = ""
        for try await chunk in agent.runStreaming("go") { text += chunk }
        #expect(text == "done")

        let requests = provider.captured
        #expect(requests.count == 3)

        // Turn 3's request: tool_result (call 1), the stored stop-reasoning
        // nudge (call 2's "continue"), and the transient progress note — all
        // three built by Agent as `.user`-mapped content.
        let messages = try Self.anthropicMessages(requests[2])
        let roles = messages.compactMap { $0["role"] as? String }
        #expect(roles.count == messages.count, "every message dict carries a role")
        for (a, b) in zip(roles, roles.dropFirst()) {
            #expect(a != b, "consecutive same-role entries were not merged: \(roles)")
        }

        // The note is the last text block of the last (merged) user entry.
        let lastContent = try #require(messages.last?["content"] as? [[String: Any]])
        let lastBlock = try #require(lastContent.last)
        #expect(lastBlock["type"] as? String == "text")
        let noteText = try #require(lastBlock["text"] as? String)
        #expect(noteText == Agent.progressNudge(turn: 3, maxTurns: 4))
    }
}
