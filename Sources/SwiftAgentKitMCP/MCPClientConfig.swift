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
    /// Human-readable name, when the server gives one.
    public let title: String?
    /// The server's own usage notes (MCP `instructions`), when it gives them.
    /// Useful for describing the server in one line; many servers send none.
    public let instructions: String?
    public init(name: String, version: String, title: String? = nil, instructions: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
        self.instructions = instructions
    }
}