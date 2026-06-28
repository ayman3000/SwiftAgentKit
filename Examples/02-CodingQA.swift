//
//  02-CodingQA.swift
//  SwiftAgentKit Examples
//
//  Pattern: Multi-turn chat
//  Shows: Conversation history, follow-up questions, context-window trimming
//
//  The agent remembers previous messages so the user can ask follow-ups
//  that reference earlier context ("show me an example of both").
//

import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

func codingQAAssistant() async throws {
    let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a Swift expert. Answer concisely with code examples. If the user asks a follow-up, use context from previous messages.",
        maxTurns: 1,           // one LLM call per run()
        contextWindow: 8192,   // model's context limit in tokens
        maxMessages: 50         // keep last 50 messages before trimming
    ))

    // First question
    print("User: What's the difference between async let and Task?")
    let answer1 = try await agent.run("What's the difference between async let and Task?")
    print("Agent: \(answer1)\n")

    // Follow-up — the agent remembers the previous exchange
    // "both" is understood because the conversation history is sent to the model
    print("User: Show me a concrete example of both")
    let answer2 = try await agent.run("Show me a concrete example of both")
    print("Agent: \(answer2)\n")

    // Another follow-up
    print("User: Which one should I use for fetching multiple API endpoints?")
    let answer3 = try await agent.run("Which one should I use for fetching multiple API endpoints?")
    print("Agent: \(answer3)\n")

    // The conversation history is automatically trimmed:
    // - By message count (keep last 50)
    // - By token budget (estimate tokens as chars/4, trim oldest non-system messages)
    // - System prompt is always preserved
    // - Per-turn fitting: trims to 80% of context window before each LLM call
}

// ──────────────────────────────────────────────
// Run
// ──────────────────────────────────────────────

Task {
    try await codingQAAssistant()
}