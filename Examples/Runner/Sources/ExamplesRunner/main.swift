import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama
import LLMProviderKitGemini
import Foundation
import AppKit

// ──────────────────────────────────────────────
// Config: glm-5.2 for text, kimi for vision
// ──────────────────────────────────────────────

let textModel = "glm-5.2:cloud"
let visionModel = "kimi-k2.7-code:cloud"
let textProvider = OllamaProvider(configuration: OllamaProvider.local(model: textModel))
let visionProvider = OllamaProvider(configuration: OllamaProvider.local(model: visionModel))

// Gemini provider (real API key from environment)
let geminiApiKey = ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
    ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
    ?? ""
let geminiModel = "gemini-2.5-flash-lite"
let geminiProvider = GeminiProvider(configuration: GeminiProvider.gemini(apiKey: geminiApiKey, model: geminiModel))

func separator(_ title: String) {
    print("\n\(String(repeating: "=", count: 60))")
    print("  \(title)")
    print("\(String(repeating: "=", count: 60))\n")
}

func runExample(_ name: String, _ fn: () async throws -> Void) async {
    do {
        try await fn()
    } catch AgentError.maxTurnsReached(let turns) {
        print("⚠️ Max turns (\(turns)) reached in \(name)")
    } catch {
        print("❌ Error in \(name): \(error)")
    }
}

// ──────────────────────────────────────────────
// Example 1: Simple Chat (single-shot)
// ──────────────────────────────────────────────

func example1() async throws {
    separator("Example 1: Simple Chat (single-shot, glm-5.2)")

    let agent = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: "You are a helpful assistant. Keep answers under 3 sentences.",
        maxTurns: 0
    ))

    let reply = try await agent.run("What is protocol-oriented programming in Swift?")
    print("Response: \(reply)")
}

// ──────────────────────────────────────────────
// Example 1B: Structured Output
// ──────────────────────────────────────────────

func example1B() async throws {
    separator("Example 1B: Structured Output (ticket classification, glm-5.2)")

    let agent = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: """
        You are a classifier. Read the support ticket and return JSON with this exact format:
        {"category": "bug|feature|question|billing", "priority": "low|medium|high|urgent", "summary": "one sentence summary"}
        Return ONLY the JSON, no markdown, no explanation.
        """,
        maxTurns: 0
    ))

    struct TicketClassification: Codable {
        let category: String
        let priority: String
        let summary: String
    }

    let ticket = """
    Subject: App crashes when I click "Export"
    Body: Every time I try to export my project as a PDF, the app freezes and then
    closes. I'm on version 2.3.1 and this started happening after the latest update.
    I have a deadline tomorrow and really need this to work!
    """

    do {
        let result = try await agent.runStructured(ticket, as: TicketClassification.self)
        print("Category: \(result.category)")
        print("Priority: \(result.priority)")
        print("Summary: \(result.summary)")
    } catch {
        print("Parse error: \(error)")
    }
}

// ──────────────────────────────────────────────
// Example 2: Multi-turn chat
// ──────────────────────────────────────────────

func example2() async throws {
    separator("Example 2: Multi-turn Chat (coding Q&A, glm-5.2)")

    let agent = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: "You are a Swift expert. Answer concisely with code examples.",
        maxTurns: 1,
        contextWindow: 8192,
        maxMessages: 50
    ))

    print("User: What's the difference between async let and Task?")
    let answer1 = try await agent.run("What's the difference between async let and Task?")
    print("Agent: \(answer1.prefix(300))...\n")

    print("User: Show me a concrete example of both")
    let answer2 = try await agent.run("Show me a concrete example of both")
    print("Agent: \(answer2.prefix(300))...")
}

// ──────────────────────────────────────────────
// Example 3: ReAct with Tools (file agent)
// ──────────────────────────────────────────────

