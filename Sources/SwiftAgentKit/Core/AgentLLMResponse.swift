//
//  AgentLLMResponse.swift
//  SwiftAgentKit
//
//  Bridges between LLMProviderKit's response types and the agent layer.
//  Adds tool-call parsing that LLMProviderKit doesn't do (yet).
//

import Foundation
import LLMProviderKit

/// The agent-layer representation of an LLM response.
///
/// Wraps `LLMResponse` from LLMProviderKit and adds:
/// - Parsed tool calls (extracted from the response content or native tool-call fields)
/// - Usage stats for token tracking
/// - The raw response for debugging
///
public struct AgentLLMResponse: Sendable {

    public let text: String
    public let toolCalls: [AgentToolCall]?
    public let finishReason: AgentFinishReason
    public let usage: AgentTokenUsage?
    public let providerName: String

    public init(
        text: String,
        toolCalls: [AgentToolCall]? = nil,
        finishReason: AgentFinishReason = .stop,
        usage: AgentTokenUsage? = nil,
        providerName: String
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.usage = usage
        self.providerName = providerName
    }

    /// Whether the model is requesting tool execution.
    public var hasToolCalls: Bool {
        guard let toolCalls else { return false }
        return !toolCalls.isEmpty
    }

    /// Create from an `LLMResponse` (LLMProviderKit).
    /// Checks native tool calls first, then falls back to text-marker parsing.
    public static func from(_ response: LLMResponse) -> AgentLLMResponse {
        // Priority 1: Native tool calls from the provider (Ollama native, OpenAI, etc.)
        if !response.toolCalls.isEmpty {
            let agentToolCalls = response.toolCalls.map { tc in
                // Decode arguments JSON string to AnyCodable dict
                var params: [String: AnyCodable] = [:]
                if let decoded = tc.decodedArguments() {
                    for (key, value) in decoded {
                        params[key] = AnyCodable(value)
                    }
                }
                return AgentToolCall(id: tc.id, name: tc.name, parameters: params)
            }
            return AgentLLMResponse(
                text: response.text,
                toolCalls: agentToolCalls,
                finishReason: .toolCalls,
                usage: AgentTokenUsage.from(response.usage),
                providerName: response.providerName
            )
        }

        // Priority 2: Text-marker parsing (TOOL_CALL: name {json} or JSON array)
        let textToolCalls = ToolCallParser.parse(from: response.text)

        return AgentLLMResponse(
            text: response.text,
            toolCalls: textToolCalls,
            finishReason: AgentFinishReason.from(response.finishReason),
            usage: AgentTokenUsage.from(response.usage),
            providerName: response.providerName
        )
    }
}

// MARK: - Finish Reason

public enum AgentFinishReason: String, Sendable, Equatable {

    case stop
    case length
    case contentFilter
    case toolCalls
    case unknown

    public static func from(_ reason: LLMFinishReason?) -> AgentFinishReason {
        guard let reason else { return .unknown }
        switch reason {
        case .stop: return .stop
        case .length: return .length
        case .contentFilter: return .contentFilter
        case .toolCalls: return .toolCalls
        case .unknown: return .unknown
        }
    }
}

// MARK: - Token Usage

public struct AgentTokenUsage: Sendable, Equatable {

    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?

    public init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    public static func from(_ usage: LLMUsage?) -> AgentTokenUsage? {
        guard let usage else { return nil }
        return AgentTokenUsage(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            totalTokens: usage.totalTokens
        )
    }
}

// MARK: - Tool Call Parser

/// Parses tool calls from LLM response text.
///
/// LLMProviderKit doesn't yet parse tool calls from provider responses.
/// This parser supports two formats:
///
/// 1. **Text-marker format** (used by Ollama models without native tool calling):
///    ```
///    TOOL_CALL: tool_name {"param": "value"}
///    ```
///
/// 2. **JSON array format** (used by some models that emit structured JSON):
///    ```json
///    [{"name": "tool_name", "parameters": {"param": "value"}}]
///    ```
///
/// This is generalized from production-proven tool-call parsing logic.
///
public enum ToolCallParser {

    public static func parse(from text: String) -> [AgentToolCall]? {
        var calls: [AgentToolCall] = []

        // Format 1: TOOL_CALL: name {json}
        let toolCallPattern = "TOOL_CALL:\\s*(\\w+)\\s*(\\{[^}]*\\})"
        if let regex = try? NSRegularExpression(pattern: toolCallPattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let nameRange = Range(match.range(at: 1), in: text)!
                let jsonRange = Range(match.range(at: 2), in: text)!
                let name = String(text[nameRange])
                let jsonStr = String(text[jsonRange])

                if let data = jsonStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    var params: [String: AnyCodable] = [:]
                    for (key, value) in parsed {
                        params[key] = AnyCodable(value)
                    }
                    calls.append(AgentToolCall(name: name, parameters: params))
                }
            }
        }

        if !calls.isEmpty { return calls }

        // Format 2: Try parsing the entire text as a JSON array of tool calls
        // (some models emit [{"name": "...", "parameters": {...}}, ...] directly)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            .replacingOccurrences(of: "```json\n", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in parsed {
                guard let name = entry["name"] as? String else { continue }
                let params = (entry["parameters"] as? [String: Any]) ?? (entry["arguments"] as? [String: Any]) ?? [:]
                var codableParams: [String: AnyCodable] = [:]
                for (key, value) in params {
                    codableParams[key] = AnyCodable(value)
                }
                calls.append(AgentToolCall(name: name, parameters: codableParams))
            }
        }

        return calls.isEmpty ? nil : calls
    }
}