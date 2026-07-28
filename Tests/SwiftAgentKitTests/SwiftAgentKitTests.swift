//
//  SwiftAgentKitTests.swift
//  SwiftAgentKit
//
//  Unit tests for SwiftAgentKit — test core types, parsing, memory, and planning
//  without network calls (same strategy as LLMProviderKit tests).
//

import Testing
import Foundation
import LLMProviderKit
import LLMProviderKitOllama
@testable import SwiftAgentKit

// MARK: - AgentMessage Tests

@Test func testAgentMessageCreation() {
    let system = AgentMessage.system("You are helpful")
    #expect(system.role == .system)
    #expect(system.content == "You are helpful")

    let user = AgentMessage.user("Hello")
    #expect(user.role == .user)
    #expect(user.content == "Hello")
    #expect(user.images.isEmpty)

    let assistant = AgentMessage.assistant("Hi there!")
    #expect(assistant.role == .assistant)
    #expect(assistant.content == "Hi there!")

    let toolCall = AgentToolCall(name: "read_file", parameters: ["path": AnyCodable("/tmp/test.txt")])
    let assistantWithTools = AgentMessage.assistant(toolCalls: [toolCall])
    #expect(assistantWithTools.role == .assistant)
    #expect(assistantWithTools.toolCalls?.count == 1)
}

// MARK: - AnyCodable Tests

@Test func testAnyCodableString() {
    let codable = AnyCodable("hello")
    #expect(codable.stringValue == "hello")
}

@Test func testAnyCodableInt() {
    let codable = AnyCodable(42)
    #expect(codable.intValue == 42)
}

@Test func testAnyCodableBool() {
    let codable = AnyCodable(true)
    #expect(codable.boolValue == true)
}

@Test func testAnyCodableDictionary() {
    let codable = AnyCodable(["key": "value", "num": 42])
    let dict = codable.dictValue
    #expect(dict?["key"] as? String == "value")
}

// MARK: - Tool Tests

// Test tool for testing
struct EchoTool: AgentTool {
    let name = "echo"
    let description = "Echoes back the input message."
    let parameters = ToolParameters(
        properties: [
            "message": ToolParameterProperty(type: "string", description: "The message to echo back")
        ],
        required: ["message"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let message = parameters["message"] as? String ?? "no message"
        return .success(toolCallId: "", toolName: name, result: message)
    }
}

struct FailingTool: AgentTool {
    let name = "fail"
    let description = "Always fails."
    let parameters = ToolParameters.empty

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .error(toolCallId: "", toolName: name, message: "Intentional failure")
    }
}

struct DangerousTool: AgentTool {
    let name = "delete_everything"
    let description = "A destructive operation that requires confirmation."
    let parameters = ToolParameters.empty
    var requiresConfirmation: Bool { true }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "done")
    }
}

@Test func testToolToJSON() {
    let tool = EchoTool()
    let json = tool.toJSON()
    #expect(json["type"] as? String == "function")
    let function = json["function"] as? [String: Any]
    #expect(function?["name"] as? String == "echo")
}

@Test func testToolRegistry() async {
    let registry = ToolRegistry()
    await registry.register(EchoTool())
    let found = await registry.tool(named: "echo")
    #expect(found != nil)
    #expect(found?.name == "echo")

    let notFound = await registry.tool(named: "nonexistent")
    #expect(notFound == nil)

    let count = await registry.allTools().count
    #expect(count == 1)
}

@Test func testToolDispatcher() async {
    let registry = ToolRegistry()
    await registry.register(EchoTool())
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    let call = AgentToolCall(name: "echo", parameters: ["message": AnyCodable("hello world")])
    let results = await dispatcher.dispatch(calls: [call], state: state, observer: nil)
    #expect(results.count == 1)
    #expect(results[0].result == "hello world")
    #expect(!results[0].isError)
}

@Test func testToolDispatcherStampsToolCallIdAndName() async {
    let registry = ToolRegistry()
    await registry.register(EchoTool())
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    let call = AgentToolCall(
        id: "call_strict_provider_1",
        name: "echo",
        parameters: ["message": AnyCodable("strict correlation")]
    )

    let results = await dispatcher.dispatch(calls: [call], state: state, observer: nil)

    #expect(results.count == 1)
    #expect(results[0].toolCallId == "call_strict_provider_1")
    #expect(results[0].toolName == "echo")
    #expect(results[0].result == "strict correlation")
}

@Test func testToolDispatcherStampsCallbackInterceptedResult() async {
    let registry = ToolRegistry()
    await registry.register(EchoTool())
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()
    let call = AgentToolCall(id: "call_intercepted", name: "echo", parameters: [:])

    var callbacks = AgentCallbacks()
    callbacks.beforeTool = { _, _ in
        .success(toolCallId: "", toolName: nil, result: "intercepted")
    }

    let results = await dispatcher.dispatch(
        calls: [call],
        state: state,
        callbacks: callbacks,
        observer: nil
    )

    #expect(results.count == 1)
    #expect(results[0].toolCallId == "call_intercepted")
    #expect(results[0].toolName == "echo")
    #expect(results[0].result == "intercepted")
}

@Test func testToolResultsFanOutToSeparateLLMMessages() {
    let message = AgentMessage.tool(results: [
        .success(toolCallId: "call_1", toolName: "first_tool", result: "first result"),
        .success(toolCallId: "call_2", toolName: "second_tool", result: "second result")
    ])

    let llmMessages = message.toLLMMessages()

    #expect(llmMessages.count == 2)
    #expect(llmMessages[0].role == .tool)
    #expect(llmMessages[0].toolCallId == "call_1")
    #expect(llmMessages[0].content.contains("first_tool"))
    #expect(llmMessages[0].content.contains("first result"))
    #expect(llmMessages[1].role == .tool)
    #expect(llmMessages[1].toolCallId == "call_2")
    #expect(llmMessages[1].content.contains("second_tool"))
    #expect(llmMessages[1].content.contains("second result"))
}

@Test func testProviderMetadataSurvivesToolCallBridge() {
    let request = LLMRequest(model: "gemini-2.5-flash", messages: [.user("What time is it?")])
    let response = LLMResponse(
        text: "",
        finishReason: .toolCalls,
        toolCalls: [
            LLMToolCall(
                id: "current_datetime",
                name: "current_datetime",
                arguments: "{}",
                providerMetadata: ["gemini.thoughtSignature": "signed-part-token"]
            )
        ],
        request: request,
        providerName: "gemini"
    )

    let agentResponse = AgentLLMResponse.from(response)
    let agentToolCall = try! #require(agentResponse.toolCalls?.first)
    #expect(agentToolCall.providerMetadata["gemini.thoughtSignature"] == "signed-part-token")

    let assistantMessage = AgentMessage.assistant(content: "", toolCalls: [agentToolCall])
    let llmToolCall = try! #require(assistantMessage.toLLMMessage().toolCalls?.first)
    #expect(llmToolCall.providerMetadata["gemini.thoughtSignature"] == "signed-part-token")
}

@Test func testToolDispatcherNotFound() async {
    let registry = ToolRegistry()
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    let call = AgentToolCall(name: "nonexistent", parameters: [:])
    let results = await dispatcher.dispatch(calls: [call], state: state, observer: nil)
    #expect(results.count == 1)
    #expect(results[0].isError)
}

@Test func testToolDispatcherDedup() async {
    let registry = ToolRegistry()
    await registry.register(EchoTool())
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    let call = AgentToolCall(name: "echo", parameters: ["message": AnyCodable("dup")])
    let results = await dispatcher.dispatch(calls: [call, call], state: state, parallel: false, observer: nil)
    #expect(results.count == 2)
    #expect(results[0].isError == false) // First succeeds
    #expect(results[1].isError == true)  // Second is deduped
}

@Test func testConfirmationRequiredFailsClosedWithoutHandler() async {
    let registry = ToolRegistry()
    await registry.register(DangerousTool())
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    let call = AgentToolCall(name: "delete_everything")
    // No onToolConfirmation handler and autonomous mode is off → fail closed.
    let results = await dispatcher.dispatch(calls: [call], state: state, observer: nil)
    #expect(results.count == 1)
    #expect(results[0].isError == true)
    #expect(results[0].result.contains("requires confirmation"))
}

@Test func testConfirmationRequiredRunsWhenApproved() async {
    let registry = ToolRegistry()
    await registry.register(DangerousTool())
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    var callbacks = AgentCallbacks()
    callbacks.onToolConfirmation = { _, _ in true }

    let call = AgentToolCall(name: "delete_everything")
    let results = await dispatcher.dispatch(calls: [call], state: state, callbacks: callbacks, observer: nil)
    #expect(results.count == 1)
    #expect(results[0].isError == false)
    #expect(results[0].result == "done")
}