func example3() async throws {
    separator("Example 3: ReAct with Tools (file agent, glm-5.2)")

    struct ListFilesTool: AgentTool {
        let name = "list_files"
        let description = "List files and folders in a directory."
        let parameters = ToolParameters(
            properties: ["directory": ToolParameterProperty(type: "string", description: "The directory path to list")],
            required: ["directory"]
        )
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            let dir = parameters["directory"] as? String ?? "."
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: dir)
                let listing = files.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
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
            properties: ["path": ToolParameterProperty(type: "string", description: "File path")],
            required: ["path"]
        )
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            let path = parameters["path"] as? String ?? ""
            if let content = try? String(contentsOfFile: path) {
                let truncated = content.count > 2000 ? String(content.prefix(2000)) + "\n... (truncated)" : content
                return .success(toolCallId: "", toolName: name, result: truncated)
            }
            return .error(toolCallId: "", toolName: name, message: "File not found: \(path)")
        }
    }

    let agent = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: "You are a file system analyst. Use tools to explore directories and read files. When you have enough information, stop calling tools and write your summary.",
        maxTurns: 10,
        enableRepairRetry: true
    ))

    agent.register(ListFilesTool())
    agent.register(ReadFileTool())

    agent.onEvent { event in
        switch event {
        case .toolExecutionStarted(let call):
            let firstParam = call.parameters.values.first
            print("🔧 \(call.name)(\(firstParam?.stringValue ?? firstParam.map { "\($0)" } ?? ""))")
        case .toolExecutionFinished(_, let result):
            print("  → \(result.isError ? "ERROR" : "OK"): \(result.result.prefix(120))")
        case .finished(let s):
            print("✨ Turns: \(s.totalTurns), Tools: \(s.toolsExecuted)")
        default: break
        }
    }

    let summary: String
    do {
        summary = try await agent.run("What files are in the /tmp directory? Read any interesting ones and tell me what you find.")
    } catch AgentError.maxTurnsReached(let turns) {
        summary = "⚠️ Max turns (\(turns)) — model kept calling tools without summarizing."
    }
    print("\n📋 Summary:\n\(summary.prefix(500))")
}

// ──────────────────────────────────────────────
// Example 4: Planner + ReAct (project scaffolder)
// ──────────────────────────────────────────────

func example4() async throws {
    separator("Example 4: Planner + ReAct (project scaffolder, glm-5.2)")

    struct CreateFolderTool: AgentTool {
        let name = "create_folder"
        let description = "Create a directory at the given path."
        let parameters = ToolParameters(
            properties: ["path": ToolParameterProperty(type: "string", description: "Folder path")],
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
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            let path = parameters["path"] as? String ?? ""
            let content = parameters["content"] as? String ?? ""
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return .success(toolCallId: "", toolName: name, result: "Created file: \(path)")
        }
    }

    let agent = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: "You are a project scaffolding assistant. Use tools to create the project structure.",
        maxTurns: 15,
        enablePlanning: true,
        enableRepairRetry: true,
        enablePlanContinuation: true
    ))

    agent.register(CreateFolderTool())
    agent.register(CreateFileTool())

    agent.onEvent { event in
        switch event {
        case .planningStarted: print("🧠 Generating plan...")
        case .planGenerated(let steps):
            print("📋 Plan (\(steps.count) steps):")
            steps.enumerated().forEach { print("  \($0 + 1). \($1)") }
        case .toolExecutionStarted(let call): print("🔧 \(call.name)")
        case .toolExecutionFinished(_, let r): print("  → \(r.result)")
        case .planContinuationTriggered(let pending, let a): print("⏩ Continue (attempt \(a), \(pending.count) left)")
        case .finished(let s): print("✨ Turns: \(s.totalTurns), Steps: \(s.planStepsCompleted)/\(s.planStepsTotal)")
        default: break
        }
    }

    let result: String
    do {
        result = try await agent.run("Create a simple Swift project at /tmp/swift-greet with a main.swift that prints 'Hello World'")
    } catch AgentError.maxTurnsReached(let turns) {
        result = "⚠️ Max turns (\(turns)) reached."
    }
    print("\n📋 Result:\n\(result.prefix(500))")
}

// ──────────────────────────────────────────────
// Example 5: Stateful Agent (tools sharing state)
// ──────────────────────────────────────────────

