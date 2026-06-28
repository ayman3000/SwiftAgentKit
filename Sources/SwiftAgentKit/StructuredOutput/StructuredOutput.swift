//
//  StructuredOutput.swift
//  SwiftAgentKit
//
//  Structured output extraction — generalized from tolerant JSON parsing patterns.
//
//  Many models don't support native structured outputs / function calling.
//  This module provides a robust "parse JSON from model output" utility that
//  handles:
//  - Markdown code fences (```json ... ```)
//  - Surrounding prose ("Here is the result: {...}")
//  - Brace-matching to extract the first complete JSON object
//  - Decoding into any Codable type
//

import Foundation

/// Extract and decode structured JSON output from LLM responses.
///
/// Usage:
/// ```swift
/// let scene = try StructuredOutput<CanvasScene>.parse(from: response.text)
/// print(scene.value.elements)
/// ```
///
public enum StructuredOutput<T: Decodable> {

    /// Parse a structured output from raw LLM text.
    ///
    /// - Parameter text: The raw LLM response text (may contain markdown fences, prose, etc.)
    /// - Returns: The decoded value
    public static func parse(from text: String) throws -> T {
        let jsonStr = extractJSONObject(from: text) ?? text
        guard let data = jsonStr.data(using: .utf8) else {
            throw StructuredOutputError.invalidJSON(text)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// Parse from an `AgentLLMResponse`.
    public static func parse(from response: AgentLLMResponse) throws -> T {
        try parse(from: response.text)
    }

    /// Extract the first complete JSON object from a string using brace matching.
    ///
    /// Handles:
    /// - Markdown code fences (```json ... ```)
    /// - Surrounding prose before/after the JSON
    /// - Strings containing braces (won't break depth counting)
    /// - Escaped characters in strings
    ///
    public static func extractJSONObject(from raw: String) -> String? {
        var text = raw

        // Strip markdown code fences
        if text.contains("```") {
            if let startRange = text.range(of: "```json\n") {
                text = String(text[startRange.upperBound...])
            } else if let startRange = text.range(of: "```\n") {
                text = String(text[startRange.upperBound...])
            }
            if let endRange = text.range(of: "```") {
                text = String(text[..<endRange.lowerBound])
            }
        }

        guard let startIdx = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var idx = startIdx

        while idx < text.endIndex {
            let char = text[idx]

            if escape {
                escape = false
                idx = text.index(after: idx)
                continue
            }

            if char == "\\" {
                escape = true
                idx = text.index(after: idx)
                continue
            }

            if char == "\"" {
                inString.toggle()
            }

            if !inString {
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[startIdx...idx])
                    }
                }
            }

            idx = text.index(after: idx)
        }

        return nil
    }

    /// Extract a JSON array from a string using bracket matching.
    public static func extractJSONArray(from raw: String) -> String? {
        var text = raw

        // Strip markdown code fences
        if text.contains("```") {
            if let startRange = text.range(of: "```json\n") {
                text = String(text[startRange.upperBound...])
            } else if let startRange = text.range(of: "```\n") {
                text = String(text[startRange.upperBound...])
            }
            if let endRange = text.range(of: "```") {
                text = String(text[..<endRange.lowerBound])
            }
        }

        guard let startIdx = text.firstIndex(of: "[") else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var idx = startIdx

        while idx < text.endIndex {
            let char = text[idx]

            if escape {
                escape = false
                idx = text.index(after: idx)
                continue
            }

            if char == "\\" {
                escape = true
                idx = text.index(after: idx)
                continue
            }

            if char == "\"" {
                inString.toggle()
            }

            if !inString {
                if char == "[" { depth += 1 }
                if char == "]" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[startIdx...idx])
                    }
                }
            }

            idx = text.index(after: idx)
        }

        return nil
    }
}

// MARK: - Errors

public enum StructuredOutputError: Error, LocalizedError {
    case invalidJSON(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let text):
            return "Could not parse JSON from LLM response. Raw text (truncated): \(String(text.prefix(200)))"
        case .notFound:
            return "No JSON object found in the LLM response."
        }
    }
}