@Test func testConfirmationRequiredDeniedByHandler() async {
    let registry = ToolRegistry()
    await registry.register(DangerousTool())
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    var callbacks = AgentCallbacks()
    callbacks.onToolConfirmation = { _, _ in false }

    let call = AgentToolCall(name: "delete_everything")
    let results = await dispatcher.dispatch(calls: [call], state: state, callbacks: callbacks, observer: nil)
    #expect(results.count == 1)
    #expect(results[0].isError == true)
    #expect(results[0].result.contains("not approved"))
}

@Test func testAutonomousModeBypassesConfirmationGate() async {
    let registry = ToolRegistry()
    await registry.register(DangerousTool())
    let dispatcher = ToolDispatcher(registry: registry)
    await dispatcher.setAutonomousMode(true)
    let state = AgentState()

    // No onToolConfirmation handler, but autonomous mode is on → runs anyway.
    let call = AgentToolCall(name: "delete_everything")
    let results = await dispatcher.dispatch(calls: [call], state: state, observer: nil)
    #expect(results.count == 1)
    #expect(results[0].isError == false)
    #expect(results[0].result == "done")
}

// MARK: - Conversation/Memory Tests

@Test func testConversationAppendAndRead() {
    let conv = Conversation(contextWindow: 8192, maxMessages: 10)
    conv.append(.system("system prompt"))
    conv.append(.user("hello"))
    conv.append(.assistant("hi"))

    let all = conv.allMessages()
    #expect(all.count == 3)
    #expect(all[0].role == .system)
    #expect(all[1].role == .user)
    #expect(all[2].role == .assistant)
}

@Test func testConversationTrim() {
    let conv = Conversation(contextWindow: 8192, maxMessages: 5)
    conv.append(.system("system"))
    for i in 0..<10 {
        conv.append(.user("message \(i)"))
    }

    let (removed, remaining) = conv.trim()
    #expect(remaining <= 5)
    #expect(removed > 0)

    // System message should be preserved
    let all = conv.allMessages()
    #expect(all.first?.role == .system)
}

@Test func testTrimPreservesToolCallResultPairing() {
    // Small caps force trimming across several tool-using turns.
    let conv = Conversation(contextWindow: 8192, maxMessages: 4)
    conv.append(.system("system"))
    for i in 0..<6 {
        let call = AgentToolCall(id: "call_\(i)", name: "echo", parameters: ["n": AnyCodable(i)])
        conv.append(.assistant(content: "", toolCalls: [call]))
        conv.append(.tool(results: [.success(toolCallId: "call_\(i)", toolName: "echo", result: "r\(i)")]))
    }

    _ = conv.trim()
    let all = conv.allMessages()

    // Every retained tool-result message must be immediately preceded by an
    // assistant message that issued tool calls (no orphaned tool results).
    for (idx, msg) in all.enumerated() where msg.role == .tool {
        #expect(idx > 0)
        let prev = all[idx - 1]
        #expect(prev.role == .assistant)
        #expect((prev.toolCalls?.isEmpty == false))
    }
    // And no assistant tool_call turn is left without its following tool result.
    for (idx, msg) in all.enumerated() where msg.role == .assistant && (msg.toolCalls?.isEmpty == false) {
        #expect(idx + 1 < all.count)
        #expect(all[idx + 1].role == .tool)
    }
}

@Test func testConversationTokenEstimation() {
    let conv = Conversation()
    let message = AgentMessage.user("This is a test message with some content")
    let tokens = conv.estimateTokens(message)
    #expect(tokens > 0)
    #expect(tokens < 20) // ~40 chars / 3.5 + overhead ≈ 16 tokens
}

@Test func testTokenCounterOverrideIsUsed() {
    let conv = Conversation()
    conv.tokenCounter = { _ in 999 }
    #expect(conv.estimateTokens(.user("anything")) == 999)
    #expect(conv.estimateTotalTokens([.user("a"), .user("b")]) == 1998)
}

@Test func testHeuristicIncludesPerMessageOverhead() {
    let conv = Conversation()
    conv.charsPerToken = 4.0
    conv.tokensPerMessageOverhead = 5
    // 8 chars / 4 = 2, plus 5 overhead = 7
    #expect(conv.estimateTokens(.user("12345678")) == 7)
}

@Test func testConversationClear() {
    let conv = Conversation()
    conv.append(.user("test"))
    conv.clear()
    #expect(conv.allMessages().isEmpty)
}

@Test func testConversationSetSystemMessage() {
    let conv = Conversation()
    conv.append(.user("hello"))
    conv.setSystemMessage(.system("new system"))
    let all = conv.allMessages()
    #expect(all.count == 2)
    #expect(all[0].role == .system)
    #expect(all[0].content == "new system")
}

// MARK: - StructuredOutput Tests

// Test types for structured output
struct TestScene: Codable, Equatable {
    let title: String
    let items: [String]
}

@Test func testStructuredOutputParse() throws {
    let json = """
    Here is the result:
    ```json
    {"title": "Test Scene", "items": ["a", "b", "c"]}
    ```
    """//.trimmingCharacters(in: .newlines)

    let scene = try StructuredOutput<TestScene>.parse(from: json)
    #expect(scene.title == "Test Scene")
    #expect(scene.items.count == 3)
}

@Test func testStructuredOutputParseNoFence() throws {
    let json = #"{"title": "Plain", "items": ["x"]}"#
    let scene = try StructuredOutput<TestScene>.parse(from: json)
    #expect(scene.title == "Plain")
}

@Test func testStructuredOutputExtractJSONObject() {
    let text = "Some prose before {\"key\": \"value\"} some prose after"
    let json = StructuredOutput<TestScene>.extractJSONObject(from: text)
    #expect(json != nil)
    #expect(json?.contains("key") == true)
}

@Test func testStructuredOutputExtractWithNestedBraces() {
    let text = #"{"title": "Test", "items": ["a{b}c"]}"#
    let json = StructuredOutput<TestScene>.extractJSONObject(from: text)
    #expect(json != nil)
}

@Test func testStructuredOutputParseSingleLineFence() throws {
    // Opening fence with no trailing newline used to defeat fence stripping.
    let json = #"```json {"title": "Inline", "items": ["a"]} ```"#
    let scene = try StructuredOutput<TestScene>.parse(from: json)
    #expect(scene.title == "Inline")
    #expect(scene.items == ["a"])
}

@Test func testStructuredOutputParseJSONContainingBackticks() throws {
    // A string value containing ``` must not truncate extraction.
    let json = #"{"title": "```code```", "items": ["x"]}"#
    let scene = try StructuredOutput<TestScene>.parse(from: json)
    #expect(scene.title == "```code```")
}

@Test func testStructuredOutputParseRootArray() throws {
    let json = """
    Here you go:
    ```json
    [{"title": "One", "items": []}, {"title": "Two", "items": ["z"]}]
    ```
    """
    let scenes = try StructuredOutput<[TestScene]>.parse(from: json)
    #expect(scenes.count == 2)
    #expect(scenes[0].title == "One")
    #expect(scenes[1].items == ["z"])
}

// MARK: - Planning Tests

@Test func testAgentPlanStep() {
    var step = AgentPlanStep(step: "Read the file")
    #expect(step.status == .pending)

    step.status = .completed
    #expect(step.status == .completed)
}

@Test func testAgentPlan() {
    let plan = AgentPlan(steps: [
        AgentPlanStep(step: "Step 1"),
        AgentPlanStep(step: "Step 2"),
        AgentPlanStep(step: "Step 3")
    ])
    #expect(plan.steps.count == 3)
    #expect(plan.hasPendingSteps == true)
    #expect(plan.pendingSteps.count == 3)
    #expect(plan.completedCount == 0)
    #expect(plan.progress == 0.0)
}

@Test func testAgentPlanProgress() {
    let plan = AgentPlan(steps: [
        AgentPlanStep(step: "Step 1", status: .completed),
        AgentPlanStep(step: "Step 2", status: .pending),
        AgentPlanStep(step: "Step 3", status: .completed)
    ])
    #expect(plan.hasPendingSteps == true)
    #expect(plan.completedCount == 2)
    #expect(plan.progress > 0.6 && plan.progress < 0.7)
}

