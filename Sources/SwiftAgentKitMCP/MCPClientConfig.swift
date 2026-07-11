import Foundation

/// Configuration for connecting to an MCP server.
public enum MCPClientConfig: Sendable {
    /// Connect to a local MCP server via stdio (subprocess).
    case stdio(command: String, args: [String] = [], env: [String: String]? = nil)
    /// Connect to a remote MCP server via streamable HTTP.
    case http(endpoint: URL)
}

/// Metadata about a discovered MCP server connection.
public struct MCPServerInfo: Sendable {
    public let name: String
    public let version: String
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}