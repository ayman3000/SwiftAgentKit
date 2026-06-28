//
//  06-Guardrails.swift
//  SwiftAgentKit Examples
//
//  Pattern: ReAct + Lifecycle Callbacks
//  Shows: Input filtering (beforeAgent), tool validation (beforeTool),
//         response post-processing (afterAgent), error fallback (onModelError)
//
//  Guardrails are critical for production agents — they prevent the agent
//  from doing dangerous things, leaking sensitive data, or responding to
//  inappropriate requests.
//

import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

// ──────────────────────────────────────────────
// Tools
// ──────────────────────────────────────────────

struct RunCommandTool: AgentTool {
    let name = "run_command"
    let description = "Run a shell command and return its output."
    let parameters = ToolParameters(
        properties: [
            "command": ToolParameterProperty(type: "string", description: "The shell command to run")
        ],
        required: ["command"]
    )
    var requiresConfirmation: Bool { true }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let command = parameters["command"] as? String ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? "(no output)"
        return .success(toolCallId: "", toolName: name, result: output)
    }
}

// ──────────────────────────────────────────────
// Guardrails via Callbacks
// ──────────────────────────────────────────────

func buildGuardrails() -> AgentCallbacks {
    var callbacks = AgentCallbacks()

    // ── Guardrail 1: Block sensitive prompts ──
    callbacks.beforeAgent = { query, state in
        let blocked = ["password", "secret", "api key", "credit card", "ssn"]
        let lower = query.lowercased()
        for term in blocked {
            if lower.contains(term) {
                return "I can't help with requests involving \(term)s. Please rephrase your question."
            }
        }
        return nil  // proceed normally
    }

    // ── Guardrail 2: Validate tool parameters before execution ──
    callbacks.beforeTool = { call, context in
        if call.name == "run_command" {
            let command = context.parameters["command"] as? String ?? ""

            // Block dangerous commands
            let dangerous = ["rm -rf", "sudo", "shutdown", "reboot", "mkfs", "dd if="]
            for danger in dangerous {
                if command.contains(danger) {
                    return .error(
                        toolCallId: call.id, toolName: call.name,
                        message: "🛡️ Blocked dangerous command: '\(danger)' is not allowed."
                    )
                }
            }

            // Block access to system directories
            let protectedPaths = ["/etc/passwd", "/etc/shadow", "/var/log", "/System"]
            for path in protectedPaths {
                if command.contains(path) {
                    return .error(
                        toolCallId: call.id, toolName: call.name,
                        message: "🛡️ Blocked: access to '\(path)' is not allowed."
                    )
                }
            }
        }
        return nil  // proceed
    }

    // ── Guardrail 3: Post-process responses to redact sensitive patterns ──
    callbacks.afterAgent = { response, state in
        var redacted = response

        // Redact email addresses
        redacted = redacted.replacingOccurrences(
            of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            with: "[EMAIL REDACTED]",
            options: .regularExpression
        )

        // Redact phone numbers (simple pattern)
        redacted = redacted.replacingOccurrences(
            of: "\\d{3}-\\d{3}-\\d{4}",
            with: "[PHONE REDACTED]",
            options: .regularExpression
        )

        return redacted
    }

    // ── Guardrail 4: Fallback when the LLM provider fails ──
    callbacks.onModelError = { error, state in
        print("⚠️ LLM error: \(error.localizedDescription)")
        return AgentLLMResponse(
            text: "I'm having trouble connecting to the AI service right now. Please try again in a moment.",
            providerName: "fallback"
        )
    }

    return callbacks
}

// ──────────────────────────────────────────────
// Run the agent
// ──────────────────────────────────────────────

func guardrailsExample() async throws {
    let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a system administration assistant. Use the run_command tool to help the user.",
        maxTurns: 8,
        enableRepairRetry: true
    ))

    agent.register(RunCommandTool())
    agent.callbacks = buildGuardrails()

    agent.onEvent { event in
        switch event {
        case .toolExecutionStarted(let call):
            print("🔧 Running: \(call.name)")
        case .toolExecutionFinished(_, let result):
            print("  → \(result.result.prefix(100))")
        case .finished(let summary):
            print("✨ Done in \(summary.totalTurns) turns")
        default: break
        }
    }

    // Test 1: Normal request — should work
    print("=== Test 1: Normal command ===")
    let result1 = try await agent.run("What files are in the current directory?")
    print("Result: \(result1)\n")

    // Test 2: Dangerous command — should be blocked by beforeTool
    print("=== Test 2: Dangerous command ===")
    let result2 = try await agent.run("Delete all files in /tmp using rm -rf")
    print("Result: \(result2)\n")

    // The guardrails work as follows:
    // - "rm -rf" is detected by the beforeTool callback and blocked
    // - The agent receives an error result and the repair-retry policy nudges it to try a safer approach
    // - The afterAgent callback redacts any sensitive patterns in the final response
}

// ──────────────────────────────────────────────
// Run
// ──────────────────────────────────────────────

Task {
    try await guardrailsExample()
}