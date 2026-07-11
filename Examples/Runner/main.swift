import Foundation
import SwiftAgentKit
import SwiftAgentKitMCP
import LLMProviderKit
import LLMProviderKitOllama

// Dispatch to the requested example based on the first CLI argument.
let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "01"

// Include the example files — they define top-level functions.
// We inline them here so SPM doesn't need separate targets per example.

switch arg {
case "01":
    print("=== Example 01: Hello Agent ===\n")
    await runExample01()
case "02":
    print("=== Example 02: Tool Calling ===\n")
    await runExample02()
case "03":
    print("=== Example 03: MCP Integration ===\n")
    await runExample03()
default:
    print("Unknown example: \(arg)")
    print("Usage: swift run Runner [01|02|03]")
    exit(1)
}

// MARK: - Example 01: Hello Agent

func runExample01() async {
    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "llama3.2"))
    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a helpful Swift assistant. Answer concisely.",
        maxTurns: 1
    ))

    do {
        let answer = try await agent.run("Explain async/await in one sentence.")
        print(answer)
    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Example 02: Tool Calling

func runExample02() async {
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

    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "llama3.2"))
    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a helpful assistant. Use tools when needed.",
        maxTurns: 6,
        tools: [CurrentTimeTool()]
    ))

    do {
        let response = try await agent.run("What time is it? Use the tool.")
        print(response)
    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Example 03: MCP Integration

func runExample03() async {
    do {
        let mcp = MCPManager()
        let tmpDir = FileManager.default.temporaryDirectory.path

        print("Connecting to MCP filesystem server…")
        let info = try await mcp.connect(.stdio(
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", tmpDir]
        ))
        print("Connected: \(info.name) v\(info.version)")

        let tools = try await mcp.bridgedTools()
        print("Discovered \(tools.count) MCP tools:")
        for tool in tools {
            print("  - \(tool.name): \(tool.description.prefix(60))")
        }

        let agent = Agent(config: AgentConfig(
            provider: OllamaProvider(configuration: OllamaProvider.local(model: "gemma4:latest")),
            systemPrompt: "You are a helpful assistant with filesystem tools. Use them to answer questions.",
            maxTurns: 8
        ))
        for tool in tools { agent.register(tool) }

        agent.onEvent { event in
            if case .toolCallsReceived(let calls) = event {
                print("  → \(calls.map { $0.name })")
            }
            if case .toolExecutionFinished(let call, let result) = event {
                print("  ✓ \(call.name): \(String(result.result.prefix(80)))")
            }
        }

        print("\nRunning agent…")
        let response = try await agent.run("List the files in the temp directory and summarize what you find.")
        print("\nAgent: \(response)")

        await mcp.disconnectAll()
        print("\nDisconnected.")
    } catch {
        print("Error: \(error)")
    }
}