// 03-MCPIntegration.swift
// Connect to an MCP server, discover tools, bridge them into the agent.
//
// Prerequisites:
//   - npx installed (Node.js)
//   - Ollama running with a model that supports tool calling
//
// Run: swift run Runner 03

import Foundation
import SwiftAgentKit
import SwiftAgentKitMCP
import LLMProviderKit
import LLMProviderKitOllama

func mcpIntegration() async throws {
    // 1. Connect to an MCP filesystem server
    let mcp = MCPManager()
    let tmpDir = FileManager.default.temporaryDirectory.path

    print("Connecting to MCP filesystem server…")
    let info = try await mcp.connect(.stdio(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", tmpDir]
    ))
    print("Connected: \(info.name) v\(info.version)")

    // 2. Discover tools from the MCP server
    let tools = try await mcp.bridgedTools()
    print("Discovered \(tools.count) MCP tools:")
    for tool in tools {
        print("  - \(tool.name): \(tool.description.prefix(60))")
    }

    // 3. Create an agent and register all MCP tools
    let agent = Agent(config: AgentConfig(
        provider: OllamaProvider(configuration: OllamaProvider.local(model: "gemma4:latest")),
        systemPrompt: "You are a helpful assistant with filesystem tools. Use them to answer questions.",
        maxTurns: 8
    ))
    for tool in tools { agent.register(tool) }

    // 4. Monitor events
    agent.onEvent { event in
        if case .toolCallsReceived(let calls) = event {
            print("  → \(calls.map { $0.name })")
        }
        if case .toolExecutionFinished(let call, let result) = event {
            print("  ✓ \(call.name): \(String(result.result.prefix(80)))")
        }
    }

    // 5. Run the agent
    print("\nRunning agent…")
    let response = try await agent.run("List the files in the temp directory and summarize what you find.")
    print("\nAgent: \(response)")

    // 6. Clean up
    await mcp.disconnectAll()
    print("\nDisconnected.")
}