func example5() async throws {
    separator("Example 5: Stateful Agent (tools sharing state, glm-5.2)")

    struct LookupAccountTool: AgentTool {
        let name = "lookup_account"
        let description = "Look up a customer account by email address."
        let parameters = ToolParameters(
            properties: ["email": ToolParameterProperty(type: "string", description: "Customer email")],
            required: ["email"]
        )
        func execute(context: ToolContext) async throws -> AgentToolResult {
            let email = context.parameters["email"] as? String ?? ""
            let mockCustomers: [String: [String: String]] = [
                "ayman@example.com": ["name": "Ayman", "tier": "pro", "id": "CUST-001"],
                "sara@example.com": ["name": "Sara", "tier": "free", "id": "CUST-002"],
            ]
            guard let customer = mockCustomers[email] else {
                return .error(toolCallId: context.callId, toolName: name, message: "No account for \(email)")
            }
            context.state.setValue(customer["name"]!, forKey: "user:name")
            context.state.setValue(customer["tier"]!, forKey: "user:tier")
            context.state.setValue(customer["id"]!, forKey: "user:id")
            return .success(toolCallId: context.callId, toolName: name,
                          result: "Found: \(customer["name"]!) (ID: \(customer["id"]!), Tier: \(customer["tier"]!))")
        }
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            .success(toolCallId: "", toolName: name, result: "Use context version")
        }
    }

    struct CheckOrdersTool: AgentTool {
        let name = "check_orders"
        let description = "Check order history for the current customer."
        let parameters = ToolParameters.empty
        func execute(context: ToolContext) async throws -> AgentToolResult {
            guard let customerId = context.state.string(forKey: "user:id") else {
                return .error(toolCallId: context.callId, toolName: name, message: "No customer loaded. Call lookup_account first.")
            }
            let orders = customerId == "CUST-001"
                ? ["Order #1001: Swift book ($29) - delivered", "Order #1002: USB-C cable ($12) - shipped"]
                : ["Order #2001: Notebook ($5) - delivered"]
            context.state.setValue(orders.count, forKey: "user:order_count")
            return .success(toolCallId: context.callId, toolName: name,
                          result: "Orders for \(customerId):\n" + orders.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n"))
        }
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            .success(toolCallId: "", toolName: name, result: "Use context version")
        }
    }

    let agent = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: """
        You are a customer support agent.
        Current customer: {user:name} (Tier: {user:tier})
        Always look up the customer first, check their orders, then help them.
        """,
        maxTurns: 8,
        enableRepairRetry: true
    ))

    agent.state.setValue("ayman@example.com", forKey: "user:email")
    agent.register(LookupAccountTool())
    agent.register(CheckOrdersTool())

    agent.onEvent { event in
        switch event {
        case .toolExecutionStarted(let call): print("🔧 \(call.name)")
        case .toolExecutionFinished(_, let r): print("  → \(r.result.prefix(120))")
        case .finished(let s): print("✨ Turns: \(s.totalTurns), Tools: \(s.toolsExecuted)")
        default: break
        }
    }

    let result: String
    do {
        result = try await agent.run("I haven't received my USB-C cable yet. Can you check my orders and help me?")
    } catch AgentError.maxTurnsReached(let turns) {
        result = "⚠️ Max turns (\(turns)) reached."
    }
    print("\n📋 Result:\n\(result.prefix(500))")
}

// ──────────────────────────────────────────────
// Example 6: Guardrails (lifecycle callbacks)
// ──────────────────────────────────────────────

