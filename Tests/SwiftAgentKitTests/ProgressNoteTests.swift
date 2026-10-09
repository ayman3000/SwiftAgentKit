import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// The turn-budget note is for one call only and goes at the very end, as a
/// user message. In the system message it changed the prompt prefix (and on
/// Anthropic, without a ContextManager, it replaced the whole system prompt:
/// the last system message wins there).
struct ProgressNoteTests {
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

    @Test(arguments: [false, true])
    func theNoteIsTheLastMessageOfItsCallOnly(withContextManager: Bool) async throws {
        let provider = ScriptedProvider(turns: (1...3).map {
            [LLMToolCall(id: "e\($0)", name: "echo", arguments: #"{"n":\#($0)}"#)]
        } + [[]])
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE", maxTurns: 4,
                                              tools: [EchoTool()],
                                              contextManager: withContextManager ? ContextManager() : nil,
                                              loopDetection: nil, progressNudgeFractions: [0.5]))
        _ = try await agent.run("go")
        let requests = provider.captured
        #expect(requests.count == 4)
        // Turn 2 of 4 carries the note, as its very last message, from the user.
        let noted = requests[1].messages
        #expect(noted.last?.role == .user)
        #expect(noted.last?.content.hasPrefix("[Progress check] You have used 2 of 4 turns.") == true)
        for request in requests {
            let systems = request.messages.filter { $0.role == .system }
            #expect(systems.count == 1)
            #expect(systems.allSatisfy { !$0.content.contains("[Progress check]") })
        }
        for index in [0, 2, 3] {
            #expect(!requests[index].messages.contains { $0.content.contains("[Progress check]") })
        }
    }
}