@Test func testUpdateProgressAdvancesTargetlessPlan() {
    // LLM-generated steps default to empty `targets`; progress must still advance.
    let planner = LLMPlanner(provider: ToolAwareMockProvider())
    var plan = AgentPlan(steps: [
        AgentPlanStep(step: "Step 1"),
        AgentPlanStep(step: "Step 2")
    ])
    #expect(plan.progress == 0.0)

    let ok = AgentToolResult.success(toolCallId: "c1", toolName: "echo", result: "done")
    planner.updateProgress(plan: &plan, toolCall: AgentToolCall(id: "c1", name: "echo"), result: ok)
    #expect(plan.completedCount == 1)

    planner.updateProgress(plan: &plan, toolCall: AgentToolCall(id: "c2", name: "echo"), result: ok)
    #expect(plan.completedCount == 2)
    #expect(plan.hasPendingSteps == false)

    // An error must not advance the plan.
    var plan2 = AgentPlan(steps: [AgentPlanStep(step: "Only step")])
    let err = AgentToolResult.error(toolCallId: "c3", toolName: "echo", message: "boom")
    planner.updateProgress(plan: &plan2, toolCall: AgentToolCall(id: "c3", name: "echo"), result: err)
    #expect(plan2.completedCount == 0)
}

// MARK: - Plan Parsing Tests

@Test func testParsePlanStepsFromJSON() throws {
    let json = #"{"steps": ["Read file", "Process contents", "Write output"]}"#
    let steps = try LLMPlanner.parsePlanSteps(from: json)
    #expect(steps.count == 3)
    #expect(steps[0] == "Read file")
}

@Test func testParsePlanStepsFromMarkdownFence() throws {
    let text = """
    ```json
    {"steps": ["Step A", "Step B"]}
    ```
    """//.trimmingCharacters(in: .whitespacesAndNewlines)

    let steps = try LLMPlanner.parsePlanSteps(from: text)
    #expect(steps.count == 2)
}

@Test func testParsePlanStepsFallback() throws {
    let text = """
    1. First step
    2. Second step
    3. Third step
    """//.trimmingCharacters(in: .newlines)

    let steps = try LLMPlanner.parsePlanSteps(from: text)
    #expect(steps.count == 3)
}

// MARK: - RepairRetryPolicy Tests

@Test func testRepairRetryShouldRetry() {
    let policy = RepairRetryPolicy(maxAttempts: 3)
    let errors = [AgentToolResult.error(toolCallId: "1", toolName: "test", message: "failed")]

    #expect(policy.shouldRetry(repairableErrors: errors, attemptsUsed: 0, turnsRemaining: 5) == true)
    #expect(policy.shouldRetry(repairableErrors: errors, attemptsUsed: 3, turnsRemaining: 5) == false)
    #expect(policy.shouldRetry(repairableErrors: [], attemptsUsed: 0, turnsRemaining: 5) == false)
    #expect(policy.shouldRetry(repairableErrors: errors, attemptsUsed: 0, turnsRemaining: 0) == false)
}

@Test func testRepairRetryNudge() {
    let policy = RepairRetryPolicy()
    let errors = [
        AgentToolResult.error(toolCallId: "1", toolName: "write_file", message: "Permission denied")
    ]
    let nudge = policy.nudge(for: errors)
    #expect(nudge.contains("write_file"))
    #expect(nudge.contains("Permission denied"))
    #expect(nudge.contains("retry"))
}

// MARK: - PlanContinuationPolicy Tests

@Test func testPlanContinuationShouldContinue() {
    let policy = PlanContinuationPolicy(maxAttempts: 10)
    let plan = AgentPlan(steps: [
        AgentPlanStep(step: "Step 1", status: .completed),
        AgentPlanStep(step: "Step 2", status: .pending)
    ])

    #expect(policy.shouldContinue(plan: plan, attemptsUsed: 0, turnsRemaining: 5) == true)
    #expect(policy.shouldContinue(plan: plan, attemptsUsed: 10, turnsRemaining: 5) == false)

    let completedPlan = AgentPlan(steps: [
        AgentPlanStep(step: "Step 1", status: .completed)
    ])
    #expect(policy.shouldContinue(plan: completedPlan, attemptsUsed: 0, turnsRemaining: 5) == false)
}

// MARK: - ToolCallParser Tests

@Test func testToolCallParserTextMarker() {
    let text = #"TOOL_CALL: read_file {"path": "/tmp/test.txt"}"#
    let calls = ToolCallParser.parse(from: text)
    #expect(calls?.count == 1)
    #expect(calls?[0].name == "read_file")
    #expect(calls?[0].parameters["path"]?.stringValue == "/tmp/test.txt")
}

@Test func testToolCallParserNone() {
    let text = "This is just a normal response with no tool calls."
    let calls = ToolCallParser.parse(from: text)
    #expect(calls == nil)
}

// MARK: - AgentError Tests

@Test func testAgentErrorDescriptions() {
    let error = AgentError.toolNotFound("read_file")
    #expect(error.errorDescription?.contains("read_file") == true)

    let maxTurns = AgentError.maxTurnsReached(10)
    #expect(maxTurns.errorDescription?.contains("10") == true)
}

// MARK: - AgentState Tests

@Test func testAgentStateSetGet() {
    let state = AgentState()
    state.setValue("hello", forKey: "greeting")
    #expect(state.string(forKey: "greeting") == "hello")
    #expect(state.string(forKey: "missing") == nil)
}

@Test func testAgentStateTypes() {
    let state = AgentState()
    state.setValue(42, forKey: "count")
    state.setValue(3.14, forKey: "pi")
    state.setValue(true, forKey: "flag")
    #expect(state.int(forKey: "count") == 42)
    #expect(state.double(forKey: "pi") == 3.14)
    #expect(state.bool(forKey: "flag") == true)
}

@Test func testAgentStateRemove() {
    let state = AgentState()
    state.setValue("temp", forKey: "temp:key")
    state.setValue("perm", forKey: "perm")
    state.removeValue(forKey: "temp:key")
    #expect(state.value(forKey: "temp:key") == nil)
    #expect(state.string(forKey: "perm") == "perm")
}

@Test func testAgentStateClearTemp() {
    let state = AgentState()
    state.setValue("a", forKey: "temp:cache")
    state.setValue("b", forKey: "session:data")
    state.clearTemp()
    #expect(state.value(forKey: "temp:cache") == nil)
    #expect(state.string(forKey: "session:data") == "b")
}

@Test func testAgentStateClearAll() {
    let state = AgentState()
    state.setValue("a", forKey: "key1")
    state.setValue("b", forKey: "key2")
    state.clearAll()
    #expect(state.snapshot().isEmpty)
}

@Test func testAgentStateTemplate() {
    let state = AgentState()
    state.setValue("World", forKey: "name")
    state.setValue("Swift", forKey: "lang")
    let result = state.template("Hello {name}, welcome to {lang}!")
    #expect(result == "Hello World, welcome to Swift!")
}

@Test func testAgentStateSnapshot() {
    let state = AgentState()
    state.setValue("a", forKey: "key1")
    state.setValue("b", forKey: "key2")
    let snap = state.snapshot()
    #expect(snap.count == 2)
    #expect(snap["key1"] as? String == "a")
}

@Test func testAgentStateMutateIsAtomicUnderConcurrency() async {
    let state = AgentState()
    let n = 2000
    // Many concurrent read-modify-write increments — atomic `mutate` must not
    // lose any (a naive get-then-set would).
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<n {
            group.addTask { state.mutate(forKey: "count", default: 0) { $0 += 1 } }
        }
    }
    #expect(state.int(forKey: "count") == n)
}

@Test func testAgentStateConcurrentAccessIsSafe() async {
    let state = AgentState()
    // Hammer reads, writes, snapshots, and mutates concurrently — must not crash
    // or corrupt (proves the internal lock covers every path).
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<600 {
            group.addTask { state.setValue(i, forKey: "k\(i % 8)") }
            group.addTask { _ = state.snapshot() }
            group.addTask { _ = state.value(forKey: "k\(i % 8)") }
            group.addTask { state.mutate(forKey: "hits", default: 0) { $0 += 1 } }
        }
    }
    #expect(state.int(forKey: "hits") == 600)
    #expect(state.snapshot().keys.count <= 9)  // k0…k7 + hits
}

// MARK: - ToolContext Tests

@Test func testToolContextAccess() {
    let state = AgentState()
    state.setValue("user123", forKey: "user:id")

    let context = ToolContext(
        callId: "call-1",
        toolName: "read_file",
        parameters: ["path": "/tmp/test.txt"],
        state: state,
        turn: 3,
        query: "Read the file"
    )

    #expect(context.callId == "call-1")
    #expect(context.toolName == "read_file")
    #expect(context.parameters["path"] as? String == "/tmp/test.txt")
    #expect(context.turn == 3)
    #expect(context.query == "Read the file")
    #expect(context.state.string(forKey: "user:id") == "user123")
}

@Test func testToolContextStateReadWrite() {
    let state = AgentState()
    let context = ToolContext(
        callId: "call-1", toolName: "test", parameters: [:], state: state
    )

    context.state.setValue("processed", forKey: "temp:status")
    #expect(context.state.string(forKey: "temp:status") == "processed")
}

