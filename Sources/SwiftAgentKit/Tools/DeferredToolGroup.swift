import Foundation

/// A set of tools the model doesn't see until it asks for them — an MCP
/// server, say. Its tools stay registered (so they can run), but their
/// definitions aren't sent on every call: the prompt carries one line per group
/// and the model loads a group with `load_tools` when it needs it.
///
/// Measured: one MCP server (chrome-devtools) was 30 tools / 6,769 tokens on
/// every call while used in 2–4% of turns. Same pattern as skills: an index up
/// front, the full thing on demand.
public struct DeferredToolGroup: Sendable, Equatable {
    /// Stable id the model passes to `load_tools` (e.g. an MCP server name).
    public var id: String
    /// One line: what this group lets the assistant do.
    public var description: String
    /// Names of the registered tools that belong to the group.
    public var toolNames: [String]
    /// Send the tools from the start instead (the user always wants them).
    public var alwaysLoaded: Bool

    public init(id: String, description: String, toolNames: [String], alwaysLoaded: Bool = false) {
        self.id = id
        self.description = description
        self.toolNames = toolNames
        self.alwaysLoaded = alwaysLoaded
    }
}

/// Weak handle so a tool can reach its agent without a retain cycle.
final class AgentHandle: @unchecked Sendable {
    weak var agent: Agent?
    init(_ agent: Agent) { self.agent = agent }
}

/// `load_tools`: makes one or more deferred groups' tools available from the
/// next model call on, for the rest of the conversation.
struct LoadToolsTool: AgentTool {
    let handle: AgentHandle
    let name = "load_tools"
    let description = """
        Load the tools of one or more tool groups listed under "Tool groups you can load" \
        in your instructions. Their tools become available from your next step and stay \
        available for the rest of the conversation. Load a group before using its tools; \
        load several at once when a task needs them.
        """
    let parameters = ToolParameters(
        properties: ["groups": ToolParameterProperty(type: "array", description: "Group ids to load, e.g. [\"chrome-devtools\"]", itemsType: "string")],
        required: ["groups"])
    /// Changes nothing outside the conversation, so it batches with reads.
    var isReadOnly: Bool { true }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let ids: [String]
        if let list = parameters["groups"] as? [String] { ids = list }
        else if let one = parameters["groups"] as? String { ids = [one] }
        else { return .error(toolCallId: "", toolName: name, message: "Pass `groups`: a list of group ids.") }
        guard let agent = handle.agent else {
            return .error(toolCallId: "", toolName: name, message: "The agent is gone.")
        }
        return .success(toolCallId: "", toolName: name, result: await agent.loadToolGroups(ids))
    }
}
