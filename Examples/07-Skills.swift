//
//  07-Skills.swift
//  SwiftAgentKit Examples
//
//  Pattern: ReAct + Progressive Disclosure Skills
//  Shows: Skill registration, trigger-keyword matching, tier gating,
//         and how skills save tokens by only injecting relevant instructions
//
//  Skills are the key to running efficient agents on local models with
//  small context windows. Instead of stuffing every instruction into the
//  system prompt, skills are injected only when the query matches.
//

import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

// ──────────────────────────────────────────────
// Tools (shared across all skills)
// ──────────────────────────────────────────────

struct ReadFileTool: AgentTool {
    let name = "read_file"
    let description = "Read the contents of a file."
    let parameters = ToolParameters(
        properties: ["path": ToolParameterProperty(type: "string", description: "File path")],
        required: ["path"]
    )
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let path = parameters["path"] as? String ?? ""
        let content = (try? String(contentsOfFile: path)) ?? "File not found"
        return .success(toolCallId: "", toolName: name, result: content)
    }
}

struct WriteFileTool: AgentTool {
    let name = "write_file"
    let description = "Write content to a file."
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
        return .success(toolCallId: "", toolName: name, result: "Wrote to \(path)")
    }
}

// ──────────────────────────────────────────────
// Run the agent
// ──────────────────────────────────────────────

func skillsExample() async throws {
    let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a versatile coding assistant. Use tools when needed.",
        maxTurns: 15,
        enableRepairRetry: true
    ))

    agent.register(ReadFileTool())
    agent.register(WriteFileTool())

    // ── Register Skills ──

    // Skill 1: SwiftUI expertise — activated when the user mentions SwiftUI
    agent.registerSkill(AgentSkill(
        name: "swiftui",
        triggerKeywords: ["swiftui", "view", "swift ui", "navigationstack", "list", "form"],
        instructions: """
        When working with SwiftUI:
        - Use `@Observable` for models (not ObservableObject) on macOS 14+/iOS 17+
        - Use `@State` for view-local state
        - Prefer `NavigationStack` over `NavigationView`
        - Use `.onChange(of: value) { _, _ in ... }` syntax (not the deprecated single-parameter version)
        - For lists, use `List { ForEach(items) { item in ... } }` pattern
        """
    ))

    // Skill 2: Testing expertise — activated when the user mentions tests
    agent.registerSkill(AgentSkill(
        name: "testing",
        triggerKeywords: ["test", "xctest", "swift testing", "@test", "unit test", "mock"],
        instructions: """
        When writing tests:
        - Use the new Swift Testing framework (`import Testing`, `@Test` macro) for new code
        - Use `#expect(condition)` instead of `XCTAssert(condition)`
        - Use `#expect throwsError` for error testing
        - Name tests descriptively: `@Test func whenUserLogsIn_thenRedirectsToDashboard()`
        - Mock dependencies with protocols, not class inheritance
        """
    ))

    // Skill 3: Scaffolding — activated when the user wants to create a new project
    agent.registerSkill(AgentSkill(
        name: "scaffolding",
        triggerKeywords: ["scaffold", "new project", "create app", "set up project", "bootstrap"],
        instructions: """
        When scaffolding a project:
        1. Ask for the project name if not provided
        2. Create the directory structure
        3. Create Package.swift (for CLI tools) or .xcodeproj (for apps)
        4. Create a main entry point
        5. Create a README.md with setup instructions
        6. Create a .gitignore for Swift projects
        """,
        tier: "pro"  // only available for pro users
    ))

    // ── Set tier filter ──
    // If you have free/pro tiers, set the filter so only matching skills are active.
    // Skills with no tier are always available. Skills with tier="pro" only activate
    // when the filter is set to "pro".
    // await agent.skillRegistry.setTierFilter("pro")  // uncomment to enable pro skills
    // await agent.skillRegistry.setTierFilter("free")  // only tierless skills + free-tier skills

    // ── Observe which skills activate ──
    agent.onEvent { event in
        switch event {
        case .skillsActivated(let names):
            print("🎯 Skills activated: \(names.joined(separator: ", "))")

        case .toolExecutionStarted(let call):
            print("🔧 \(call.name)")

        case .toolExecutionFinished(_, let result):
            print("  → \(result.result.prefix(80))")

        case .finished(let summary):
            print("✨ Done in \(summary.totalTurns) turns\n")

        default: break
        }
    }

    // ── Test 1: SwiftUI question — activates swiftui skill ──
    print("=== Test 1: SwiftUI Question ===")
    let result1 = try await agent.run("How do I create a SwiftUI view with a list and navigation?")
    print("Result: \(result1.prefix(200))...\n")
    // Output: 🎯 Skills activated: swiftui
    // The swiftui skill instructions are injected into the system prompt.
    // The testing and scaffolding skills stay dormant — saving ~400 tokens.

    // ── Test 2: Testing question — activates testing skill ──
    print("=== Test 2: Testing Question ===")
    let result2 = try await agent.run("Write a unit test for a function that parses JSON")
    print("Result: \(result2.prefix(200))...\n")
    // Output: 🎯 Skills activated: testing
    // Only the testing skill is injected. SwiftUI skill is dormant.

    // ── Test 3: Unrelated question — no skills activate ──
    print("=== Test 3: No Skills ===")
    let result3 = try await agent.run("What's the capital of France?")
    print("Result: \(result3)\n")
    // No skills activate — the system prompt stays minimal.
    // The model uses its general knowledge to answer.

    // Key insight: without skills, you'd need to include ALL instructions
    // (SwiftUI, testing, scaffolding) in every system prompt — even for
    // "What's the capital of France?" That's hundreds of wasted tokens.
    // With progressive disclosure, only relevant expertise is loaded.
}

// ──────────────────────────────────────────────
// Run
// ──────────────────────────────────────────────

Task {
    try await skillsExample()
}