@Test func testToolActions() {
    let actions = ToolActions(skipSummarization: true, shouldStop: false, shouldRetry: true)
    #expect(actions.skipSummarization == true)
    #expect(actions.shouldStop == false)
    #expect(actions.shouldRetry == true)
}

// MARK: - AgentCallbacks Tests

@Test func testAgentCallbacksCreation() {
    let callbacks = AgentCallbacks()
    #expect(callbacks.beforeAgent == nil)
    #expect(callbacks.afterAgent == nil)
    #expect(callbacks.beforeModel == nil)
    #expect(callbacks.afterModel == nil)
    #expect(callbacks.beforeTool == nil)
    #expect(callbacks.afterTool == nil)
    #expect(callbacks.onModelError == nil)
    #expect(callbacks.onToolError == nil)
}

// MARK: - Tool with ToolContext Tests

struct StatefulTool: AgentTool {
    let name = "save_value"
    let description = "Save a value to agent state."
    let parameters = ToolParameters(
        properties: [
            "key": ToolParameterProperty(type: "string", description: "State key"),
            "value": ToolParameterProperty(type: "string", description: "Value to store")
        ],
        required: ["key", "value"]
    )

    // Override the context-based execute to access state
    func execute(context: ToolContext) async throws -> AgentToolResult {
        let key = context.parameters["key"] as? String ?? ""
        let value = context.parameters["value"] as? String ?? ""
        context.state.setValue(value, forKey: key)
        return .success(toolCallId: context.callId, toolName: name, result: "Saved \(value) to \(key)")
    }

    // Required by protocol but not used (context-based execute takes priority)
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "Use context version")
    }
}

@Test func testToolWithContextCanWriteState() async {
    let registry = ToolRegistry()
    await registry.register(StatefulTool())
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    let call = AgentToolCall(
        name: "save_value",
        parameters: ["key": AnyCodable("user:name"), "value": AnyCodable("Alex")]
    )
    let results = await dispatcher.dispatch(calls: [call], state: state, observer: nil)

    #expect(results.count == 1)
    #expect(!results[0].isError)
    #expect(state.string(forKey: "user:name") == "Alex")
}

// MARK: - Parallel Tool Execution Tests

/// Records each tool's [start, end] interval so a test can prove parallelism
/// deterministically (overlapping intervals) instead of via a flaky wall clock.
actor OverlapRecorder {
    private(set) var intervals: [(start: Date, end: Date)] = []
    func record(_ start: Date, _ end: Date) { intervals.append((start, end)) }
}

struct DelayTool: AgentTool {
    let name: String
    var recorder: OverlapRecorder? = nil
    let description = "Echoes with a small delay."
    let parameters = ToolParameters(
        properties: ["msg": ToolParameterProperty(type: "string", description: "Message")],
        required: ["msg"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let start = Date()
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        await recorder?.record(start, Date())
        let msg = parameters["msg"] as? String ?? ""
        return .success(toolCallId: "", toolName: name, result: msg)
    }
}

@Test func testParallelToolExecution() async {
    let recorder = OverlapRecorder()
    let registry = ToolRegistry()
    await registry.register(DelayTool(name: "delay1", recorder: recorder))
    await registry.register(DelayTool(name: "delay2", recorder: recorder))
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    let call1 = AgentToolCall(name: "delay1", parameters: ["msg": AnyCodable("a")])
    let call2 = AgentToolCall(name: "delay2", parameters: ["msg": AnyCodable("b")])

    let results = await dispatcher.dispatch(calls: [call1, call2], state: state, parallel: true, observer: nil)
    #expect(results.count == 2)

    // Deterministic parallelism check: the two executions overlapped in time
    // (machine-speed independent), rather than a flaky wall-clock threshold.
    let intervals = await recorder.intervals
    #expect(intervals.count == 2)
    if intervals.count == 2 {
        let (a, b) = (intervals[0], intervals[1])
        #expect(a.start < b.end && b.start < a.end, "tool executions should overlap when run in parallel")
    }
}

@Test func testAgentSkillMatches() {
    let skill = AgentSkill(
        name: "chart",
        triggerKeywords: ["chart", "graph", "plot"],
        instructions: "Use Charts framework."
    )
    #expect(skill.matches("Create a bar chart of sales") == true)
    #expect(skill.matches("Read this file") == false)
}

@Test func testAgentSkillRender() {
    let skill = AgentSkill(
        name: "scaffold",
        triggerKeywords: ["scaffold", "new project"],
        instructions: "Ask for project name first."
    )
    let rendered = skill.render()
    #expect(rendered.contains("scaffold"))
    #expect(rendered.contains("Ask for project name"))
}

@Test func testSkillRegistryMatching() async {
    let registry = SkillRegistry()
    await registry.register(AgentSkill(
        name: "chart",
        triggerKeywords: ["chart", "graph"],
        instructions: "Chart instructions."
    ))
    await registry.register(AgentSkill(
        name: "scaffold",
        triggerKeywords: ["scaffold", "new project"],
        instructions: "Scaffold instructions."
    ))

    let matched = await registry.matchingSkills(for: "Create a chart")
    #expect(matched.count == 1)
    #expect(matched[0].name == "chart")
}

@Test func testSkillRegistryNoMatch() async {
    let registry = SkillRegistry()
    await registry.register(AgentSkill(
        name: "chart",
        triggerKeywords: ["chart"],
        instructions: "Chart instructions."
    ))

    let matched = await registry.matchingSkills(for: "Read a file")
    #expect(matched.isEmpty)
}

@Test func testSkillRegistryPromptAugmentation() async {
    let registry = SkillRegistry()
    await registry.register(AgentSkill(
        name: "chart",
        triggerKeywords: ["chart"],
        instructions: "Use Charts framework."
    ))

    let aug = await registry.systemPromptAugmentation(for: "Make a chart")
    #expect(aug.contains("chart"))
    #expect(aug.contains("Charts framework"))

    let noAug = await registry.systemPromptAugmentation(for: "Read a file")
    #expect(noAug.isEmpty)
}

@Test func testSkillRegistryTierFilter() async {
    let registry = SkillRegistry()
    await registry.register(AgentSkill(
        name: "free-skill",
        triggerKeywords: ["test"],
        instructions: "Free."
    ))
    await registry.register(AgentSkill(
        name: "pro-skill",
        triggerKeywords: ["test"],
        instructions: "Pro.",
        tier: "pro"
    ))

    // No filter → both match
    let allMatched = await registry.matchingSkills(for: "test something")
    #expect(allMatched.count == 2)

    // Pro filter → only pro skill + tierless skills
    await registry.setTierFilter("pro")
    let proMatched = await registry.matchingSkills(for: "test something")
    #expect(proMatched.count == 2) // free-skill has no tier → included; pro-skill has tier pro → included
}
// MARK: - Agent Registration Race Regression

final class AgentMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct ToolAwareMockProvider: LLMProvider {
    static let name = "tool-aware-mock"

    let configuration = LLMProviderConfiguration(
        name: ToolAwareMockProvider.name,
        baseURL: URL(string: "https://mock.local")!,
        apiKey: nil,
        defaultModel: "mock"
    )

    let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentMockURLProtocol.self]
        return URLSession(configuration: config)
    }()

    func prepareRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        URLRequest(url: URL(string: "https://mock.local/chat")!)
    }

    func parseStreamLine(_ line: String, request: LLMRequest) throws -> [LLMStreamChunk] { [] }

    func parseResponse(_ data: Data, request: LLMRequest) throws -> LLMResponse {
        if request.messages.contains(where: { $0.role == .user && $0.content.contains("Do you know me?") }) {
            let systemPrompt = request.messages.first(where: { $0.role == .system })?.content ?? ""
            return LLMResponse(
                text: systemPrompt,
                finishReason: .stop,
                request: request,
                providerName: Self.name
            )
        }

        if let toolMessage = request.messages.last(where: { $0.role == .tool }) {
            return LLMResponse(
                text: "final tool result: \(toolMessage.content)",
                finishReason: .stop,
                request: request,
                providerName: Self.name
            )
        }

        if request.tools.contains(where: { $0.name == "echo" }) {
            return LLMResponse(
                text: "",
                finishReason: .toolCalls,
                toolCalls: [LLMToolCall(name: "echo", arguments: "{\"message\":\"race-proof\"}")],
                request: request,
                providerName: Self.name
            )
        }

        return LLMResponse(
            text: "missing tools in request",
            finishReason: .stop,
            request: request,
            providerName: Self.name
        )
    }
}

