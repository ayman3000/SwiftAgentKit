//
//  AgentTool.swift
//  SwiftAgentKit
//
//  The universal tool protocol — extracted from Kommanda's `AITool` and
//  generalized for any Swift AI app.
//
//  Design inspired by Kommanda's proven pattern:
//  - Protocol-defined tools with JSON-Schema parameters
//  - `toJSON()` serializes to OpenAI-compatible function schema
//  - `execute()` returns a `ToolResult` with success/error
//  - Optional `requiresConfirmation` for dangerous operations
//

import Foundation

// MARK: - Tool Protocol

/// A tool that an agent can call.
///
/// Conform to this protocol to define a tool. The agent loop will:
/// 1. Include the tool's schema in the LLM request (if the provider supports tool definitions)
/// 2. Parse tool calls from the LLM response
/// 3. Dispatch the call to `execute(parameters:)`
/// 4. Feed the result back to the model as a tool message
///
/// Example:
/// ```swift
/// struct ReadFileTool: AgentTool {
///     let name = "read_file"
///     let description = "Read the contents of a file at the given path."
///     let parameters = ToolParameters(type: "object", properties: [
///         "path": ToolParameterProperty(type: "string", description: "Absolute file path")
///     ], required: ["path"])
///
///     func execute(parameters: [String: Any]) async throws -> AgentToolResult {
///         let path = parameters["path"] as! String
///         let content = try String(contentsOfFile: path)
///         return .success(toolCallId: "", toolName: name, result: content)
///     }
/// }
/// ```
///
public protocol AgentTool: Sendable {

    /// The tool name (used by the model to call this tool).
    var name: String { get }

    /// Human-readable description of what the tool does.
    /// This is sent to the model — make it clear and specific.
    var description: String { get }

    /// JSON-Schema parameters describing the tool's input.
    var parameters: ToolParameters { get }

    /// Whether this tool requires user confirmation before executing.
    /// Default is `false`. Override for dangerous tools (delete, shell, etc.).
    var requiresConfirmation: Bool { get }

    /// Execute the tool with the given parameters.
    ///
    /// - Parameters:
    ///   - parameters: The decoded parameter values as `[String: Any]`
    /// - Returns: The tool result (success or error)
    func execute(parameters: [String: Any]) async throws -> AgentToolResult

    /// Execute the tool with a rich context (state, call info, actions).
    ///
    /// Default implementation delegates to `execute(parameters:)`.
    /// Override this if your tool needs access to agent state or actions.
    func execute(context: ToolContext) async throws -> AgentToolResult
}

// MARK: - Default Implementation (backward compatible)

public extension AgentTool {
    func execute(context: ToolContext) async throws -> AgentToolResult {
        try await execute(parameters: context.parameters)
    }
}

// MARK: - Default Implementation

public extension AgentTool {
    var requiresConfirmation: Bool { false }
}

// MARK: - Tool Schema Types

/// JSON-Schema parameters for a tool.
///
public struct ToolParameters: Sendable, Equatable, Codable {

    public let type: String          // always "object"
    public let properties: [String: ToolParameterProperty]
    public let required: [String]

    public init(type: String = "object", properties: [String: ToolParameterProperty], required: [String]) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    /// Empty parameters (tool takes no input).
    public static let empty = ToolParameters(properties: [:], required: [])
}

/// A single parameter property in the tool's JSON-Schema.
///
public struct ToolParameterProperty: Sendable, Equatable, Codable {

    public let type: String
    public let description: String
    public let `enum`: [String]?
    public let itemsType: String?       // for array types
    public let defaultValue: String?     // optional default value hint

    public init(
        type: String,
        description: String,
        `enum`: [String]? = nil,
        itemsType: String? = nil,
        defaultValue: String? = nil
    ) {
        self.type = type
        self.description = description
        self.enum = `enum`
        self.itemsType = itemsType
        self.defaultValue = defaultValue
    }

    enum CodingKeys: String, CodingKey {
        case type, description, `enum`, itemsType, defaultValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        description = try container.decode(String.self, forKey: .description)
        `enum` = try container.decodeIfPresent([String].self, forKey: .enum)
        itemsType = try container.decodeIfPresent(String.self, forKey: .itemsType)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(`enum`, forKey: .enum)
        try container.encodeIfPresent(itemsType, forKey: .itemsType)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

// MARK: - Tool JSON Serialization

public extension AgentTool {

    /// Serialize the tool to an OpenAI-compatible function schema.
    ///
    /// This is the format used by OpenAI, Ollama, and most OpenAI-compatible APIs:
    /// ```json
    /// {
    ///   "type": "function",
    ///   "function": {
    ///     "name": "read_file",
    ///     "description": "Read file contents",
    ///     "parameters": { "type": "object", "properties": {...}, "required": [...] }
    ///   }
    /// }
    /// ```
    ///
    func toJSON() -> [String: Any] {
        let encoder = JSONEncoder()
        let paramsData = try? encoder.encode(parameters)
        let paramsJSON = paramsData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]

        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": paramsJSON ?? [:]
            ]
        ]
    }

    /// Serialize to a JSON string (for logging/debugging).
    func toJSONString() -> String {
        let json = toJSON()
        let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - Tool Registry

/// A registry of tools available to an agent.
///
/// Manages tool lookup by name and handles dispatch.
/// Thread-safe via `actor` isolation.
///
public actor ToolRegistry {

    private var tools: [String: any AgentTool] = [:]

    public init() {}

    /// Register a tool.
    public func register(_ tool: any AgentTool) {
        tools[tool.name] = tool
    }

    /// Register multiple tools.
    public func registerAll(_ tools: [any AgentTool]) {
        for tool in tools {
            self.tools[tool.name] = tool
        }
    }

    /// Unregister a tool by name.
    public func unregister(named name: String) {
        tools.removeValue(forKey: name)
    }

    /// Look up a tool by name.
    public func tool(named name: String) -> (any AgentTool)? {
        tools[name]
    }

    /// Get all registered tools.
    public func allTools() -> [any AgentTool] {
        Array(tools.values)
    }

    /// Get all tool names.
    public func allToolNames() -> [String] {
        Array(tools.keys)
    }

    /// Check if a tool is registered.
    public func contains(_ name: String) -> Bool {
        tools[name] != nil
    }

    /// Clear all tools.
    public func clear() {
        tools.removeAll()
    }
}