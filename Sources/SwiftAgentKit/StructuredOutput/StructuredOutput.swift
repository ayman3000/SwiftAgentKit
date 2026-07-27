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
        let jsonStr = extractJSON(from: text) ?? text
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

    /// Extract the first complete top-level JSON value — object *or* array —
    /// from a string, whichever delimiter appears first.
    ///
    /// This is what `parse` uses, so root-level JSON arrays (`T == [Foo]`) work
    /// as well as objects. Balanced matching skips surrounding prose and markdown
    /// code fences naturally: the scan starts at the first `{`/`[` and stops at
    /// its matching close, so leading ```` ```json ```` and a trailing ```` ``` ````
    /// fall outside the returned range without any fragile fence stripping (which
    /// previously mis-truncated single-line fences and JSON containing ```` ``` ````).
    public static func extractJSON(from raw: String) -> String? {
        let objectStart = raw.firstIndex(of: "{")
        let arrayStart = raw.firstIndex(of: "[")

        switch (objectStart, arrayStart) {
        case let (obj?, arr?):
            return obj < arr
                ? extractBalanced(in: raw, from: obj, open: "{", close: "}")
                : extractBalanced(in: raw, from: arr, open: "[", close: "]")
        case let (obj?, nil):
            return extractBalanced(in: raw, from: obj, open: "{", close: "}")
        case let (nil, arr?):
            return extractBalanced(in: raw, from: arr, open: "[", close: "]")
        case (nil, nil):
            return nil
        }
    }

    /// Extract the first complete JSON object using brace matching.
    public static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        return extractBalanced(in: raw, from: start, open: "{", close: "}")
    }

    /// Extract the first complete JSON array using bracket matching.
    public static func extractJSONArray(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "[") else { return nil }
        return extractBalanced(in: raw, from: start, open: "[", close: "]")
    }

    /// Balanced-delimiter scan honoring JSON string literals and escapes.
    private static func extractBalanced(
        in text: String,
        from startIdx: String.Index,
        open: Character,
        close: Character
    ) -> String? {
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
                if char == open { depth += 1 }
                if char == close {
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