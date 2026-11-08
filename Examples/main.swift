//
//  main.swift — the Examples runner.
//
//  swift run Runner        list the examples
//  swift run Runner 02     run one
//
//  Every example in this folder is compiled as part of this target, so
//  `swift build` (and CI) catches an example that falls behind the API.
//

import Foundation

let examples: [(id: String, title: String, run: () async throws -> Void)] = [
    ("01", "Hello Agent — one LLM call, no tools", helloAgent),
    ("02", "Tool Calling — a Swift tool the model calls", toolCalling),
    ("03", "MCP Integration — bridge an MCP server's tools (needs Node)", mcpIntegration),
    ("04", "Simple Chat — text, structured output, streaming", simpleChatExample),
    ("05", "Coding Q&A — multi-turn chat with history", codingQAAssistant),
    ("06", "File Agent — ReAct over read-only file tools", fileAgentExample),
    ("07", "Project Scaffolder — planner + ReAct", projectScaffolderExample),
    ("08", "Stateful Agent — state, events and session persistence", statefulAgentExample),
    ("09", "Guardrails — callbacks that block, rewrite and redact", guardrailsExample),
    ("10", "Skills — progressive-disclosure instructions", skillsExample),
]

let requested = CommandLine.arguments.dropFirst().first

guard let requested, let example = examples.first(where: { $0.id == requested || "0\(requested)" == $0.id }) else {
    print("Usage: swift run Runner <number>\n")
    for example in examples { print("  \(example.id)  \(example.title)") }
    print("\nThe examples use Ollama (`ollama serve`) and pull nothing themselves:")
    print("`ollama pull llama3.2` first, or edit the model name in the example.")
    exit(requested == nil ? 0 : 1)
}

print("=== Example \(example.id): \(example.title) ===\n")
do {
    try await example.run()
} catch {
    print("Error: \(error)")
    exit(1)
}
