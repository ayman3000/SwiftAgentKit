import Foundation

/// Runs a saved routine: fills its inputs, executes its steps through the same
/// dispatcher the model's own calls go through, and stops at the first failure.
///
/// The whole value is that no model runs between the steps. A twelve-call task
/// becomes one call, because the only thinking left is deciding which routine to
/// run and what to put in its blanks.
public struct RunRoutineTool: AgentTool {
    public let name = "run_routine"
    public let description: String
    public let parameters = ToolParameters(
        properties: [
            "name": ToolParameterProperty(type: "string", description: "Which saved routine to run."),
            "inputs": ToolParameterProperty(
                type: "object",
                description: "Values for the routine's inputs, e.g. {\"file\": \"~/notes/q3.md\", \"title\": \"Q3\"}."),
        ],
        required: ["name"])
    public var requiresConfirmation: Bool { false }   // each step inside is gated on its own
    public var inputExamples: [String] { [
        #"""
        {"name": "note-to-word", "inputs": {"text": "Hi Naseem", "filename": "hi_naseem"}}
        """#,
    ] }

    private let store: any RoutineStore
    /// Runs one tool call exactly as if the model had made it, so the approval
    /// gate, the per-conversation permissions and the cost ledger all still apply.
    private let execute: @Sendable (AgentToolCall) async -> AgentToolResult

    public init(store: any RoutineStore, known: [Routine],
                execute: @escaping @Sendable (AgentToolCall) async -> AgentToolResult) {
        self.store = store
        self.execute = execute
        self.description = Self.describe(known)
    }

    static func describe(_ routines: [Routine]) -> String {
        let base = """
        Run a saved routine: proven steps that execute back to back with NO model \
        call between them, so a task that would cost a dozen turns costs one. Prefer \
        this over driving the app yourself whenever a routine covers the request; \
        supply its inputs from what the user asked for. A step that fails stops the \
        routine and reports which one, and you take over from there.
        """
        guard !routines.isEmpty else {
            return base + "\n\nNo routines are saved yet. Once you complete an automation that "
                + "the user is likely to repeat, offer to save it with save_routine."
        }
        let listed = routines.map { r -> String in
            let inputs = r.inputs.isEmpty ? "no inputs"
                : r.inputs.map { $0.name + ($0.required ? "" : "?") }.joined(separator: ", ")
            return "  • \(r.name) — \(r.description) [\(inputs)]"
        }.joined(separator: "\n")
        return base + "\n\nSaved routines:\n" + listed
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let routineName = parameters["name"] as? String, !routineName.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "run_routine requires `name`.")
        }
        let routines = (try? await store.all()) ?? []
        guard let routine = routines.first(where: { $0.name == routineName })
                ?? routines.first(where: { $0.name.caseInsensitiveCompare(routineName) == .orderedSame })
        else {
            let known = routines.map(\.name).joined(separator: ", ")
            return .error(toolCallId: "", toolName: name,
                          message: "No routine named '\(routineName)'."
                          + (known.isEmpty ? " None are saved." : " Saved: \(known)."))
        }

        // Fill the blanks, and refuse rather than act on a missing one.
        let supplied = (parameters["inputs"] as? [String: Any]) ?? [:]
        var values: [String: String] = [:]
        var missing: [String] = []
        for input in routine.inputs {
            if let raw = supplied[input.name], !(raw is NSNull) {
                values[input.name] = String(describing: raw)
            } else if let fallback = input.defaultValue {
                values[input.name] = fallback
            } else if input.required {
                missing.append("\(input.name) (\(input.description))")
            }
        }
        guard missing.isEmpty else {
            return .error(toolCallId: "", toolName: name,
                          message: "Routine '\(routine.name)' needs: \(missing.joined(separator: "; ")). "
                          + "Ask the user for the missing value, or supply it from the conversation.")
        }

        var report: [String] = []
        for (index, step) in routine.steps.enumerated() {
            let filled = step.arguments.mapValues { Routine.substitute($0, with: values) }
            let call = AgentToolCall(name: step.tool, parameters: filled)
            let label = step.note.map { Routine.fill($0, values) } ?? step.tool
            let result = await execute(call)
            if result.isError {
                report.append("\(index + 1). \(label) → FAILED: \(result.result)")
                let rest = routine.steps.count - index - 1
                if rest > 0 { report.append("Stopped; \(rest) step\(rest == 1 ? "" : "s") not run.") }
                return .error(toolCallId: "", toolName: name,
                              message: "Routine '\(routine.name)':\n" + report.joined(separator: "\n"))
            }
            report.append("\(index + 1). \(label) → \(result.result.prefix(160))")
        }
        // Mark it proven: a routine earns trust by finishing, not by being written.
        var proven = routine
        proven.lastSucceededAt = Date()
        try? await store.save(proven)
        return .success(toolCallId: "", toolName: name,
                        result: "Routine '\(routine.name)' completed.\n" + report.joined(separator: "\n"))
    }
}

/// Saves a routine the agent has just proven by running it.
public struct SaveRoutineTool: AgentTool {
    public let name = "save_routine"
    public let description = """
    Save an automation you have just completed successfully, so next time it runs \
    with no model calls between the steps. Only save steps that actually ran and \
    worked — a routine is a proven sequence, not a plan. Replace anything that \
    varies (a filename, a path, a recipient, the text to type) with a {placeholder} \
    and declare it in `inputs`. Target elements by title or identifier, never by a \
    ref like "e42": refs are only valid for one window read.
    """
    public let parameters = ToolParameters(
        properties: [
            "name": ToolParameterProperty(type: "string", description: "Short kebab-case name, e.g. \"note-to-word\"."),
            "description": ToolParameterProperty(type: "string", description: "One line: what it does, so you can pick it later."),
            "inputs": ToolParameterProperty(type: "array", description: "[{name, description, required?}] — the blanks the caller fills."),
            "steps": ToolParameterProperty(type: "array", description: "[{tool, arguments, note?}] in order; strings may contain {placeholders}."),
        ],
        required: ["name", "description", "steps"])
    public var requiresConfirmation: Bool { true }
    public var inputExamples: [String] { [
        #"""
        {"name": "note-to-word", "description": "Write a line in a new Word document and save it to the Desktop", "inputs": [{"name": "text", "description": "What to write"}, {"name": "filename", "description": "Name without extension"}], "steps": [{"tool": "mac_run", "note": "Word: new document, type, save", "arguments": {"bundle_id": "com.microsoft.Word", "read_after": false, "steps": [{"action": "launch"}, {"action": "key", "keys": "cmd+n"}, {"action": "wait", "timeout_seconds": 1}, {"action": "type", "text": "{text}"}, {"action": "key", "keys": "cmd+s"}]}}]}
        """#,
    ] }

    private let store: any RoutineStore

    public init(store: any RoutineStore) { self.store = store }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let routineName = (parameters["name"] as? String)?.trimmingCharacters(in: .whitespaces), !routineName.isEmpty,
              let description = parameters["description"] as? String,
              let rawSteps = parameters["steps"] as? [[String: Any]], !rawSteps.isEmpty
        else {
            return .error(toolCallId: "", toolName: name, message: "save_routine needs `name`, `description` and a non-empty `steps` array.")
        }
        let inputs: [Routine.Input] = ((parameters["inputs"] as? [[String: Any]]) ?? []).compactMap { raw in
            guard let n = raw["name"] as? String, !n.isEmpty else { return nil }
            return Routine.Input(name: n,
                                 description: (raw["description"] as? String) ?? "",
                                 required: (raw["required"] as? Bool) ?? true,
                                 defaultValue: raw["default"] as? String)
        }
        let steps: [Routine.Step] = rawSteps.compactMap { raw in
            guard let tool = raw["tool"] as? String, !tool.isEmpty else { return nil }
            let args = (raw["arguments"] as? [String: Any]) ?? [:]
            return Routine.Step(tool: tool, arguments: args.mapValues(AnyCodable.init), note: raw["note"] as? String)
        }
        guard steps.count == rawSteps.count else {
            return .error(toolCallId: "", toolName: name, message: "Every step needs a `tool` name.")
        }
        let routine = Routine(name: FileRoutineStore.fileSafe(routineName), description: description,
                              inputs: inputs, steps: steps)
        // A placeholder with no input behind it fails halfway through, on the
        // user's machine, having already done part of the job. Catch it here.
        let undeclared = routine.undeclaredPlaceholders
        guard undeclared.isEmpty else {
            return .error(toolCallId: "", toolName: name,
                          message: "These placeholders have no matching input: \(undeclared.joined(separator: ", ")). "
                          + "Declare them in `inputs` or remove the braces.")
        }
        do {
            try await store.save(routine)
            return .success(toolCallId: "", toolName: name,
                            result: "Saved routine '\(routine.name)' with \(steps.count) step(s)"
                            + (inputs.isEmpty ? "." : " and inputs: \(inputs.map(\.name).joined(separator: ", "))."))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Could not save: \(error.localizedDescription)")
        }
    }
}
