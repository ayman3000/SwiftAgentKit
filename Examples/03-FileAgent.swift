//
//  03-FileAgent.swift
//  SwiftAgentKit Examples
//
//  Pattern: ReAct with tools
//  Shows: Tool definition, tool registration, agent loop, event observing,
//         repair-retry when a tool fails
//
//  The agent explores the filesystem: lists directories, reads files,
//  and summarizes what it finds — all autonomously.
//

import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

// ──────────────────────────────────────────────
// Tools
// ──────────────────────────────────────────────

struct ListFilesTool: AgentTool {
    let name = "list_files"
    let description = "List files and folders in a directory."
    let parameters = ToolParameters(
        properties: [
            "directory": ToolParameterProperty(type: "string", description: "The directory path to list")
        ],
        required: ["directory"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let dir = parameters["directory"] as? String ?? "."
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            let listing = files.enumerated().map { index, file in
                "\(index + 1). \(file)"
            }.joined(separator: "\n")
            return .success(toolCallId: "", toolName: name, result: listing.isEmpty ? "Empty directory" : listing)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Cannot read directory: \(dir)")
        }
    }
}

struct ReadFileTool: AgentTool {
    let name = "read_file"
    let description = "Read the contents of a text file."
    let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "The absolute or relative path to the file")
        ],
        required: ["path"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let path = parameters["path"] as? String ?? ""
        if let content = try? String(contentsOfFile: path) {
            // Truncate very long files to avoid blowing the context window
            let truncated = content.count > 5000 ? String(content.prefix(5000)) + "\n... (truncated)" : content
            return .success(toolCallId: "", toolName: name, result: truncated)
        }
        return .error(toolCallId: "", toolName: name, message: "File not found: \(path)")
    }
}

struct CountFilesTool: AgentTool {
    let name = "count_files"
    let description = "Count the number of files in a directory (recursive)."
    let parameters = ToolParameters(
        properties: [
            "directory": ToolParameterProperty(type: "string", description: "The directory to count files in")
        ],
        required: ["directory"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let dir = parameters["directory"] as? String ?? "."
        var count = 0
        if let enumerator = FileManager.default.enumerator(atPath: dir) {
            while enumerator.nextObject() != nil { count += 1 }
        }
        return .success(toolCallId: "", toolName: name, result: "Found \(count) files in \(dir)")
    }
}

// ──────────────────────────────────────────────
// Run the agent
// ──────────────────────────────────────────────

func fileAgentExample() async throws {
    let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: """
        You are a file system analyst. Use the available tools to explore directories \
        and read files. When the user asks about a directory, list its contents first, \
        then read any interesting files to provide a detailed summary.
        """,
        maxTurns: 10,            // allow up to 10 reasoning steps
        enableRepairRetry: true   // if a tool fails, the agent will be nudged to fix it
    ))

    // Register tools
    agent.register(ListFilesTool())
    agent.register(ReadFileTool())
    agent.register(CountFilesTool())

    // Observe what the agent is doing in real time
    agent.onEvent { event in
        switch event {
        case .started(let query):
            print("🚀 Agent started: \(query)")
        case .toolExecutionStarted(let call):
            print("🔧 Running tool: \(call.name) with \(call.parameters)")
        case .toolExecutionFinished(_, let result):
            let preview = result.result.prefix(100)
            print("✅ Result: \(result.isError ? "ERROR" : "OK") — \(preview)")
        case .repairRetryTriggered(_, let attempt):
            print("🔄 Repair-retry triggered (attempt \(attempt))")
        case .finished(let summary):
            print("✨ Done! Turns: \(summary.totalTurns), Tools: \(summary.toolsExecuted), Errors: \(summary.toolErrors)")
        default: break
        }
    }

    // The agent will:
    // Turn 1: call list_files → sees the directory contents
    // Turn 2: call read_file → reads the most interesting file
    // Turn 3: maybe call read_file again for another file
    // Turn 4: no more tool calls → returns a summary
    let summary = try await agent.run("What's in the /tmp directory? Summarize what you find.")
    print("\n📋 Summary:\n\(summary)")
}

// ──────────────────────────────────────────────
// Run
// ──────────────────────────────────────────────

Task {
    try await fileAgentExample()
}