import Foundation
import SwiftAgentKit
import MCP

/// Bridges an MCP server tool into SwiftAgentKit's `AgentTool` protocol.
///
/// The bridge holds a reference to the MCP client and the tool metadata.
/// When the agent calls the tool, the bridge forwards the call to the MCP server
/// via `client.callTool(name:arguments:)` and wraps the result.
public struct MCPToolBridge: AgentTool {

    public let name: String
    public let description: String
    public let parameters: ToolParameters
    public let requiresConfirmation: Bool

    private let client: Client
    private let serverName: String

    init(tool: Tool, client: Client, serverName: String) {
        self.name = tool.name
        self.description = tool.description ?? ""
        self.client = client
        self.serverName = serverName
        self.parameters = MCPToolBridge.convertSchema(tool.inputSchema)
        self.requiresConfirmation = false
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        var arguments: [String: Value] = [:]
        for (key, value) in parameters {
            arguments[key] = MCPToolBridge.convertAnyToValue(value)
        }
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)

        // Extract text from content items
        let textParts = content.compactMap { item -> String? in
            if case .text(let text, _, _) = item {
                return text
            }
            return nil
        }
        let result = textParts.joined(separator: "\n")

        if isError ?? false {
            return .error(toolCallId: "", toolName: name, message: result.isEmpty ? "MCP tool error" : result)
        }
        return .success(toolCallId: "", toolName: name, result: result)
    }

    public func execute(context: ToolContext) async throws -> AgentToolResult {
        try await execute(parameters: context.parameters)
    }

    // MARK: - Schema Conversion

    /// Convert an MCP `Value` JSON schema to SwiftAgentKit's `ToolParameters`.
    private static func convertSchema(_ schema: Value?) -> ToolParameters {
        guard let schema else { return .empty }
        guard case .object(let dict) = schema else { return .empty }

        var properties: [String: ToolParameterProperty] = [:]
        var required: [String] = []

        if case .object(let props) = dict["properties"] ?? .null {
            for (key, value) in props {
                if case .object(let propDict) = value {
                    let type = propDict["type"]?.stringValue ?? "string"
                    let desc = propDict["description"]?.stringValue ?? ""
                    let enumValues: [String]? = {
                        guard case .array(let arr) = propDict["enum"] ?? .null else { return nil }
                        return arr.compactMap { $0.stringValue }
                    }()
                    let itemsType: String? = {
                        guard case .object(let items) = propDict["items"] ?? .null else { return nil }
                        return items["type"]?.stringValue
                    }()
                    properties[key] = ToolParameterProperty(
                        type: type,
                        description: desc,
                        enum: enumValues,
                        itemsType: itemsType
                    )
                }
            }
        }

        if case .array(let arr) = dict["required"] ?? .null {
            required = arr.compactMap { $0.stringValue }
        }

        return ToolParameters(properties: properties, required: required)
    }

    /// Convert `Any` to MCP's `Value`.
    private static func convertAnyToValue(_ value: Any) -> Value {
        if let s = value as? String { return .string(s) }
        if let i = value as? Int { return .int(i) }
        if let d = value as? Double { return .double(d) }
        if let b = value as? Bool { return .bool(b) }
        if let arr = value as? [Any] { return .array(arr.map { convertAnyToValue($0) }) }
        if let dict = value as? [String: Any] {
            var v: [String: Value] = [:]
            for (k, val) in dict { v[k] = convertAnyToValue(val) }
            return .object(v)
        }
        return .null
    }
}