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
    multiple times in one turn to run independent tasks in parallel. If the \
    sub-agent model cannot see images, describe any image yourself in the \
    prompt rather than asking the sub-agent to look at it. When a document \
    has been read with document_digest, give the sub-agent the notes path, \
    not the document.
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

    public var inputExamples: [String] { [
        #"""
        {"description": "Review data layer", "prompt": "Read every file under lib/services in /Users/me/proj and list correctness bugs. For each: file:line, what is wrong, why it matters, and how to confirm it. Report findings only; change nothing."}
        """#
    ] }

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

        emit(.subAgentStarted(id: id, label: label))
        // One try on the sub-agent model; if that model itself fails (not a
        // stop, not out of turns), one more on the parent's — a broken or
        // exhausted cheap model must not sink the task (model roles, 2026-09-26).
        var onParentModel = false
        while true {
            let child = await spawner.makeChild(onParentModel: onParentModel)
            emit(.subAgentModel(id: id, model: child.config.model, fellBack: onParentModel))
            let outcome = await runChild(child, id: id, prompt: prompt)
            switch outcome {
            case .done(let result):
                return result
            case .failed(let error):
                let canFallBack = !onParentModel && spawner.hasDedicatedModel && !Self.isStop(error)
                if canFallBack { onParentModel = true; continue }
                emit(.subAgentFinished(id: id, summary: "error: \(error.localizedDescription)", failed: true))
                return .error(toolCallId: "", toolName: name,
                              message: "Sub-agent failed: \(error.localizedDescription)")
            }
        }
    }

    private enum ChildOutcome { case done(AgentToolResult), failed(any Error) }

    /// A user stop or a cancelled parent is not a model failure — never retried.
    static func isStop(_ error: any Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if case AgentError.cancelled = error { return true }
        return false
    }

    private func runChild(_ child: Agent, id: UUID, prompt: String) async -> ChildOutcome {
        spawner.track(id, child)
        defer { spawner.untrack(id) }
        let forwarder = child.onEvent { [emit] event in
            emit(.subAgentEvent(id: id, event: event))
        }
        defer { child.removeObserver(forwarder) }
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
                emit(.subAgentFinished(id: id, summary: "(no answer)", failed: true))
                return .done(.error(toolCallId: "", toolName: name, message: "Sub-agent returned no answer."))
            }
            emit(.subAgentFinished(id: id, summary: String(trimmed.prefix(200))))
            return .done(.success(toolCallId: "", toolName: name, result: trimmed))
        } catch let error as AgentError {
            // Out of turns is NOT a failed task: the child did real work and may
            // have written its output already. Returning a bare error made the
            // parent re-delegate the same task again and again (observed
            // 2026-09-08: three children, seven minutes, nothing kept). Hand
            // back what it managed, clearly marked as partial.
            if case .maxTurnsReached(let turns) = error {
                let partial = Self.partialReport(child: child, turns: turns)
                emit(.subAgentFinished(id: id, summary: "partial (out of turns)"))
                return .done(.success(toolCallId: "", toolName: name, result: partial))
            }
            return .failed(error)
        } catch {
            return .failed(error)
        }
    }
}

// MARK: - Partial results

extension DelegateTaskTool {
    /// What a child that ran out of turns has to show for itself: its last
    /// words plus the tools it ran, so the parent can use the work (or read a
    /// file the child wrote) instead of delegating the same task again.
    static func partialReport(child: Agent, turns: Int) -> String {
        report(messages: child.conversation.messages, turns: turns)
    }

    /// Pure, for tests.
    static func report(messages: [AgentMessage], turns: Int) -> String {
        let lastText = messages.reversed()
            .first { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .content.trimmingCharacters(in: .whitespacesAndNewlines)

        var tools: [String] = []
        for message in messages {
            for call in message.toolCalls ?? [] where !tools.contains(call.name) {
                tools.append(call.name)
            }
        }

        var out = "PARTIAL RESULT — the sub-agent used all \(turns) of its turns before finishing. "
        out += "This is not a failure to retry blindly: it did the work below, and may already have "
        out += "written its output to a file. Check what exists before delegating this task again; "
        out += "if you do re-delegate, narrow the scope.\n"
        if !tools.isEmpty { out += "\nTools it ran: \(tools.joined(separator: ", ")).\n" }
        if let lastText, !lastText.isEmpty {
            out += "\nIts last words:\n\(lastText.prefix(2000))\n"
        } else {
            out += "\nIt produced no text before running out.\n"
        }
        return out
    }
}
