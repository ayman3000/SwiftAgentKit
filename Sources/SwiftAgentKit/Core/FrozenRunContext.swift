//
//  FrozenRunContext.swift
//  SwiftAgentKit
//
//  The parts of the system prompt an agent re-reads at the start of a run —
//  persistent memory, the app's per-run context, the skill index — kept as
//  text, so a conversation can send the same system prompt run after run
//  (provider prompt caching) and an app can save them with the conversation
//  and restore them after a relaunch.
//

import Foundation

public struct FrozenRunContext: Codable, Sendable, Equatable {
    /// `PromptDigest.hex` of what the engine builds itself: the configured
    /// prompt, the tool line and the tool-group index. A frozen context is
    /// used only with the same base, so a changed engine never sends a stale mix.
    public let baseDigest: String
    public let memory: String
    public let runContext: String
    public let skillIndex: String

    public init(baseDigest: String, memory: String, runContext: String, skillIndex: String) {
        self.baseDigest = baseDigest
        self.memory = memory
        self.runContext = runContext
        self.skillIndex = skillIndex
    }
}