func example6() async throws {
    separator("Example 6: Guardrails (lifecycle callbacks, glm-5.2)")

    struct RunCommandTool: AgentTool {
        let name = "run_command"
        let description = "Run a shell command and return its output."
        let parameters = ToolParameters(
            properties: ["command": ToolParameterProperty(type: "string", description: "Shell command")],
            required: ["command"]
        )
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            let command = parameters["command"] as? String ?? ""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "(no output)"
            return .success(toolCallId: "", toolName: name, result: output.isEmpty ? "(empty)" : output)
        }
    }

    var callbacks = AgentCallbacks()

    callbacks.beforeAgent = { query, state in
        let blocked = ["password", "secret", "api key", "credit card"]
        let lower = query.lowercased()
        for term in blocked {
            if lower.contains(term) {
                return "I can't help with requests involving \(term)s. Please rephrase your question."
            }
        }
        return nil
    }

    callbacks.beforeTool = { call, context in
        if call.name == "run_command" {
            let command = context.parameters["command"] as? String ?? ""
            let dangerous = ["rm -rf", "sudo", "shutdown", "reboot", "mkfs"]
            for danger in dangerous {
                if command.contains(danger) {
                    return .error(toolCallId: call.id, toolName: call.name,
                                message: "🛡️ Blocked dangerous command: '\(danger)' is not allowed.")
                }
            }
        }
        return nil
    }

    callbacks.onModelError = { error, state in
        print("⚠️ LLM error: \(error.localizedDescription)")
        return AgentLLMResponse(text: "The AI service is temporarily unavailable.", providerName: "fallback")
    }

    let agent = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: "You are a system admin assistant. Use the run_command tool to help.",
        maxTurns: 10,
        enableRepairRetry: true
    ))

    agent.register(RunCommandTool())
    agent.callbacks = callbacks

    agent.onEvent { event in
        switch event {
        case .toolExecutionStarted(let call): print("🔧 \(call.name)")
        case .toolExecutionFinished(_, let r): print("  → \(r.result.prefix(100))")
        case .finished(let s): print("✨ Turns: \(s.totalTurns)")
        default: break
        }
    }

    print("--- Test A: Normal command ---")
    do {
        let resultA = try await agent.run("What files are in the /tmp directory?")
        print("Result: \(resultA.prefix(200))\n")
    } catch AgentError.maxTurnsReached(let turns) {
        print("⚠️ Max turns (\(turns)) — model kept calling tools.\n")
    } catch {
        print("Error: \(error)\n")
    }

    print("--- Test B: Dangerous command ---")
    do {
        let resultB = try await agent.run("Delete all files using rm -rf /tmp")
        print("Result: \(resultB.prefix(200))")
    } catch AgentError.maxTurnsReached(let turns) {
        print("⚠️ Max turns (\(turns)) reached.")
    } catch {
        print("Error: \(error)")
    }
}

// ──────────────────────────────────────────────
// Example 7: Skills (progressive disclosure)
// ──────────────────────────────────────────────

func example7() async throws {
    separator("Example 7: Skills (progressive disclosure, glm-5.2)")

    let agent = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: "You are a versatile coding assistant.",
        maxTurns: 1
    ))

    agent.registerSkill(AgentSkill(
        name: "swiftui",
        triggerKeywords: ["swiftui", "view", "navigationstack", "list", "form"],
        instructions: """
        When working with SwiftUI:
        - Use @Observable for models (not ObservableObject) on macOS 14+
        - Use NavigationStack over NavigationView
        - Use .onChange(of: value) { _, _ in ... } syntax
        """
    ))

    agent.registerSkill(AgentSkill(
        name: "testing",
        triggerKeywords: ["test", "xctest", "swift testing", "@test", "unit test"],
        instructions: """
        When writing tests:
        - Use Swift Testing framework (import Testing, @Test macro)
        - Use #expect(condition) instead of XCTAssert
        - Name tests descriptively
        """
    ))

    agent.onEvent { event in
        switch event {
        case .skillsActivated(let names): print("🎯 Skills: \(names)")
        case .finished(let s): print("✨ Turns: \(s.totalTurns)\n")
        default: break
        }
    }

    print("--- Test A: SwiftUI question ---")
    do {
        let resultA = try await agent.run("How do I create a SwiftUI NavigationStack with a list?")
        print("Response: \(resultA.prefix(300))...\n")
    } catch { print("Error: \(error)\n") }

    print("--- Test B: Testing question ---")
    do {
        let resultB = try await agent.run("How do I write a unit test with Swift Testing?")
        print("Response: \(resultB.prefix(300))...\n")
    } catch { print("Error: \(error)\n") }

    print("--- Test C: Unrelated question ---")
    do {
        let resultC = try await agent.run("What's the capital of France?")
        print("Response: \(resultC)")
    } catch { print("Error: \(error)") }
}

