import Testing
import Foundation
@testable import SwiftAgentKit

/// Answers each call from a script, in order, and counts the calls.
private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<AgentToolResult, Error>]
    private var calls = 0
    init(_ answers: [Result<AgentToolResult, Error>]) { self.answers = answers }
    var callCount: Int { lock.withLock { calls } }
    func next() throws -> AgentToolResult {
        let answer: Result<AgentToolResult, Error> = lock.withLock {
            calls += 1
            return answers.isEmpty ? .success(.success(toolCallId: "", toolName: "t", result: "extra")) : answers.removeFirst()
        }
        return try answer.get()
    }
}

private struct ScriptedTool: AgentTool {
    let name: String
    let description = "scripted"
    let parameters = ToolParameters(properties: [:], required: [])
    let readOnly: Bool
    var optOut = false
    let script: Script
    var isReadOnly: Bool { readOnly }
    var retriesTransientFailures: Bool { optOut ? false : readOnly }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult { try script.next() }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [AgentEvent] = []
    func add(_ event: AgentEvent) { lock.withLock { all.append(event) } }
    var retried: [(firstError: String, recovered: Bool)] {
        lock.withLock {
            all.compactMap { event in
                if case let .toolCallRetried(_, firstError, recovered) = event { return (firstError, recovered) }
                return nil
            }
        }
    }
    var finishedCount: Int {
        lock.withLock { all.filter { if case .toolExecutionFinished = $0 { return true }; return false }.count }
    }
}

@Suite struct ToolRetryTests {

    private static func transient(_ message: String) -> Result<AgentToolResult, Error> {
        .success(.transientError(toolCallId: "", toolName: "t", message: message))
    }
    private static func ok(_ text: String) -> Result<AgentToolResult, Error> {
        .success(.success(toolCallId: "", toolName: "t", result: text))
    }

    private func dispatch(_ tool: ScriptedTool, events: Events = Events()) async -> AgentToolResult {
        let registry = ToolRegistry()
        await registry.register(tool)
        let dispatcher = ToolDispatcher(registry: registry)
        await dispatcher.setTransientRetryDelay(.zero)
        let observer = BlockObserver { events.add($0) }
        let results = await dispatcher.dispatch(calls: [AgentToolCall(name: tool.name)],
                                                state: AgentState(), observer: observer)
        return results[0]
    }

    @Test func aReadOnlyToolWithATransientErrorSucceedsOnRetry() async {
        let script = Script([Self.transient("timed out"), Self.ok("page")])
        let events = Events()
        let result = await dispatch(ScriptedTool(name: "read", readOnly: true, script: script), events: events)
        #expect(!result.isError)
        #expect(result.result == "page")
        #expect(result.retryRecovered)
        #expect(script.callCount == 2)
        #expect(events.finishedCount == 1, "the model sees one result, the success")
        #expect(events.retried.map { $0.recovered } == [true])
        #expect(events.retried.map { $0.firstError } == ["timed out"])
    }

    @Test func aToolThatChangesThingsIsNeverRetried() async {
        let script = Script([Self.transient("timed out"), Self.ok("written")])
        let result = await dispatch(ScriptedTool(name: "write", readOnly: false, script: script))
        #expect(result.isError)
        #expect(!result.retryRecovered)
        #expect(script.callCount == 1)
    }

    @Test func aValidationErrorIsNeverRetried() async {
        let script = Script([.success(.error(toolCallId: "", toolName: "t", message: "File not found")), Self.ok("x")])
        let result = await dispatch(ScriptedTool(name: "read", readOnly: true, script: script))
        #expect(result.isError)
        #expect(result.result == "File not found")
        #expect(script.callCount == 1)
    }

    @Test func aThrownTimeoutIsRetried() async {
        let script = Script([.failure(URLError(.timedOut)), Self.ok("page")])
        let result = await dispatch(ScriptedTool(name: "read", readOnly: true, script: script))
        #expect(!result.isError)
        #expect(result.retryRecovered)
        #expect(script.callCount == 2)
    }

    @Test func aFailedRetryReturnsTheOriginalErrorAndRetriesOnlyOnce() async {
        let script = Script([Self.transient("first"), Self.transient("second"), Self.ok("third")])
        let events = Events()
        let result = await dispatch(ScriptedTool(name: "read", readOnly: true, script: script), events: events)
        #expect(result.isError)
        #expect(result.result == "first", "the original error reaches the model unchanged")
        #expect(!result.retryRecovered)
        #expect(script.callCount == 2)
        #expect(events.retried.map { $0.recovered } == [false])
    }

    @Test func aReadOnlyToolCanOptOut() async {
        let script = Script([Self.transient("timed out"), Self.ok("x")])
        let result = await dispatch(ScriptedTool(name: "logs", readOnly: true, optOut: true, script: script))
        #expect(result.isError)
        #expect(script.callCount == 1)
    }

    @Test func transientIsDecidedByTheErrorsType() {
        #expect(ToolRetry.isTransient(URLError(.timedOut)))
        #expect(ToolRetry.isTransient(URLError(.networkConnectionLost)))
        #expect(!ToolRetry.isTransient(URLError(.badURL)))
        #expect(!ToolRetry.isTransient(URLError(.cannotConnectToHost)), "nothing listening is not a blip")
        #expect(!ToolRetry.isTransient(CancellationError()))
        #expect(ToolRetry.isTransient(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))))
        #expect(!ToolRetry.isTransient(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
    }

    @Test func failureCarriesTheErrorsClass() {
        #expect(AgentToolResult.failure(toolCallId: "", toolName: "t", message: "x", error: URLError(.timedOut)).isTransient)
        #expect(!AgentToolResult.failure(toolCallId: "", toolName: "t", message: "x", error: URLError(.badURL)).isTransient)
        #expect(AgentToolResult.failure(toolCallId: "", toolName: "t", message: "x", error: URLError(.badURL)).isError)
    }

    @Test func aResultSavedBeforeTheseFieldsStillDecodes() throws {
        let json = #"{"id":"1","toolCallId":"c","toolName":"t","result":"r","isError":false,"images":[]}"#
        let result = try JSONDecoder().decode(AgentToolResult.self, from: Data(json.utf8))
        #expect(!result.isTransient)
        #expect(!result.retryRecovered)
        #expect(result.result == "r")
    }
}