@Test func testAgentInjectsPersistentMemoryIntoSystemPrompt() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-memory-injection-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = FileAgentMemoryStore(directory: directory)
    try await store.save(AgentMemoryEntry(kind: .user, title: "Name", content: "Ayman"))

    let agent = Agent(config: AgentConfig(
        provider: ToolAwareMockProvider(),
        model: "mock",
        systemPrompt: "You are helpful.",
        maxTurns: 1
    ))
    agent.memoryStore = store

    let output = try await agent.run("Do you know me?")
    #expect(output.contains("Ayman"))
    #expect(output.contains("MEMORY"))
}

@Test func testAgentAwaitsImmediateToolRegistrationBeforeRun() async throws {
    let agent = Agent(config: AgentConfig(provider: ToolAwareMockProvider(), model: "mock", maxTurns: 3))
    agent.register(EchoTool())

    let output = try await agent.run("Use echo tool now")

    #expect(output.contains("race-proof"))
}

@Test func testAgentRejectsConcurrentRunsOnSameInstance() async throws {
    let agent = Agent(config: AgentConfig(provider: ToolAwareMockProvider(), model: "mock", maxTurns: 1))
    var callbacks = AgentCallbacks()
    callbacks.beforeAgent = { query, _ in
        if query == "first" {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return "first done"
        }
        return nil
    }
    agent.callbacks = callbacks

    let firstRun = Task { try await agent.run("first") }
    try await Task.sleep(nanoseconds: 50_000_000)

    await #expect(throws: AgentError.runInProgress) {
        _ = try await agent.run("second")
    }

    let firstOutput = try await firstRun.value
    #expect(firstOutput == "first done")
}

// MARK: - @Tool Macro Tests

struct TestTools {
    @Tool("Return the current date and time.")
    func currentTime() async throws -> String {
        "Sunday at 2:15 PM"
    }

    @Tool("Calculate a basic arithmetic expression.")
    func calculate(expression: String) async throws -> String {
        if expression.trimmingCharacters(in: .whitespaces) == "38 * 17" {
            return "646"
        }
        return "unknown"
    }

    @Tool("Echo a message back.")
    /// - Parameter message: The message to echo
    func echoMessage(message: String) async throws -> String {
        "Echo: \(message)"
    }

    @Tool("Check if a number is even.")
    func isEven(number: Int) async throws -> String {
        number % 2 == 0 ? "true" : "false"
    }

    @Tool("Format a floating-point score.")
    func formatScore(score: Double) async throws -> String {
        String(format: "%.1f", score)
    }

    @Tool("Check if user is active.")
    func checkActive(active: Bool) async throws -> String {
        active ? "active" : "inactive"
    }

    // A description containing a double-quote and a backslash — this only
    // compiles if the macro escapes the description in the generated literal.
    @Tool("Wrap text in \"quotes\" using a \\ backslash.")
    func wrapQuoted(text: String) async throws -> String {
        "\"\(text)\""
    }
}

@Test func testToolMacroNoParams() async throws {
    let tools = TestTools()
    let tool = tools.currentTimeTool()
    #expect(tool.name == "current_time")
    #expect(tool.description == "Return the current date and time.")
    #expect(tool.parameters == ToolParameters.empty)

    let result = try await tool.execute(parameters: [:])
    #expect(!result.isError)
    #expect(result.result == "Sunday at 2:15 PM")
}

@Test func testToolMacroWithParams() async throws {
    let tools = TestTools()
    let tool = tools.calculateTool()
    #expect(tool.name == "calculate")
    #expect(tool.description == "Calculate a basic arithmetic expression.")
    #expect(tool.parameters.properties.count == 1)
    #expect(tool.parameters.properties["expression"]?.type == "string")
    #expect(tool.parameters.required == ["expression"])

    let result = try await tool.execute(parameters: ["expression": "38 * 17"])
    #expect(!result.isError)
    #expect(result.result == "646")
}

@Test func testToolMacroWithDocCDescription() async throws {
    let tools = TestTools()
    let tool = tools.echoMessageTool()
    #expect(tool.name == "echo_message")
    let prop = tool.parameters.properties["message"]
    #expect(prop?.type == "string")
    // DocC comment extraction falls back to param name when comment not found
    #expect(prop?.description == "message" || prop?.description == "The message to echo")
}

@Test func testToolMacroWithIntParam() async throws {
    let tools = TestTools()
    let tool = tools.isEvenTool()
    #expect(tool.parameters.properties["number"]?.type == "integer")
    #expect(tool.parameters.required == ["number"])

    let result = try await tool.execute(parameters: ["number": 4])
    #expect(result.result == "true")
}

@Test func testToolMacroWithBoolParam() async throws {
    let tools = TestTools()
    let tool = tools.checkActiveTool()
    #expect(tool.parameters.properties["active"]?.type == "boolean")

    let result = try await tool.execute(parameters: ["active": true])
    #expect(result.result == "active")
}

@Test func testToolMacroWithDoubleParam() async throws {
    let tools = TestTools()
    let tool = tools.formatScoreTool()
    #expect(tool.parameters.properties["score"]?.type == "number")
    #expect(tool.parameters.required == ["score"])

    let result = try await tool.execute(parameters: ["score": 9.25])
    #expect(result.result == "9.2")
}

@Test func testToolMacroGeneratesAgentToolConformance() async throws {
    let tools = TestTools()
    let tool = tools.currentTimeTool()
    let agent = Agent(config: AgentConfig(
        provider: ToolAwareMockProvider(),
        model: "mock",
        maxTurns: 3
    ))
    agent.register(tool)
    #expect(Bool(true))
}

@Test func testToolMacroHandlesEscapedDescription() async throws {
    // A @Tool description containing escaped quotes and a backslash must
    // survive macro expansion and compile — this guards the description
    // passthrough. The expectation mirrors the source literal exactly.
    let tool = TestTools().wrapQuotedTool()
    #expect(tool.description == "Wrap text in \"quotes\" using a \\ backslash.")
    let result = try await tool.execute(parameters: ["text": "hi"])
    #expect(result.result == "\"hi\"")
}

@Test func testAgentConfigToolsAutoRegistration() async throws {
    let agent = Agent(config: AgentConfig(
        provider: ToolAwareMockProvider(),
        model: "mock",
        maxTurns: 3,
        tools: [EchoTool()]
    ))

    // Tools should be registered automatically from config
    let output = try await agent.run("Use echo tool now")
    #expect(output.contains("race-proof"))
}


// MARK: - AgentMemory Tests

@Test func testAgentMemoryEntryEquatable() {
    let entry = AgentMemoryEntry(kind: .user, title: "Name", content: "Ayman")
    let same = AgentMemoryEntry(id: entry.id, kind: .user, title: "Name", content: "Ayman",
                                createdAt: entry.createdAt, updatedAt: entry.updatedAt)
    let different = AgentMemoryEntry(kind: .user, title: "Role", content: "Engineer")
    #expect(entry == same)
    #expect(entry != different)
}

@Test func testFileAgentMemoryStoreSeedsAndSaves() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = FileAgentMemoryStore(directory: tempDir)
    store.seedIfNeeded()

    let entries = try await store.loadAll()
    #expect(entries.count >= 1) // AGENT.md

    try FileManager.default.removeItem(at: tempDir)
}

@Test func testFileAgentMemoryStoreSavesUserFact() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = FileAgentMemoryStore(directory: tempDir)

    let entry = AgentMemoryEntry(kind: .user, title: "Name", content: "Ayman")
    try await store.save(entry)

    let userEntries = try await store.load(kind: .user)
    #expect(userEntries.count == 1)
    #expect(userEntries[0].content.contains("Ayman"))

    let context = await store.loadContextBlock()
    #expect(context.contains("Ayman"))

    try FileManager.default.removeItem(at: tempDir)
}

@Test func testFileAgentMemoryStoreSavesFact() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = FileAgentMemoryStore(directory: tempDir)

    let entry = AgentMemoryEntry(kind: .fact, title: "Project Location", content: "~/projects/swift-kits")
    try await store.save(entry)

    let factEntries = try await store.load(kind: .fact)
    #expect(factEntries.count == 1)
    #expect(factEntries[0].title == "Project Location")

    let indexURL = tempDir.appendingPathComponent("MEMORY.md")
    let index = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(index.contains("Project Location"))
    #expect(index.contains("memory/project-location.md"))

    try FileManager.default.removeItem(at: tempDir)
}

@Test func testRememberToolExecutes() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = FileAgentMemoryStore(directory: tempDir)
    let tool = RememberTool(store: store)

    let result = try await tool.execute(parameters: [
        "kind": "user",
        "title": "Name",
        "content": "Ayman"
    ])

    #expect(!result.isError)
    #expect(result.result.contains("Remembered"))

    let userEntries = try await store.load(kind: .user)
    #expect(userEntries.count == 1)

    try FileManager.default.removeItem(at: tempDir)
}