// ──────────────────────────────────────────────
// Example 8: Vision (kimi-k2.7-code:cloud)
// ──────────────────────────────────────────────

func example8() async throws {
    separator("Example 8: Vision (kimi-k2.7-code:cloud)")

    // Create a simple test image using CoreGraphics (no AppKit needed)
    let width = 200, height = 100
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let cgContext = CGContext(data: nil, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
        print("❌ Could not create image context")
        return
    }

    // Fill with red background
    cgContext.setFillColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
    cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Draw a white circle
    cgContext.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    cgContext.fillEllipse(in: CGRect(x: 60, y: 20, width: 60, height: 60))

    guard let cgImage = cgContext.makeImage() else {
        print("❌ Could not create CGImage")
        return
    }

    // Convert to PNG data
    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmapRep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
        print("❌ Could not create PNG data")
        return
    }

    let image = LLMImage(data: pngData, mimeType: "image/png")

    let request = LLMRequest(
        model: visionModel,
        messages: [
            .system("You are a vision assistant. Describe what you see in the image in detail. Mention colors, shapes, and any text."),
            .user("What do you see in this image? Describe the colors, shapes, and layout.", images: [image])
        ],
        temperature: 0.3
    )

    print("📸 Sending a red image with a white circle to kimi-k2.7-code:cloud...")
    let llmResponse = try await visionProvider.complete(request)
    print("\n👁️ Vision Response:\n\(llmResponse.text)")
}

// ──────────────────────────────────────────────
// Example 9: Session Persistence
// ──────────────────────────────────────────────

func example9() async throws {
    separator("Example 9: Session Persistence (save/load conversation)")

    let store = FileSessionStore(directoryPath: "/tmp/agent_sessions")

    let agent = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: "You are a helpful assistant.",
        maxTurns: 1
    ))

    // Have a conversation
    print("💬 Having a conversation...")
    _ = try await agent.run("My name is Ayman and I'm building a Swift agent kit.")
    _ = try await agent.run("What's my name?")

    // Save the session
    let sessionId = "test-session-001"
    try await agent.saveSession(store: store, sessionId: sessionId)
    print("💾 Saved session '\(sessionId)' (\(agent.conversation.allMessages().count) messages)")

    // List sessions
    let sessions = try await store.listSessions()
    print("📁 Available sessions: \(sessions)")

    // Create a new agent and load the session
    let agent2 = Agent(config: AgentConfig(
        provider: textProvider,
        systemPrompt: "You are a helpful assistant.",
        maxTurns: 1
    ))

    let loaded = try await agent2.loadSession(store: store, sessionId: sessionId)
    print("📂 Loaded session: \(loaded ? "YES" : "NO")")
    print("📋 Restored \(agent2.conversation.allMessages().count) messages")

    // Verify the agent remembers the context
    let reply = try await agent2.run("What did I tell you my name was?")
    print("🤖 Agent2 says: \(reply)")

    // Clean up
    try await agent2.clearSession(store: store, sessionId: sessionId)
    print("🧹 Session deleted")
}

// ──────────────────────────────────────────────
// Example 10: Gemini 2.5 Flash Lite (text + tools)
// ──────────────────────────────────────────────

