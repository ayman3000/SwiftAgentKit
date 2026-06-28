//
//  04-ProjectScaffolder.swift
//  SwiftAgentKit Examples
//
//  Pattern: Planner + ReAct
//  Shows: Plan generation, step-by-step execution, plan progress tracking,
//         plan continuation when the model tries to stop early
//

import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

// ──────────────────────────────────────────────
// Tools
// ──────────────────────────────────────────────

struct CreateFolderTool: AgentTool {
    let name = "create_folder"
    let description = "Create a directory at the given path."
    let parameters = ToolParameters(
        properties: ["path": ToolParameterProperty(type: "string", description: "Folder path to create")],
        required: ["path"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let path = parameters["path"] as? String ?? ""
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return .success(toolCallId: "", toolName: name, result: "Created folder: \(path)")
    }
}

struct CreateFileTool: AgentTool {
    let name = "create_file"
    let description = "Create a file with the given content."
    let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "File path"),
            "content": ToolParameterProperty(type: "string", description: "File content")
        ],
        required: ["path", "content"]
    )
    var requiresConfirmation: Bool { true }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let path = parameters["path"] as? String ?? ""
        let content = parameters["content"] as? String ?? ""
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return .success(toolCallId: "", toolName: name, result: "Created file: \(path)")
    }
}

// ──────────────────────────────────────────────
// Run the agent
// ──────────────────────────────────────────────

func projectScaffolderExample() async throws {
    let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a project scaffolding assistant. Use tools to create the project structure.",
        maxTurns: 20,
        enablePlanning: true,          // generate a plan before executing
        enableRepairRetry: true,        // fix failed tool calls
        enablePlanContinuation: true   // nudge the model if it stops before the plan is done
    ))

    agent.register(CreateFolderTool())
    agent.register(CreateFileTool())

    // Track plan progress
    agent.onEvent { event in
        switch event {
        case .planningStarted:
            print("🧠 Generating plan...")

        case .planGenerated(let steps):
            print("\n📋 Plan with \(steps.count) steps:")
            for (idx, step) in steps.enumerated() {
                print("  \(idx + 1). \(step)")
            }
            print()

        case .toolExecutionStarted(let call):
            print("🔧 \(call.name)(\(call.parameters.values.first ?? ""))")

        case .toolExecutionFinished(_, let result):
            print("  → \(result.result)")

        case .planStepUpdated(let index, _, let status):
            print("  📍 Step \(index + 1): \(status.rawValue)")

        case .planContinuationTriggered(let pending, let attempt):
            print("⏩ Model stopped early! Nudging to continue (attempt \(attempt), \(pending.count) steps left)")

        case .finished(let summary):
            print("\n✨ Done! Turns: \(summary.totalTurns), Steps: \(summary.planStepsCompleted)/\(summary.planStepsTotal)")

        default: break
        }
    }

    // The agent will:
    // 1. Call the LLM (no tools) to generate a plan:
    //    {"steps": ["Create project folder", "Create Package.swift", "Create Sources directory", "Create main.swift", "Create README.md"]}
    // 2. Enter the ReAct loop:
    //    - Turn 1: call create_folder → plan step 1 → completed
    //    - Turn 2: call create_file (Package.swift) → plan step 2 → completed
    //    - Turn 3: call create_folder (Sources) → plan step 3 → completed
    //    - Turn 4: call create_file (main.swift) → plan step 4 → completed
    //    - Turn 5: call create_file (README.md) → plan step 5 → completed
    //    - Turn 6: no more tool calls, all steps done → return summary
    // 3. If the model stops at turn 3 without completing the plan:
    //    - Plan continuation policy nudges: "You must continue. Pending steps: ..."
    //    - The model resumes execution
    let result = try await agent.run("Scaffold a Swift CLI tool called 'greet' at /tmp/greet that prints hello world")
    print("\n📋 Result:\n\(result)")
}

// ──────────────────────────────────────────────
// Run
// ──────────────────────────────────────────────

Task {
    try await projectScaffolderExample()
}