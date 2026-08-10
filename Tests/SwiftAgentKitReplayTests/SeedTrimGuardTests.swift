import Testing
import Foundation
@testable import SwiftAgentKit

@Test func contextTrimAlwaysKeepsANonSystemMessage() {
    // Tiny window forces aggressive trimming; a big system prompt + long history
    // reproduces the case where naive trimming removed every non-system message.
    let convo = Conversation(contextWindow: 256, maxMessages: 50)
    convo.setSystemMessage(.system(String(repeating: "system rules. ", count: 200)))
    for i in 0..<20 {
        convo.append(.user("user turn \(i) " + String(repeating: "x", count: 50)))
        convo.append(.assistant("assistant reply \(i) " + String(repeating: "y", count: 50)))
    }

    let messages = convo.messagesForLLMCall()

    let hasNonSystem = messages.contains { $0.role != .system }
    #expect(hasNonSystem, "trimming stripped every non-system message → Gemini empty contents 400")
}
