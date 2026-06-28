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

@Test func testConversationTokenEstimation() {
    let conv = Conversation()
    let message = AgentMessage.user("This is a test message with some content")
    let tokens = conv.estimateTokens(message)
    #expect(tokens > 0)
    #expect(tokens < 20) // ~38 chars / 4 = ~10 tokens
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

struct DelayTool: AgentTool {
    let name: String
    let description = "Echoes with a small delay."
    let parameters = ToolParameters(
        properties: ["msg": ToolParameterProperty(type: "string", description: "Message")],
        required: ["msg"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        // Simulate I/O delay
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        let msg = parameters["msg"] as? String ?? ""
        return .success(toolCallId: "", toolName: name, result: msg)
    }
}

@Test func testParallelToolExecution() async {
    let registry = ToolRegistry()
    await registry.register(DelayTool(name: "delay1"))
    await registry.register(DelayTool(name: "delay2"))
    let dispatcher = ToolDispatcher(registry: registry)
    let state = AgentState()

    let call1 = AgentToolCall(name: "delay1", parameters: ["msg": AnyCodable("a")])
    let call2 = AgentToolCall(name: "delay2", parameters: ["msg": AnyCodable("b")])

    let start = Date()
    let results = await dispatcher.dispatch(calls: [call1, call2], state: state, parallel: true, observer: nil)
    let elapsed = Date().timeIntervalSince(start)

    #expect(results.count == 2)
    // Parallel: ~50ms total (not ~100ms sequential)
    #expect(elapsed < 0.09) // Should be faster than 2x50ms
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

@Test func testAgentAwaitsImmediateToolRegistrationBeforeRun() async throws {
    let agent = Agent(config: AgentConfig(provider: ToolAwareMockProvider(), model: "mock", maxTurns: 3))
    agent.register(EchoTool())

    let output = try await agent.run("Use echo tool now")

    #expect(output.contains("race-proof"))
}
