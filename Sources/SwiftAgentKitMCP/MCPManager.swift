import Foundation
import SwiftAgentKit
import MCP

/// Manages MCP server connections and bridges discovered tools into `AgentTool`s.
///
/// Usage:
/// ```swift
/// let mcp = MCPManager()
/// try await mcp.connect(.stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]))
/// let tools = try await mcp.bridgedTools()
/// for tool in tools { agent.register(tool) }
/// ```
public actor MCPManager {

    private var connections: [MCPConnection] = []

    public init() {}

    /// Connect to an MCP server using the given configuration.
    @discardableResult
    public func connect(_ config: MCPClientConfig) async throws -> MCPServerInfo {
        let client = Client(name: "SwiftAgentKit", version: "0.3.0-alpha.1")

        let transport: Transport
        var process: Process?

        switch config {
        case .stdio(let command, let args, let env):
            // Spawn the MCP server as a subprocess and pipe its stdio
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: command)
            proc.arguments = args
            if let env { proc.environment = env }

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = Pipe()  // swallow stderr

            try proc.run()

            // StdioTransport takes FileDescriptor — get the write end of stdin
            // and the read end of stdout
            let writeFD = stdinPipe.fileHandleForWriting.fileDescriptor
            let readFD = stdoutPipe.fileHandleForReading.fileDescriptor

            transport = StdioTransport(
                input: .init(rawValue: readFD),
                output: .init(rawValue: writeFD)
            )
            process = proc

        case .http(let endpoint):
            transport = HTTPClientTransport(endpoint: endpoint)
        }

        let result = try await client.connect(transport: transport)
        let info = MCPServerInfo(
            name: result.serverInfo.name,
            version: result.serverInfo.version
        )

        connections.append(MCPConnection(
            client: client,
            transport: transport,
            serverName: result.serverInfo.name,
            config: config,
            process: process
        ))

        return info
    }

    /// Disconnect from a specific MCP server by name.
    public func disconnect(serverName: String) async {
        let toRemove = connections.filter { $0.serverName == serverName }
        for conn in toRemove {
            await conn.client.disconnect()
            conn.process?.terminate()
        }
        connections.removeAll { $0.serverName == serverName }
    }

    /// Disconnect from all MCP servers.
    public func disconnectAll() async {
        for conn in connections {
            await conn.client.disconnect()
            conn.process?.terminate()
        }
        connections.removeAll()
    }

    /// List all discovered tools from all connected MCP servers, bridged as `AgentTool`s.
    public func bridgedTools() async throws -> [any AgentTool] {
        var tools: [any AgentTool] = []
        for conn in connections {
            let (mcpTools, _) = try await conn.client.listTools()
            for tool in mcpTools {
                tools.append(MCPToolBridge(tool: tool, client: conn.client, serverName: conn.serverName))
            }
        }
        return tools
    }

    /// List tool names from all connected servers.
    public func toolNames() async throws -> [String] {
        let tools = try await bridgedTools()
        return tools.map { $0.name }
    }

    /// List connected server names.
    public func connectedServers() -> [String] {
        connections.map { $0.serverName }
    }
}

// MARK: - Internal

private struct MCPConnection {
    let client: Client
    let transport: Transport
    let serverName: String
    let config: MCPClientConfig
    let process: Process?
}