@Test func testRememberToolRejectsMissingFields() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = FileAgentMemoryStore(directory: tempDir)
    let tool = RememberTool(store: store)

    let result = try await tool.execute(parameters: ["kind": "user"])
    #expect(result.isError)

    try FileManager.default.removeItem(at: tempDir)
}

// MARK: - AgentGoal Tests

@Test func testAgentGoalProgressAndStatus() {
    var goal = AgentGoal(query: "Build a Swift package")
    #expect(goal.status == .pending)
    #expect(goal.progress == 0.0)

    goal.start()
    #expect(goal.status == .inProgress)

    goal.complete(summary: "Done")
    #expect(goal.status == .completed)
    #expect(goal.progress == 1.0)
    #expect(goal.summary == "Done")
}

@Test func testAgentGoalProgressFromPlan() {
    var goal = AgentGoal(
        query: "Do multi-step task",
        status: .inProgress,
        plan: AgentPlan(steps: [
            AgentPlanStep(step: "A", status: .completed),
            AgentPlanStep(step: "B", status: .completed),
            AgentPlanStep(step: "C", status: .pending)
        ])
    )
    #expect(goal.progress > 0.6 && goal.progress < 0.7)
}

@Test func testFileAgentGoalStoreRoundTrip() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = FileAgentGoalStore(directory: tempDir)

    var goal = AgentGoal(query: "Test goal")
    goal.start()
    try await store.save(goal)

    let loaded = try await store.load(id: goal.id)
    #expect(loaded != nil)
    #expect(loaded?.query == "Test goal")
    #expect(loaded?.status == .inProgress)

    goal.complete(summary: "Finished")
    try await store.save(goal)
    let reloaded = try await store.load(id: goal.id)
    #expect(reloaded?.status == .completed)
    #expect(reloaded?.summary == "Finished")

    let all = try await store.loadAll()
    #expect(all.count == 1)

    try await store.delete(id: goal.id)
    #expect(try await store.load(id: goal.id) == nil)

    try FileManager.default.removeItem(at: tempDir)
}

@Test func testDefaultStoreNamedHelpers() {
    let memory = FileAgentMemoryStore.defaultStore(named: "testapp")
    let goal = FileAgentGoalStore.defaultStore(named: "testapp")

    #expect(memory.directory.path.hasSuffix("/.testapp"))
    #expect(goal.directory.path.hasSuffix("/.testapp/goals"))
}

// MARK: - Streaming-with-tools

/// URLProtocol that scripts a two-turn ReAct exchange for `StreamingScriptedProvider`.
/// The turn/stream flags are encoded in the request URL by `prepareRequest`.
final class StreamingScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isStream = items.first { $0.name == "stream" }?.value == "1"
        let isFinal = items.first { $0.name == "final" }?.value == "1"

        let body: String
        if isStream {
            // Turn 1 (no tool result yet) signals a tool call; turn 2 streams the answer.
            body = isFinal
                ? "data: text Hello\ndata: text  world\ndata: done stop\n"
                : "data: done tool_calls\n"
        } else {
            body = "{}" // complete() path — parseResponse branches on the request
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A provider that streams real chunks: turn 1 asks for the `echo` tool, turn 2
/// streams "Hello world" as two text chunks. Exercises `runStreaming` with tools.
struct StreamingScriptedProvider: LLMProvider {
    static let name = "streaming-scripted-mock"

    let configuration = LLMProviderConfiguration(
        name: StreamingScriptedProvider.name,
        baseURL: URL(string: "https://stream.mock")!,
        apiKey: nil,
        defaultModel: "mock"
    )

    let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingScriptedURLProtocol.self]
        return URLSession(configuration: config)
    }()

    func prepareRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        var comps = URLComponents(string: "https://stream.mock/c")!
        let isFinal = request.messages.contains { $0.role == .tool }
        comps.queryItems = [
            URLQueryItem(name: "stream", value: stream ? "1" : "0"),
            URLQueryItem(name: "final", value: isFinal ? "1" : "0"),
        ]
        return URLRequest(url: comps.url!)
    }

    func parseStreamLine(_ line: String, request: LLMRequest) throws -> [LLMStreamChunk] {
        guard line.hasPrefix("data: ") else { return [] }
        let payload = String(line.dropFirst("data: ".count))
        if payload.hasPrefix("text ") { return [.text(String(payload.dropFirst("text ".count)))] }
        if payload == "done stop" { return [.finish(reason: .stop, usage: nil)] }
        if payload == "done tool_calls" { return [.finish(reason: .toolCalls, usage: nil)] }
        return []
    }

    func parseResponse(_ data: Data, request: LLMRequest) throws -> LLMResponse {
        let hasToolResult = request.messages.contains { $0.role == .tool }
        if request.tools.contains(where: { $0.name == "echo" }) && !hasToolResult {
            return LLMResponse(
                text: "",
                finishReason: .toolCalls,
                toolCalls: [LLMToolCall(name: "echo", arguments: "{\"message\":\"hi\"}")],
                request: request,
                providerName: Self.name
            )
        }
        return LLMResponse(text: "Hello world", finishReason: .stop, request: request, providerName: Self.name)
    }
}

/// Counts `complete()` calls to prove the streamed tool-call path doesn't re-issue.
actor CompleteCallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// In-process provider (like MLX) whose STREAM yields a complete tool call.
/// `complete()` should never be called for such a turn.
struct StreamToolCallProvider: LLMProvider {
    static let name = "stream-toolcall-mock"
    let configuration = LLMProviderConfiguration(name: StreamToolCallProvider.name, baseURL: URL(string: "inproc://x")!)
    let counter: CompleteCallCounter

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        await counter.bump()
        return LLMResponse(text: "should-not-be-used", finishReason: .stop, request: request, providerName: Self.name)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let hasToolResult = request.messages.contains { $0.role == .tool }
        return AsyncThrowingStream { continuation in
            if hasToolResult {
                continuation.yield(.text("done"))
                continuation.yield(.finish(reason: .stop, usage: nil))
            } else {
                continuation.yield(.toolCall(LLMToolCall(name: "echo", arguments: "{\"message\":\"hi\"}")))
                continuation.yield(.finish(reason: .toolCalls, usage: nil))
            }
            continuation.finish()
        }
    }
}

@Test func testStreamedToolCallsSkipCompleteReissue() async throws {
    let counter = CompleteCallCounter()
    let agent = Agent(config: AgentConfig(
        provider: StreamToolCallProvider(counter: counter),
        model: "mock",
        maxTurns: 4
    ))
    agent.register(EchoTool())

    var chunks: [String] = []
    for try await chunk in agent.runStreaming("echo please") {
        chunks.append(chunk)
    }

    #expect(chunks.joined() == "done")            // final answer streamed
    let completeCalls = await counter.count
    #expect(completeCalls == 0, "streamed tool calls must not trigger a complete() re-issue")
}

@Test func testRunStreamingStreamsFinalAnswerAfterToolCall() async throws {
    let agent = Agent(config: AgentConfig(
        provider: StreamingScriptedProvider(),
        model: "mock",
        maxTurns: 4
    ))
    agent.register(EchoTool())

    var chunks: [String] = []
    for try await chunk in agent.runStreaming("please echo something") {
        chunks.append(chunk)
    }

    // The final answer arrived token-by-token (not a single post-hoc chunk)...
    #expect(chunks.count >= 2)
    // ...and reconstructs to the streamed answer, after the tool turn ran.
    #expect(chunks.joined() == "Hello world")
}

/// Thread-safe capture of which event kinds the agent emitted.
final class StreamingEventFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var toolCalls = false, streamChunk = false, finished = false
    func record(_ event: AgentEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .toolCallsReceived: toolCalls = true
        case .streamChunk: streamChunk = true
        case .finished: finished = true
        default: break
        }
    }
    var snapshot: (toolCalls: Bool, streamChunk: Bool, finished: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (toolCalls, streamChunk, finished)
    }
}

@Test func testRunStreamingSharesRunLoopEvents() async throws {
    // Parity check: runStreaming now goes through the same ReAct loop as run(),
    // so the full event set is emitted (tool calls, stream chunks, finished).
    let agent = Agent(config: AgentConfig(
        provider: StreamingScriptedProvider(),
        model: "mock",
        maxTurns: 4
    ))
    agent.register(EchoTool())

    let flags = StreamingEventFlags()
    agent.addObserver(BlockObserver { flags.record($0) })

    for try await _ in agent.runStreaming("please echo something") {}

    let seen = flags.snapshot
    #expect(seen.toolCalls)
    #expect(seen.streamChunk)
    #expect(seen.finished)
}

