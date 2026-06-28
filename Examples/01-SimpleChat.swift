//
//  01-SimpleChat.swift
//  SwiftAgentKit Examples
//
//  Pattern: Single-shot
//  Shows: Basic LLM call, structured output parsing
//
//  Run this in a Swift Playground or as part of an app.
//  Requires: Ollama running locally (ollama serve) with a model installed.
//

import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

// ──────────────────────────────────────────────
// Example 1A: Simple text response
// ──────────────────────────────────────────────

func simpleTextResponse() async throws {
    let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a helpful assistant. Keep answers under 3 sentences.",
        maxTurns: 0  // single-shot: one LLM call, no loop
    ))

    let reply = try await agent.run("What is protocol-oriented programming in Swift?")
    print(reply)
}

// ──────────────────────────────────────────────
// Example 1B: Structured output (parse JSON)
// ──────────────────────────────────────────────

func structuredOutput() async throws {
    let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: """
        You are a classifier. Read the support ticket and return JSON with this exact format:
        {"category": "bug|feature|question|billing", "priority": "low|medium|high|urgent", "summary": "one sentence summary"}
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

    let result = try await agent.runStructured(ticket, as: TicketClassification.self)
    print("Category: \(result.category)")  // "bug"
    print("Priority: \(result.priority)")  // "high"
    print("Summary: \(result.summary)")    // one sentence
}

// ──────────────────────────────────────────────
// Example 1C: Classification with streaming
// ──────────────────────────────────────────────

func streamingResponse() async throws {
    let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a creative writer.",
        maxTurns: 0
    ))

    print("Writing story...")
    for try await chunk in agent.stream("Write a 3-paragraph story about a robot learning to paint") {
        print(chunk, terminator: "")
    }
    print()  // final newline
}

// ──────────────────────────────────────────────
// Run all
// ──────────────────────────────────────────────

Task {
    print("=== Simple Text Response ===")
    try await simpleTextResponse()

    print("\n=== Structured Output ===")
    try await structuredOutput()

    print("\n=== Streaming ===")
    try await streamingResponse()
}