func example10() async throws {
    separator("Example 10: Gemini 2.5 Flash Lite (text + tool calling)")

    guard !geminiApiKey.isEmpty else {
        print("❌ No GOOGLE_API_KEY in environment. Skipping Gemini test.")
        return
    }

    // --- Test A: Simple chat ---
    print("--- Test A: Simple chat ---")
    let agent = Agent(config: AgentConfig(
        provider: geminiProvider,
        systemPrompt: "You are a helpful assistant. Keep answers under 3 sentences.",
        maxTurns: 0
    ))

    let reply = try await agent.run("What is protocol-oriented programming in Swift?")
    print("Response: \(reply)\n")

    // --- Test B: Tool calling (file agent) ---
    print("--- Test B: Tool calling (file agent) ---")

    struct ListFilesTool: AgentTool {
        let name = "list_files"
        let description = "List files and folders in a directory."
        let parameters = ToolParameters(
            properties: ["directory": ToolParameterProperty(type: "string", description: "The directory path to list")],
            required: ["directory"]
        )
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            let dir = parameters["directory"] as? String ?? "."
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: dir)
                let listing = files.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
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
            properties: ["path": ToolParameterProperty(type: "string", description: "File path")],
            required: ["path"]
        )
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            let path = parameters["path"] as? String ?? ""
            if let content = try? String(contentsOfFile: path) {
                let truncated = content.count > 2000 ? String(content.prefix(2000)) + "\n... (truncated)" : content
                return .success(toolCallId: "", toolName: name, result: truncated)
            }
            return .error(toolCallId: "", toolName: name, message: "File not found: \(path)")
        }
    }

    let toolAgent = Agent(config: AgentConfig(
        provider: geminiProvider,
        systemPrompt: "You are a file system analyst. Use tools to explore directories and read files. When you have enough information, stop calling tools and write your summary.",
        maxTurns: 10,
        enableRepairRetry: true
    ))

    toolAgent.register(ListFilesTool())
    toolAgent.register(ReadFileTool())

    toolAgent.onEvent { event in
        switch event {
        case .toolExecutionStarted(let call):
            let firstParam = call.parameters.values.first
            print("🔧 \(call.name)(\(firstParam?.stringValue ?? firstParam.map { "\($0)" } ?? ""))")
        case .toolExecutionFinished(_, let result):
            print("  → \(result.isError ? "ERROR" : "OK"): \(result.result.prefix(120))")
        case .finished(let s):
            print("✨ Turns: \(s.totalTurns), Tools: \(s.toolsExecuted)")
        default: break
        }
    }

    let summary: String
    do {
        summary = try await toolAgent.run("What files are in the /tmp directory? Read any interesting ones and tell me what you find.")
    } catch AgentError.maxTurnsReached(let turns) {
        summary = "⚠️ Max turns (\(turns)) — model kept calling tools without summarizing."
    }
    print("\n📋 Summary:\n\(summary.prefix(500))")

    // --- Test C: Structured output ---
    print("\n--- Test C: Structured output ---")

    struct TicketClassification: Codable {
        let category: String
        let priority: String
        let summary: String
    }

    let structAgent = Agent(config: AgentConfig(
        provider: geminiProvider,
        systemPrompt: """
        You are a classifier. Read the support ticket and return JSON with this exact format:
        {"category": "bug|feature|question|billing", "priority": "low|medium|high|urgent", "summary": "one sentence summary"}
        Return ONLY the JSON, no markdown, no explanation.
        """,
        maxTurns: 0
    ))

    let ticket = """
    Subject: App crashes when I click "Export"
    Body: Every time I try to export my project as a PDF, the app freezes and then
    closes. I'm on version 2.3.1 and this started happening after the latest update.
    I have a deadline tomorrow and really need this to work!
    """

    do {
        let result = try await structAgent.runStructured(ticket, as: TicketClassification.self)
        print("Category: \(result.category)")
        print("Priority: \(result.priority)")
        print("Summary: \(result.summary)")
    } catch {
        print("Parse error: \(error)")
    }
}

// ──────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────

@main
struct ExamplesRunner {
    static func main() async throws {
        print("🤖 SwiftAgentKit v2 Examples Runner")
        print("📝 Text model: \(textModel)")
        print("👁️ Vision model: \(visionModel)")
        print("🌐 Gemini model: \(geminiModel)")
        print("🌐 Provider: Ollama (localhost:11434) + Gemini API")

        await runExample("1", example1)
        await runExample("1B", example1B)
        await runExample("2", example2)
        await runExample("3", example3)
        await runExample("4", example4)
        await runExample("5", example5)
        await runExample("6", example6)
        await runExample("7", example7)
        await runExample("8", example8)
        await runExample("9", example9)
        await runExample("10", example10)

        print("\n\n✅ All examples completed!")
    }
}