@Test func testRemoveObserverStopsEventDelivery() async throws {
    let agent = Agent(config: AgentConfig(
        provider: StreamingScriptedProvider(),
        model: "mock",
        maxTurns: 4
    ))
    agent.register(EchoTool())

    let flags = StreamingEventFlags()
    let token = agent.onEvent { flags.record($0) }
    // Remove immediately — the observer must receive no events.
    agent.removeObserver(token)

    for try await _ in agent.runStreaming("please echo something") {}

    let seen = flags.snapshot
    #expect(!seen.toolCalls)
    #expect(!seen.streamChunk)
    #expect(!seen.finished)
}

// MARK: - Context management (ContextSift)

private func firstArtifactID(in text: String) -> String? {
    guard let range = text.range(of: #"artifact-[0-9a-f]{12}"#, options: .regularExpression) else { return nil }
    return String(text[range])
}

@Test func testArtifactStoreRoundTrip() async {
    let store = InMemoryArtifactStore()
    let saved = await store.save("line one\nNEEDLE here\nline three", description: "t", toolCallID: "c1")

    let slice = await store.read(saved.id, offset: 0, limit: 4)
    #expect(slice?.content == "line")
    #expect(slice?.hasMore == true)

    let matches = await store.search(saved.id, query: "needle", maxMatches: 5)
    #expect(matches.count == 1)
    #expect(matches.first?.line == 2)
}

@Test func testContextManagerExternalizesCompletedToolResults() async {
    let manager = ContextManager(summaryLength: 40, inlineBudgetChars: 0)
    // Marker placed deep in the output (well past the 40-char receipt summary).
    let bigResult = String(repeating: "x", count: 500) + " DEEP_NEEDLE_END"

    // A completed tool exchange (an assistant text turn follows it), then a new user turn.
    let messages: [AgentMessage] = [
        .system("You are helpful."),
        .user("read the file"),
        .assistant(content: "", toolCalls: [AgentToolCall(id: "c1", name: "read_file")]),
        .tool(results: [.success(toolCallId: "c1", toolName: "read_file", result: bigResult)]),
        .assistant("Here is the summary."),
        .user("thanks, what next?"),
    ]

    let out = await manager.modelMessages(messages) { $0 }

    // The full tool output must NOT be resent in any model message…
    #expect(out.allSatisfy { !$0.content.contains("DEEP_NEEDLE_END") })
    // …but a ledger + artifact reference must appear in the (single) system block.
    let system = out.first { $0.role == .system }
    #expect(system != nil)
    #expect(system?.content.contains("tool ledger") == true)
    #expect(system?.content.contains("read_file") == true)
    let artifactID = system.flatMap { firstArtifactID(in: $0.content) }
    #expect(artifactID != nil)

    // Main messages survive.
    #expect(out.contains { $0.role == .user && $0.content.contains("thanks") })
    #expect(out.contains { $0.role == .assistant && $0.content.contains("summary") })

    // And the full output is retrievable from the store via the artifact tool.
    if let artifactID {
        let tool = ArtifactReadTool(store: manager.store)
        let read = try? await tool.execute(parameters: ["artifact_id": artifactID])
        #expect(read?.result.contains("DEEP_NEEDLE_END") == true)
    }
}

@Test func testContextManagerDoesNotRetruncateArtifactReads() async {
    // Small active bound so a normal result would be truncated…
    let manager = ContextManager(maxActiveResultChars: 40, inlineBudgetChars: 0)
    let bigRead = String(repeating: "y", count: 500) + " READ_TAIL"

    // Active exchange = an artifact_read the model just issued.
    let messages: [AgentMessage] = [
        .user("show me the full listing"),
        .assistant(content: "", toolCalls: [AgentToolCall(id: "r1", name: "artifact_read")]),
        .tool(results: [.success(toolCallId: "r1", toolName: "artifact_read", result: bigRead)]),
    ]

    let out = await manager.modelMessages(messages) { $0 }

    // Retrieval output must be shown IN FULL — not re-truncated / re-spilled,
    // otherwise the model loops calling artifact_read forever.
    let toolMsg = out.first { $0.role == .tool }
    #expect(toolMsg != nil)
    #expect(toolMsg?.content.contains("READ_TAIL") == true)
    #expect(toolMsg?.content.contains("truncated") == false)
}

@Test func testContextManagerKeepsSmallConversationInline() async {
    // A completed tool exchange in a SMALL conversation must stay fully inline
    // (no ledger, tool result present) — not externalized — so the model keeps
    // its own recent history and doesn't lose the thread on multi-step tasks.
    let manager = ContextManager()  // default 16k inline budget
    let messages: [AgentMessage] = [
        .system("You are helpful."),
        .user("check fpdf"),
        .assistant(content: "", toolCalls: [AgentToolCall(id: "c1", name: "run_shell")]),
        .tool(results: [.success(toolCallId: "c1", toolName: "run_shell", result: "fpdf 2.8.7 installed")]),
        .assistant("Good, fpdf is available."),
        .user("now create it"),
    ]

    let out = await manager.modelMessages(messages) { $0 }

    // Tool result kept inline (not dropped into a ledger)…
    #expect(out.contains { $0.role == .tool && $0.content.contains("fpdf 2.8.7 installed") })
    // …the tool-call turn is preserved…
    #expect(out.contains { $0.role == .assistant && ($0.toolCalls?.isEmpty == false) })
    // …and no "tool ledger" externalization text appears.
    #expect(out.allSatisfy { !$0.content.contains("tool ledger") })
}

@Test func testContextManagerEvictsOldestKeepsRecent() async {
    // Over budget with two completed tool exchanges: the OLD one is externalized
    // to the ledger, the RECENT tool result stays inline (so an iterative
    // debug loop can still see what it just did).
    let manager = ContextManager(inlineBudgetChars: 200)
    let oldResult = String(repeating: "O", count: 400) + " OLDTAIL"   // marker past the 200-char summary
    let messages: [AgentMessage] = [
        .user("start"),
        .assistant(content: "", toolCalls: [AgentToolCall(id: "old", name: "run_shell")]),
        .tool(results: [.success(toolCallId: "old", toolName: "run_shell", result: oldResult)]),
        .assistant(content: "", toolCalls: [AgentToolCall(id: "recent", name: "run_shell")]),
        .tool(results: [.success(toolCallId: "recent", toolName: "run_shell", result: "RECENT_MARKER_kept")]),
        .assistant("let me fix it"),
        .user("continue"),
    ]

    let out = await manager.modelMessages(messages) { $0 }

    #expect(out.contains { $0.role == .tool && $0.content.contains("RECENT_MARKER_kept") })
    #expect(out.allSatisfy { !$0.content.contains("OLDTAIL") })
    #expect(out.contains { $0.role == .system && $0.content.contains("ledger") })
}

@Test func testContextManagerKeepsActiveExchange() async {
    let manager = ContextManager(inlineBudgetChars: 0)
    // Conversation ends on a tool result the model still needs to act on.
    let messages: [AgentMessage] = [
        .user("what time is it"),
        .assistant(content: "", toolCalls: [AgentToolCall(id: "c1", name: "current_time")]),
        .tool(results: [.success(toolCallId: "c1", toolName: "current_time", result: "12:00 PM")]),
    ]

    let out = await manager.modelMessages(messages) { $0 }

    // The active tool result is kept in full (the model needs it now).
    #expect(out.contains { $0.role == .tool && $0.content.contains("12:00 PM") })
    // And the assistant tool-call turn is preserved (paired with the result).
    #expect(out.contains { $0.role == .assistant && ($0.toolCalls?.isEmpty == false) })
}

// MARK: - Skill store + learn_skill (self-improvement)

private func tempSkillDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sak-skills-\(UUID().uuidString)", isDirectory: true)
}

@Test func testFileSkillStoreRoundTrips() async throws {
    let store = FileAgentSkillStore(directory: tempSkillDir())
    try await store.save(AgentSkill(
        name: "Scaffold SwiftUI view",
        triggerKeywords: ["swiftui", "new view"],
        instructions: "1. Create the file. 2. Add a View struct. 3. Add a #Preview."
    ))

    let loaded = try await store.loadAll()
    #expect(loaded.count == 1)
    let skill = try #require(loaded.first)
    #expect(skill.name == "Scaffold SwiftUI view")
    #expect(skill.triggerKeywords.contains("swiftui"))
    #expect(skill.instructions.contains("#Preview"))
    #expect(skill.matches("please make a new SwiftUI screen"))
}

