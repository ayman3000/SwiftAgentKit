import Testing
import Foundation
import LLMProviderKit
import LLMProviderKitOpenAI
@testable import SwiftAgentKit

/// Prompt caching reuses the longest identical start of a request. These pin
/// that SwiftAgentKit hands a provider the same bytes for the same history on
/// every call.
struct CacheStableRequestTests {
    /// A call as a provider returns it: arguments parsed by JSONSerialization,
    /// so every number is an NSNumber.
    static func parsedCall(_ json: String, id: String = "call_1", name: String = "edit_file") -> AgentToolCall {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return AgentToolCall(id: id, name: name, parameters: object.mapValues { AnyCodable($0) })
    }

    @Test func aReplayedCallIsTheSameBytesEveryTime() {
        let call = Self.parsedCall(
            #"{"path":"/tmp/a.swift","old_text":"x","new_text":"y","replace_all":false,"options":{"b":1,"a":2,"c":[1,2]}}"#)
        let message = AgentMessage.assistant(content: "", toolCalls: [call])
        var seen = Set<String>()
        var noise: [[Int]] = []
        for i in 0..<200 {
            noise.append([Int](repeating: i, count: 1 + (i * 37) % 257))
            if noise.count > 16 { noise.removeFirst(8) }
            seen.insert(message.toLLMMessage().toolCalls?.first?.arguments ?? "")
        }
        #expect(seen.count == 1)
        #expect(seen.first
                == #"{"new_text":"y","old_text":"x","options":{"a":2,"b":1,"c":[1,2]},"path":"\/tmp\/a.swift","replace_all":false}"#)
    }

    /// JSONSerialization gives `1` as an NSNumber that also casts to Bool:
    /// replayed, the call said `true` where the model wrote `1`.
    @Test func numbersAreReplayedAsTheModelWroteThem() {
        let call = Self.parsedCall(#"{"count":1,"zero":0,"flag":true,"off":false,"ratio":2.5,"whole":1.0}"#)
        let arguments = AgentMessage.assistant(content: "", toolCalls: [call]).toLLMMessage().toolCalls?.first?.arguments
        #expect(arguments == #"{"count":1,"flag":true,"off":false,"ratio":2.5,"whole":1,"zero":0}"#)
    }
}
