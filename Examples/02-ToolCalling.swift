// 02-ToolCalling.swift
// Define a Swift tool, register it with the agent, let the model call it.
//
// Run: swift run Runner 02

import Foundation
import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

// A simple tool the agent can call
struct CurrentTimeTool: AgentTool {
    let name = "current_time"
    let description = "Return the current date and time."
    let parameters = ToolParameters.empty

    func execute(context: ToolContext) async throws -> AgentToolResult {
        .success(toolCallId: context.callId, toolName: name,
                 result: Date().formatted(date: .complete, time: .standard))
    }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let ctx = ToolContext(callId: "", toolName: name, parameters: parameters,
                              state: AgentState(), turn: 0, query: "")
        return try await execute(context: ctx)
    }
}

func toolCalling() async throws {
    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "llama3.2"))
    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a helpful assistant. Use tools when needed.",
        maxTurns: 6,
        tools: [CurrentTimeTool()]
    ))

    let response = try await agent.run("What time is it? Use the tool.")
    print(response)
}