@Test func testSkillStoreParsesTriggersAfterBlankLine() async throws {
    let store = FileAgentSkillStore(directory: tempSkillDir())
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let md = "# Deploy\n\nTriggers: deploy, ship\n\nRun the deploy script.\n"
    try md.write(to: store.directory.appendingPathComponent("deploy.md"), atomically: true, encoding: .utf8)

    let loaded = try await store.loadAll()
    let skill = try #require(loaded.first)
    #expect(skill.name == "Deploy")
    #expect(skill.triggerKeywords.contains("deploy"))
    #expect(skill.instructions.contains("deploy script"))
    #expect(skill.instructions.contains("Triggers:") == false)
}

@Test func testContextManagerReusesActiveArtifact() async {
    let manager = ContextManager(maxActiveResultChars: 20, inlineBudgetChars: 0)
    let big = String(repeating: "z", count: 300)
    let messages: [AgentMessage] = [
        .user("go"),
        .assistant(content: "", toolCalls: [AgentToolCall(id: "c1", name: "run_shell")]),
        .tool(results: [.success(toolCallId: "c1", toolName: "run_shell", result: big)]),
    ]

    func artifactID(_ msgs: [LLMMessage]) -> String? {
        let text = msgs.first { $0.role == .tool }?.content ?? ""
        guard let r = text.range(of: #"artifact-[0-9a-f]{12}"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }
    let a = artifactID(await manager.modelMessages(messages) { $0 })
    let b = artifactID(await manager.modelMessages(messages) { $0 })
    #expect(a != nil)
    #expect(a == b, "active artifact id should be stable across turns")
}

@Test func testLearnSkillToolPersistsAndActivates() async throws {
    let store = FileAgentSkillStore(directory: tempSkillDir())
    let registry = SkillRegistry()
    let tool = LearnSkillTool(store: store, registry: registry)

    let result = try await tool.execute(parameters: [
        "name": "Fix flaky test",
        "triggers": "flaky, retry, intermittent",
        "instructions": "Re-run 3x; if it passes sometimes, quarantine and open an issue.",
    ])
    #expect(result.isError == false)

    // Persisted…
    let persisted = try await store.loadAll()
    #expect(persisted.contains { $0.name == "Fix flaky test" })
    // …and live in the registry (fires on a matching query).
    let active = await registry.matchingSkills(for: "this test is flaky")
    #expect(active.contains { $0.name == "Fix flaky test" })
}

// MARK: - Live model smoke test (gated)

/// A real tool the model must call to answer correctly.
struct AddTool: AgentTool {
    let name = "add"
    let description = "Add two integers and return their sum."
    let parameters = ToolParameters(
        properties: [
            "a": ToolParameterProperty(type: "integer", description: "First integer"),
            "b": ToolParameterProperty(type: "integer", description: "Second integer"),
        ],
        required: ["a", "b"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        func intValue(_ key: String) -> Int {
            if let i = parameters[key] as? Int { return i }
            if let d = parameters[key] as? Double { return Int(d) }
            if let s = parameters[key] as? String, let i = Int(s) { return i }
            return 0
        }
        let sum = intValue("a") + intValue("b")
        return .success(toolCallId: "", toolName: name, result: "\(sum)")
    }
}

/// End-to-end streaming-with-tools against a real Ollama model. Gated: runs only
/// when `SAK_LIVE_TESTS=1` (and a local Ollama server has `glm-5.2:cloud`), so CI
/// and normal `swift test` stay hermetic. Run with:
///   SAK_LIVE_TESTS=1 swift test --filter liveOllamaStreamingWithToolCall
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func liveOllamaStreamingWithToolCall() async throws {
    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "glm-5.2:cloud"))
    let agent = Agent(config: AgentConfig(provider: provider, model: "glm-5.2:cloud", maxTurns: 4))
    agent.register(AddTool())

    var chunks: [String] = []
    for try await chunk in agent.runStreaming(
        "What is 21 plus 21? Use the add tool, then state the numeric result."
    ) {
        chunks.append(chunk)
    }

    let full = chunks.joined()
    // The answer streamed (at least one chunk) and reflects the tool's computed result.
    #expect(!chunks.isEmpty)
    #expect(full.contains("42"))
}

/// A tool that returns a large multi-line "directory listing" (mimics run_shell),
/// with a sentinel filename placed PAST the inline preview so the model must go
/// through `artifact_read` to find it.
struct BigListingTool: AgentTool {
    let name = "run_shell"
    let description = "Run a shell command and return its output. Use it to list files."
    let parameters = ToolParameters(
        properties: ["command": ToolParameterProperty(type: "string", description: "The shell command")],
        required: ["command"]
    )

    static let needle = "NEEDLE_FILE_Zm9v.txt"

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        var lines: [String] = []
        for i in 0..<400 { lines.append("-rw-r--r--  1 user staff  \(1000 + i)  Jan  1 file_\(String(format: "%04d", i)).dat") }
        lines.append("-rw-r--r--  1 user staff  4242  Jan  1 \(Self.needle)")  // ~well past 8k chars
        return .success(toolCallId: "", toolName: name, result: lines.joined(separator: "\n"))
    }
}

/// Live regression for the ContextSift `artifact_read` loop. With a `ContextManager`
/// and a >8k tool output whose sentinel is only reachable via retrieval, the model
/// must NOT spiral calling `artifact_read`. Gated on `SAK_LIVE_TESTS=1`.
///   SAK_LIVE_TESTS=1 swift test --filter liveContextSiftNoArtifactReadLoop
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func liveContextSiftNoArtifactReadLoop() async throws {
    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "glm-5.2:cloud"))
    let agent = Agent(config: AgentConfig(
        provider: provider,
        model: "glm-5.2:cloud",
        maxTurns: 8,
        tools: [BigListingTool()],
        contextManager: ContextManager()
    ))

    // Count artifact_read executions — before the fix this spiralled (~6 calls).
    let counter = ArtifactReadCounter()
    _ = agent.onEvent { event in
        if case .toolExecutionFinished(let call, _) = event, call.name == "artifact_read" {
            Task { await counter.bump() }
        }
    }

    var chunks: [String] = []
    for try await chunk in agent.runStreaming(
        "Run run_shell to list the files, then tell me whether a file named \(BigListingTool.needle) is present. Answer yes or no and name it."
    ) {
        chunks.append(chunk)
    }

    let full = chunks.joined()
    let reads = await counter.count
    // The run produced a final answer and did not loop on retrieval.
    #expect(!full.isEmpty)
    #expect(reads <= 3, "artifact_read was called \(reads) times — retrieval loop suspected")
}

actor ArtifactReadCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Live proof of cross-conversation memory: a fact told to one agent is recalled
/// by a *different* agent sharing the same `FileAgentMemoryStore`. Mirrors the
/// Naseem setup (one store shared by every conversation). Gated on SAK_LIVE_TESTS=1.
///   SAK_LIVE_TESTS=1 swift test --filter liveCrossConversationMemory
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func liveCrossConversationMemory() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("naseem-mem-\(UUID().uuidString)", isDirectory: true)
    let store = FileAgentMemoryStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    func makeAgent() -> Agent {
        let provider = OllamaProvider(configuration: OllamaProvider.local(model: "glm-5.2:cloud"))
        let agent = Agent(config: AgentConfig(provider: provider, model: "glm-5.2:cloud", maxTurns: 4))
        agent.memoryStore = store
        return agent
    }

    // Conversation 1 — the user introduces themselves.
    let convo1 = makeAgent()
    _ = try await convo1.run("My name is Ayman and I prefer Swift. Please remember this about me.")

    // The remember tool should have persisted the user fact.
    let userDoc = try await store.load(kind: .user).first?.content ?? ""
    #expect(userDoc.localizedCaseInsensitiveContains("Ayman"))

    // Conversation 2 — a brand-new agent, same store, no shared conversation history.
    let convo2 = makeAgent()
    let answer = try await convo2.run("What is my name? Answer with just the name.")
    #expect(answer.localizedCaseInsensitiveContains("Ayman"))
}

/// Live: the agent authors a skill via `learn_skill` (auto-registered when a
/// skill store is attached) and it persists. Gated on SAK_LIVE_TESTS=1.
///   SAK_LIVE_TESTS=1 swift test --filter liveAgentLearnsSkill
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func liveAgentLearnsSkill() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("naseem-skills-\(UUID().uuidString)", isDirectory: true)
    let store = FileAgentSkillStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "glm-5.2:cloud"))
    let agent = Agent(config: AgentConfig(provider: provider, model: "glm-5.2:cloud", maxTurns: 4))
    agent.skillStore = store   // auto-registers learn_skill + loads persisted skills

    _ = try await agent.run(
        "Use the learn_skill tool to save a skill named \"greet politely\" with triggers "
        + "\"greeting, hello\" and instructions \"Say hello warmly and offer to help.\"")

    let skills = try await store.loadAll()
    #expect(skills.contains { $0.name.localizedCaseInsensitiveContains("greet") })
}
