// 01-HelloAgent.swift
// The simplest possible SwiftAgentKit agent — one LLM call, no tools.
//
// Run: swift run Runner 01

import Foundation
import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

func helloAgent() async throws {
    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "llama3.2"))
    let agent = Agent(config: AgentConfig(
        provider: provider,
        systemPrompt: "You are a helpful Swift assistant. Answer concisely.",
        maxTurns: 1
    ))

    let answer = try await agent.run("Explain async/await in one sentence.")
    print(answer)
}