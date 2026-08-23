//
//  ConversationRewriteTests.swift
//  SwiftAgentKit
//
//  Tests for Conversation.rewriteMessages — verifies that the transform
//  is applied to every non-system message while system messages pass through
//  untouched, and that count + order are preserved.
//

import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

@Test func rewriteMessagesTransformsNonSystemOnly() {
    let convo = Conversation(contextWindow: 8192)
    convo.setSystemMessage(AgentMessage(role: .system, content: "SYS"))
    convo.append(AgentMessage(role: .user, content: "hello",
                              images: [LLMImage(data: Data([1, 2, 3]))]))
    convo.append(AgentMessage(role: .assistant, content: "hi"))

    convo.rewriteMessages { message in
        var m = message
        m.images = []
        m.content += " [x]"
        return m
    }

    let all = convo.allMessages()
    #expect(all.count == 3)
    #expect(all[0].role == .system && all[0].content == "SYS")          // untouched
    #expect(all[1].content == "hello [x]" && all[1].images.isEmpty)     // transformed
    #expect(all[2].content == "hi [x]")
}
