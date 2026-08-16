//
//  DelegateTaskTool.swift
//  SwiftAgentKit
//
//  Built-in tool that lets the model delegate a bounded task to a sub-agent.
//  Auto-registered when `AgentConfig.enableSubAgents` is on.
//

import Foundation

/// Delegates a self-contained task to a child agent and returns its final
/// answer as the tool result. Child events are wrapped in
/// `AgentEvent.subAgentEvent` and forwarded to the parent's observers.
public final class DelegateTaskTool: AgentTool, @unchecked Sendable {

    public let name = "delegate_task"

    public let description = """
    Delegate a bounded, self-contained task to a sub-agent that runs it in a \
    fresh context and returns only its final answer. Use for multi-step side \
    tasks (research sweeps, multi-file analysis) whose intermediate steps you \
    don't need to see — they won't consume your context. The sub-agent has \
    your tools but cannot delegate further, and it sees NONE of this \
    conversation: put everything it needs in `prompt`. You may call this \
    multiple times in one turn to run independent tasks in parallel.
    """

    public let parameters = ToolParameters(
        properties: [
            "description": ToolParameterProperty(
                type: "string",
                description: "Short human-readable label for the task (3-8 words), shown in the UI."
            ),
            "prompt": ToolParameterProperty(
                type: "string",
                description: "The complete task for the sub-agent, including all context it needs."
            )
        ],
        required: ["description", "prompt"]
    )

    private let spawner: SubAgentSpawner
    private let emit: @Sendable (AgentEvent) -> Void

    public init(spawner: SubAgentSpawner, emit: @Sendable @escaping (AgentEvent) -> Void) {
        self.spawner = spawner
        self.emit = emit
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let label = parameters["description"] as? String, !label.isEmpty,
              let prompt = parameters["prompt"] as? String, !prompt.isEmpty
        else {
            return .error(
                toolCallId: "",
                toolName: name,
                message: "Error: `description` and `prompt` are both required."
            )
        }

        let id = UUID()

        // Serialize sub-agent execution (default limit 1): parallel children
        // hammering a single model backend cause a load-storm that fails them
        // all. Acquire the gate before spawning/running; release when done.
        await spawner.gate.acquire()
        defer { Task { await spawner.gate.release() } }

        let child = await spawner.makeChild()
        spawner.track(id, child)
        defer { spawner.untrack(id) }

        let forwarder = child.onEvent { [emit] event in
            emit(.subAgentEvent(id: id, event: event))
        }
        defer { child.removeObserver(forwarder) }

        emit(.subAgentStarted(id: id, label: label))
        do {
            // Task cancellation (parent stream cancelled mid-tool) must reach
            // the child's loop, not just this await.
            let answer = try await withTaskCancellationHandler {
                try await child.run(prompt)
            } onCancel: {
                child.markCancelled()
                Task { await child.cancel() }
            }
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                emit(.subAgentFinished(id: id, summary: "(no answer)"))
                return .error(toolCallId: "", toolName: name,
                              message: "Sub-agent returned no answer.")
            }
            emit(.subAgentFinished(id: id, summary: String(trimmed.prefix(200))))
            return .success(toolCallId: "", toolName: name, result: trimmed)
        } catch {
            emit(.subAgentFinished(id: id, summary: "error: \(error.localizedDescription)"))
            return .error(toolCallId: "", toolName: name,
                          message: "Sub-agent failed: \(error.localizedDescription)")
        }
    }
}
