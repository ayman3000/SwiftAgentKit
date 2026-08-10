import Foundation
import LLMProviderKit

/// One scripted LLM response in a replay scenario. Mirrors the answer-bearing
/// fields of `LLMResponse`; `ReplayProvider` reconstructs a full `LLMResponse`
/// at replay time by attaching the live request.
public struct ScriptedTurn: Codable, Equatable {
    public var text: String
    public var reasoning: String?
    public var finishReason: LLMFinishReason?
    public var toolCalls: [LLMToolCall]
    public var usage: LLMUsage?

    public init(
        text: String,
        reasoning: String? = nil,
        finishReason: LLMFinishReason? = nil,
        toolCalls: [LLMToolCall] = [],
        usage: LLMUsage? = nil
    ) {
        self.text = text
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

/// An ordered list of scripted LLM responses for one agent run.
public struct Scenario: Codable, Equatable {
    public var name: String
    public var turns: [ScriptedTurn]

    public init(name: String, turns: [ScriptedTurn]) {
        self.name = name
        self.turns = turns
    }

    /// Load a scenario from a JSON file on disk.
    public static func load(from url: URL) throws -> Scenario {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Scenario.self, from: data)
    }
}

/// The `Fixtures` directory next to the calling test file. The default argument
/// binds `#filePath` at the CALL site, so this resolves relative to the test's
/// source location (works for both reading and `SAK_UPDATE_SNAPSHOTS` writing).
public func fixturesDirectory(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
}
