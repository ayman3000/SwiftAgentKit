import Testing
import Foundation
@testable import SwiftAgentKit

struct RoutineTests {

    private func store() -> FileRoutineStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("routines-\(UUID().uuidString)", isDirectory: true)
        return FileRoutineStore(directory: dir)
    }

    private func noteRoutine() -> Routine {
        Routine(
            name: "note-to-word",
            description: "Write a line in Word and save it",
            inputs: [Routine.Input(name: "text", description: "What to write"),
                     Routine.Input(name: "filename", description: "Name", required: false, defaultValue: "untitled")],
            steps: [Routine.Step(tool: "mac_run", arguments: [
                "bundle_id": AnyCodable("com.microsoft.Word"),
                "steps": AnyCodable([["action": "type", "text": "{text}"],
                                     ["action": "type", "text": "{filename}.docx"]]),
            ], note: "type {text}")])
    }

    // MARK: - Substitution

    @Test func placeholdersAreFilledAtEveryDepth() {
        let step = noteRoutine().steps[0]
        let filled = step.arguments.mapValues { Routine.substitute($0, with: ["text": "Hi", "filename": "note"]) }
        let nested = filled["steps"]?.value as? [[String: Any]]
        #expect(nested?[0]["text"] as? String == "Hi")
        #expect(nested?[1]["text"] as? String == "note.docx", "placeholders inside nested arrays are filled too")
        #expect(filled["bundle_id"]?.value as? String == "com.microsoft.Word")
    }

    @Test func anUnknownPlaceholderIsLeftVisibleRatherThanBlanked() {
        // Blanking would turn "{path}" into "", and a step acting on an empty
        // path is worse than one that visibly fails.
        let filled = Routine.substitute(AnyCodable("rm {path}"), with: [:])
        #expect(filled.value as? String == "rm {path}")
    }

    @Test func undeclaredPlaceholdersAreReported() {
        var routine = noteRoutine()
        #expect(routine.undeclaredPlaceholders.isEmpty)
        routine.inputs = [Routine.Input(name: "text", description: "")]
        #expect(routine.undeclaredPlaceholders == ["filename"])
    }

    // MARK: - Storage

    @Test func routinesRoundTripThroughTheStore() async throws {
        let s = store()
        try await s.save(noteRoutine())
        let back = try await s.all()
        #expect(back.count == 1)
        // createdAt loses its fractional seconds through ISO-8601; the parts
        // that define the routine must survive exactly.
        let saved = try #require(back.first)
        #expect(saved.name == noteRoutine().name)
        #expect(saved.description == noteRoutine().description)
        #expect(saved.inputs == noteRoutine().inputs)
        #expect(saved.steps == noteRoutine().steps)
        try await s.delete(name: "note-to-word")
        #expect(try await s.all().isEmpty)
    }

    @Test func aNameCannotEscapeItsDirectory() {
        #expect(FileRoutineStore.fileSafe("../../etc/passwd") == "etc-passwd")
        #expect(FileRoutineStore.fileSafe("note to word") == "note-to-word")
    }

    // MARK: - Running

    @Test func everyStepRunsInOrderAndTheRoutineIsMarkedProven() async throws {
        let s = store()
        try await s.save(noteRoutine())
        let seen = Recorder()
        let tool = RunRoutineTool(store: s, known: [noteRoutine()]) { call in
            await seen.record(call)
            return .success(toolCallId: call.id, toolName: call.name, result: "ok")
        }
        let result = try await tool.execute(parameters: ["name": "note-to-word", "inputs": ["text": "Hi"]])
        #expect(!result.isError, "\(result.result)")
        #expect(await seen.calls.count == 1)
        // The optional input fell back to its default rather than blocking.
        let steps = await seen.calls.first?.parameters["steps"]?.value as? [[String: Any]]
        #expect(steps?[1]["text"] as? String == "untitled.docx")
        let saved = try await s.all().first
        #expect(saved?.lastSucceededAt != nil, "finishing is what makes a routine proven")
    }

    @Test func aMissingRequiredInputStopsBeforeAnythingRuns() async throws {
        let s = store()
        try await s.save(noteRoutine())
        let seen = Recorder()
        let tool = RunRoutineTool(store: s, known: []) { call in
            await seen.record(call)
            return .success(toolCallId: call.id, toolName: call.name, result: "ok")
        }
        let result = try await tool.execute(parameters: ["name": "note-to-word"])
        #expect(result.isError)
        #expect(result.result.contains("text"))
        #expect(await seen.calls.isEmpty, "nothing may run when an input is missing")
    }

    @Test func aFailedStepStopsTheRoutineAndSaysWhatWasSkipped() async throws {
        let s = store()
        var routine = noteRoutine()
        routine.steps = [routine.steps[0], routine.steps[0], routine.steps[0]]
        try await s.save(routine)
        let seen = Recorder()
        let tool = RunRoutineTool(store: s, known: []) { call in
            await seen.record(call)
            let n = await seen.calls.count
            return n == 2
                ? .error(toolCallId: call.id, toolName: call.name, message: "window went away")
                : .success(toolCallId: call.id, toolName: call.name, result: "ok")
        }
        let result = try await tool.execute(parameters: ["name": "note-to-word", "inputs": ["text": "Hi"]])
        #expect(result.isError)
        #expect(result.result.contains("window went away"))
        #expect(result.result.contains("1 step not run"))
        #expect(await seen.calls.count == 2, "the third step must not run")
        #expect(try await s.all().first?.lastSucceededAt == nil, "a failed run does not prove anything")
    }

    @Test func anUnknownRoutineListsWhatExists() async throws {
        let s = store()
        try await s.save(noteRoutine())
        let tool = RunRoutineTool(store: s, known: []) { _ in .success(toolCallId: "", toolName: "x", result: "") }
        let result = try await tool.execute(parameters: ["name": "nope"])
        #expect(result.isError)
        #expect(result.result.contains("note-to-word"))
    }

    // MARK: - Saving

    @Test func savingRefusesAPlaceholderWithNoInput() async throws {
        let s = store()
        let tool = SaveRoutineTool(store: s)
        let result = try await tool.execute(parameters: [
            "name": "risky", "description": "d",
            "steps": [["tool": "run_shell", "arguments": ["command": "rm {path}"]]],
        ])
        #expect(result.isError)
        #expect(result.result.contains("path"))
        #expect(try await s.all().isEmpty)
    }

    @Test func savedRoutinesAppearInTheToolDescription() {
        let text = RunRoutineTool.describe([noteRoutine()])
        #expect(text.contains("note-to-word"))
        #expect(text.contains("text"))
        #expect(text.contains("filename?"), "an optional input is marked")
        #expect(RunRoutineTool.describe([]).contains("No routines are saved yet"))
    }
}

private actor Recorder {
    var calls: [AgentToolCall] = []
    func record(_ call: AgentToolCall) { calls.append(call) }
}
