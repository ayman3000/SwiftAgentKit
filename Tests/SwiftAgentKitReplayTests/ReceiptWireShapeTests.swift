import Testing
import Foundation
import LLMProviderKit
import LLMProviderKitAnthropic
import LLMProviderKitGemini
import SwiftAgentKit

/// Receipts in place make an assistant message followed by another
/// assistant message the normal shape of a sifted request. The two strictest
/// wires must still pair every tool result with its own call, and Gemini
/// must never see a model turn right before a function-call turn.
struct ReceiptWireShapeTests {
    static func siftedMessages() async -> [LLMMessage] {
        let manager = ContextManager(summaryLength: 40, inlineBudgetChars: 0)
        var messages: [AgentMessage] = [.system("sys"), .user("do three things")]
        for i in 1...3 {
            messages.append(.assistant(content: "", toolCalls: [AgentToolCall(id: "c\(i)", name: "run_shell")]))
            messages.append(.tool(results: [.success(toolCallId: "c\(i)", toolName: "run_shell",
                                                     result: "output \(i) " + String(repeating: "x", count: 200))]))
        }
        // A fourth step still running: its call and result stay inline.
        messages.append(.assistant(content: "", toolCalls: [AgentToolCall(id: "c4", name: "run_shell")]))
        messages.append(.tool(results: [.success(toolCallId: "c4", toolName: "run_shell", result: "output 4")]))
        return await manager.modelMessages(messages) { $0 }
    }

    @Test func theSiftedShapeHasConsecutiveAssistantMessages() async {
        #expect(await Self.siftedMessages().map(\.role)
                == [.system, .user, .assistant, .assistant, .assistant, .assistant, .tool])
    }

    @Test func anthropicPairsEveryToolResultWithItsCall() async throws {
        let request = LLMRequest(model: "claude-sonnet-4-6", messages: await Self.siftedMessages())
        let provider = AnthropicProvider(configuration: AnthropicProvider.anthropic(apiKey: "k", model: "claude-sonnet-4-6"))
        let body = try #require(try provider.prepareRequest(request, stream: false).httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        var results = 0
        for (i, message) in messages.enumerated() {
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "tool_result" {
                results += 1
                let previous = i > 0 ? (messages[i - 1]["content"] as? [[String: Any]] ?? []) : []
                let ids = previous.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
                #expect(ids.contains(block["tool_use_id"] as? String ?? ""))
            }
        }
        #expect(results == 1)
        #expect(String(decoding: body, as: UTF8.self).contains("Tool calls in this step"))
    }

    @Test func geminiPairsEveryFunctionResponseWithItsCall() async throws {
        let request = LLMRequest(model: "gemini-2.0-flash", messages: await Self.siftedMessages())
        let provider = GeminiProvider(configuration: GeminiProvider.gemini(apiKey: "k", model: "gemini-2.0-flash"))
        let body = try #require(try provider.prepareRequest(request, stream: false).httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])
        var responses = 0
        for (i, content) in contents.enumerated() {
            for part in content["parts"] as? [[String: Any]] ?? [] where part["functionResponse"] != nil {
                responses += 1
                let previous = i > 0 ? (contents[i - 1]["parts"] as? [[String: Any]] ?? []) : []
                #expect(previous.contains { $0["functionCall"] != nil })
            }
        }
        #expect(responses == 1)
    }

    /// Gemini rejects a function-call turn that follows a model turn; since
    /// LLMProviderKit 0.1.0-alpha.40 a run of one role is one content.
    @Test func geminiNeverSendsTwoContentsOfOneRoleInARow() async throws {
        let request = LLMRequest(model: "gemini-2.0-flash", messages: await Self.siftedMessages())
        let provider = GeminiProvider(configuration: GeminiProvider.gemini(apiKey: "k", model: "gemini-2.0-flash"))
        let body = try #require(try provider.prepareRequest(request, stream: false).httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let roles = try #require(json["contents"] as? [[String: Any]]).compactMap { $0["role"] as? String }
        // user (task), model (three receipts + the active call), user (its result)
        #expect(roles == ["user", "model", "user"])
    }
}
