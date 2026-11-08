import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// The README's tools implement only `execute(context:)`. That must compile
/// and run — it didn't while `execute(parameters:)` was a bare requirement.
private struct ContextOnlyTool: AgentTool {
    let name = "context_only"
    let description = "Echoes its `text` argument and call id."
    let parameters = ToolParameters(
        properties: ["text": ToolParameterProperty(type: "string", description: "Text to echo")],
        required: ["text"]
    )

    func execute(context: ToolContext) async throws -> AgentToolResult {
        let text = context.parameters["text"] as? String ?? ""
        return .success(toolCallId: context.callId, toolName: name, result: "\(text) via \(context.toolName)")
    }
}

/// The older style — only `execute(parameters:)` — keeps working.
private struct ParametersOnlyTool: AgentTool {
    let name = "parameters_only"
    let description = "Echoes its `text` argument."
    let parameters = ToolParameters(
        properties: ["text": ToolParameterProperty(type: "string", description: "Text to echo")],
        required: ["text"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: parameters["text"] as? String ?? "")
    }
}

/// Neither entry point: a clear error result, not a hang or a crash.
private struct NoEntryPointTool: AgentTool {
    let name = "no_entry_point"
    let description = "Implements nothing."
    let parameters = ToolParameters.empty
}

private struct NoProvider: LLMProvider {
    static let name = "none"
    let configuration = LLMProviderConfiguration(name: "none", baseURL: URL(string: "http://localhost:1")!)
    func prepareRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        throw LLMError.unsupportedOperation("no model in this test")
    }
}

@Suite struct ToolEntryPointTests {
    private func agent(_ tools: [any AgentTool]) -> Agent {
        Agent(config: AgentConfig(provider: NoProvider(), tools: tools))
    }

    @Test func aToolWithOnlyContextExecuteRuns() async {
        let agent = agent([ContextOnlyTool()])
        let result = await agent.runToolCall(AgentToolCall(id: "c1", name: "context_only",
                                                           parameters: ["text": AnyCodable("hi")]))
        #expect(!result.isError)
        #expect(result.result == "hi via context_only")
        #expect(result.toolCallId == "c1")
    }

    @Test func aToolWithOnlyParametersExecuteStillRuns() async {
        let agent = agent([ParametersOnlyTool()])
        let result = await agent.runToolCall(AgentToolCall(id: "c2", name: "parameters_only",
                                                           parameters: ["text": AnyCodable("hello")]))
        #expect(!result.isError)
        #expect(result.result == "hello")
    }

    @Test func aToolWithNeitherEntryPointReportsAnError() async {
        let agent = agent([NoEntryPointTool()])
        let result = await agent.runToolCall(AgentToolCall(id: "c3", name: "no_entry_point"))
        #expect(result.isError)
        #expect(result.result.contains("execute(context:)"))
    }
}
