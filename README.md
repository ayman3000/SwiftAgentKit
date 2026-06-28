# SwiftAgentKit

**SwiftAgentKit** is a protocol-oriented Swift package for building tool-using AI agents in Swift apps.

It gives Swift developers a reusable agent runtime: conversation memory, tool calling, state, planning, structured output, callbacks, event observability, session persistence, and a ReAct-style loop — all built on top of [`LLMProviderKit`](https://github.com/ayman3000/LLMProviderKit), the multi-provider LLM abstraction for Swift.

> **Status:** `0.1.0-alpha` candidate. The core loop is working and dogfooded with local and cloud providers, but APIs may still evolve.

---

## Why SwiftAgentKit?

Calling an LLM is not the same as building an agent.

A normal LLM call is:

```text
User prompt → Model response
```

An agent loop is:

```text
User prompt
→ Model decides what to do
→ Model requests tools
→ Swift code executes those tools
→ Tool results are sent back to the model
→ Model continues or produces a final answer
```

`LLMProviderKit` handles the provider layer:

```text
Ollama / OpenAI / Gemini / Anthropic / compatible providers
```

`SwiftAgentKit` handles the agent layer:

```text
Tools, memory, state, planning, repair, callbacks, events, sessions
```

Together they let you build real Swift AI apps where the model can act through your app’s capabilities instead of only generating text.

---

## Who is this for?

SwiftAgentKit is for Swift developers building AI-powered apps such as:

- SwiftUI chat assistants
- local-first Ollama apps
- productivity assistants
- coding assistants
- file or project automation tools
- data/query assistants
- app copilots
- agentic macOS utilities
- educational AI apps
- prototypes that need to switch between local and cloud models

It is especially useful when your app needs the model to call Swift code safely:

```text
read a document
query app state
search local data
call an API
run a calculation
create or modify files
remember context
perform multi-step workflows
```

---

## What the package provides

### Core capabilities

| Capability | What it does |
|---|---|
| **Agent loop** | Runs the model → tools → results → model loop until completion. |
| **Tool system** | Define Swift tools with JSON-Schema parameters. The model can call them natively. |
| **Conversation memory** | Maintains chat history and trims it to fit the context window. |
| **Agent state** | Shared key-value state across turns and tools, with `{key}` prompt templating. |
| **Planning** | Optional planning step before execution for complex tasks. |
| **Repair retry** | Nudges the model when tool errors happen instead of accepting false success. |
| **Plan continuation** | Nudges the model if it stops before completing a plan. |
| **Structured output** | Parses JSON from imperfect model responses. |
| **Lifecycle callbacks** | Intercept or replace agent/model/tool behavior for guardrails. |
| **Event stream** | Observe starts, LLM calls, tool calls, tool results, retries, and finish summaries. |
| **Session persistence** | Save and restore conversations through a `SessionStore`. |
| **Streaming** | Stream simple non-tool responses token-by-token. |

---

## Architecture

```text
┌───────────────────────────────────────────────┐
│                Your Swift App                 │
│        SwiftUI / AppKit / CLI / Server         │
├───────────────────────────────────────────────┤
│                SwiftAgentKit                   │
│  Agent loop · Tools · Memory · State · Events  │
│  Planning · Callbacks · Sessions · JSON output │
├───────────────────────────────────────────────┤
│                LLMProviderKit                  │
│  Ollama · OpenAI · Gemini · Anthropic · more   │
├───────────────────────────────────────────────┤
│              Foundation / URLSession           │
└───────────────────────────────────────────────┘
```

SwiftAgentKit does **not** implement provider networking itself. It depends on `LLMProviderKit`’s `LLMProvider` protocol, so the same agent can run on local or cloud models.

---

## Current alpha validation

The package has been dogfooded in a real SwiftUI client with:

- Ollama local model tool-calling loop
- Gemini tool-calling loop
- runtime tool selection
- event timeline debugging
- provider/model switching
- multi-turn transcript context
- tool execution and result loop closure

Validated behaviors include:

```text
User prompt
→ LLM call
→ tool calls received
→ Swift tools execute
→ tool results sent back
→ second LLM call
→ final answer
→ finished with 0 errors
```

This is enough for an alpha release. It is not yet a stable v1 API.

---

## Requirements

- Swift 5.9+
- macOS 13+
- iOS 16+
- tvOS 16+
- watchOS 9+
- visionOS 1+
- [`LLMProviderKit`](https://github.com/ayman3000/LLMProviderKit)

SwiftAgentKit itself is Foundation-based and does not depend on SwiftUI, UIKit, or AppKit.

---

## Installation

### Local package dependency

If you are developing both packages locally:

```swift
// Package.swift
let package = Package(
    name: "YourApp",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    dependencies: [
        .package(path: "../SwiftAgentKit"),
        .package(path: "../LLMProviderKit")
    ],
    targets: [
        .target(
            name: "YourApp",
            dependencies: [
                .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitOllama", package: "LLMProviderKit")
            ]
        )
    ]
)
```

### Xcode

1. Open your app project in Xcode.
2. Go to **File ▸ Add Package Dependencies…**.
3. Add the local `SwiftAgentKit` package path.
4. Add `LLMProviderKit` and the provider products your app needs.
5. Link the products to your app target.

For example, an Ollama app usually needs:

```text
SwiftAgentKit
LLMProviderKit
LLMProviderKitOllama
```

A Gemini app usually needs:

```text
SwiftAgentKit
LLMProviderKit
LLMProviderKitGemini
```

---

## Quick start: simple chat

Use SwiftAgentKit as a normal chat agent with memory.

```swift
import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

let provider = OllamaProvider(
    configuration: OllamaProvider.local(model: "llama3.2")
)

let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "You are a helpful Swift assistant.",
    maxTurns: 1
))

let answer = try await agent.run("Explain async/await in Swift with a tiny example.")
print(answer)
```

Use this pattern when you want conversation history but do not need tools.

---

## Quick start: agent with tools

Tools are normal Swift types that conform to `AgentTool`.

```swift
import Foundation
import SwiftAgentKit

struct CurrentTimeTool: AgentTool {
    let name = "current_time"
    let description = "Return the current date and time on the user's device."
    let parameters = ToolParameters.empty

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let text = Date().formatted(date: .complete, time: .standard)
        return .success(toolCallId: "", toolName: name, result: text)
    }
}
```

Register the tool and run the agent:

```swift
import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

let provider = OllamaProvider(
    configuration: OllamaProvider.local(model: "qwen3:0.6b")
)

let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "You are a helpful assistant. Use tools when needed.",
    maxTurns: 6
))

agent.register(CurrentTimeTool())

let response = try await agent.run("Use your tool to tell me the current time.")
print(response)
```

The agent will send the tool definition to the provider. If the model calls `current_time`, SwiftAgentKit executes the Swift tool and feeds the result back to the model.

---

## Example: multiple runtime tools

```swift
struct EchoTool: AgentTool {
    let name = "echo_message"
    let description = "Echo a message back exactly."
    let parameters = ToolParameters(
        properties: [
            "message": ToolParameterProperty(
                type: "string",
                description: "Message to echo"
            )
        ],
        required: ["message"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let message = parameters["message"] as? String ?? ""
        return .success(toolCallId: "", toolName: name, result: "Echo: \(message)")
    }
}

struct CalculatorTool: AgentTool {
    let name = "calculator"
    let description = "Calculate basic arithmetic expressions."
    let parameters = ToolParameters(
        properties: [
            "expression": ToolParameterProperty(
                type: "string",
                description: "Arithmetic expression, e.g. 38 * 17"
            )
        ],
        required: ["expression"]
    )

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let expression = parameters["expression"] as? String ?? ""

        // Replace this tiny example with a real safe parser in production.
        if expression.trimmingCharacters(in: .whitespaces) == "38 * 17" {
            return .success(toolCallId: "", toolName: name, result: "646")
        }

        return .error(
            toolCallId: "",
            toolName: name,
            message: "Unsupported expression: \(expression)"
        )
    }
}

agent.registerAll([
    CurrentTimeTool(),
    EchoTool(),
    CalculatorTool()
])

let result = try await agent.run("Get the current time, echo SwiftAgentKit, then calculate 38 * 17.")
print(result)
```

When a model requests multiple tools in the same turn, SwiftAgentKit can dispatch them concurrently and preserves result order when feeding results back.

---

## Observing the agent loop

Use events to build a timeline in your app UI or logs.

```swift
agent.onEvent { event in
    switch event {
    case .started(let query):
        print("Started:", query)

    case .llmCallStarted(let turn):
        print("LLM call started — turn \(turn)")

    case .llmCallCompleted(let turn, let response):
        print("LLM completed — turn \(turn):", response.text)

    case .toolCallsReceived(let calls):
        print("Tool calls:", calls.map(\.name).joined(separator: ", "))

    case .toolExecutionStarted(let call):
        print("Tool started:", call.name)

    case .toolExecutionFinished(let call, let result):
        print("Tool finished:", call.name, result.isError ? "ERROR" : "OK")

    case .finished(let summary):
        print("Finished in \(summary.totalTurns) turns, tools: \(summary.toolsExecuted)")

    default:
        break
    }
}
```

This is useful for developer tools, debug panels, progress UIs, and audit logs.

---

## Using different providers

SwiftAgentKit works with any `LLMProviderKit` provider.

### Ollama

```swift
import LLMProviderKitOllama

let provider = OllamaProvider(
    configuration: OllamaProvider.local(model: "qwen3:0.6b")
)
```

### Gemini

```swift
import LLMProviderKitGemini

let provider = GeminiProvider(
    configuration: GeminiProvider.gemini(
        apiKey: ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? "",
        model: "gemini-2.5-flash-lite"
    )
)
```

### OpenAI

```swift
import LLMProviderKitOpenAI

let provider = OpenAIProvider(
    configuration: OpenAIProvider.openAI(
        apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "",
        model: "gpt-4o-mini"
    )
)
```

### Anthropic

```swift
import LLMProviderKitAnthropic

let provider = AnthropicProvider(
    configuration: AnthropicProvider.anthropic(
        apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "",
        model: "claude-sonnet-4-20250514"
    )
)
```

Once you create the provider, the SwiftAgentKit code is the same:

```swift
let agent = Agent(config: AgentConfig(provider: provider, maxTurns: 6))
agent.register(CurrentTimeTool())
let response = try await agent.run("What time is it? Use the tool.")
```

---

## Agent modes and philosophies

SwiftAgentKit supports several useful patterns through `AgentConfig`.

| Pattern | Configuration | Use when |
|---|---|---|
| **Single-shot** | `maxTurns: 0` | One generation or structured extraction. |
| **Multi-turn chat** | `maxTurns: 1`, no tools | Chat with history but no actions. |
| **ReAct with tools** | `maxTurns > 0`, tools registered | The model must call tools and iterate. |
| **Planner + ReAct** | `enablePlanning: true` | Multi-step tasks benefit from a plan before tool use. |

### Single-shot structured output

```swift
struct Summary: Codable {
    let title: String
    let bullets: [String]
}

let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "Return only valid JSON matching {title: String, bullets: [String]}.",
    maxTurns: 0
))

let summary = try await agent.runStructured(
    "Summarize Swift actors in 3 bullets.",
    as: Summary.self
)

print(summary.title)
```

### Multi-turn chat

```swift
let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "You are a concise Swift tutor.",
    maxTurns: 1,
    contextWindow: 8192,
    maxMessages: 50
))

let first = try await agent.run("What is an actor in Swift?")
let followUp = try await agent.run("Show a small example.")
```

The second call includes previous conversation context automatically.

### Planner + tool execution

```swift
let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "You are a systematic implementation assistant.",
    maxTurns: 12,
    enablePlanning: true,
    enablePlanContinuation: true,
    enableRepairRetry: true
))

agent.registerAll([
    ReadFileTool(),
    WriteFileTool(),
    ListFilesTool()
])

let result = try await agent.run("Inspect this small project and write a README summary.")
print(result)
```

Planning is optional. Keep it off for simple tasks and enable it for tasks where step tracking matters.

---

## Agent state

`AgentState` is a shared key-value store available across turns and tools.

```swift
agent.state.setValue("pro", forKey: "user:tier")
agent.state.setValue("/Users/example/project", forKey: "app:workspace")
```

System prompts can template values:

```swift
let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "The user's tier is {user:tier}. Workspace: {app:workspace}.",
    maxTurns: 6
))
```

Tools can access state through `ToolContext`:

```swift
struct SaveNoteTool: AgentTool {
    let name = "save_note"
    let description = "Save a short note into agent state."
    let parameters = ToolParameters(
        properties: [
            "note": ToolParameterProperty(type: "string", description: "Note text")
        ],
        required: ["note"]
    )

    func execute(context: ToolContext) async throws -> AgentToolResult {
        let note = context.parameters["note"] as? String ?? ""
        context.state.setValue(note, forKey: "session:last_note")
        return .success(toolCallId: context.callId, toolName: name, result: "Saved note.")
    }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "Use execute(context:) instead.")
    }
}
```

Suggested key prefixes:

| Prefix | Meaning |
|---|---|
| `temp:` | Temporary data cleared after a run. |
| `session:` | Current conversation/session data. |
| `user:` | User-level data your app provides. |
| `app:` | App-level configuration or context. |

---

## Lifecycle callbacks and guardrails

Callbacks can intercept the run. Return `nil` to continue normally, or return a value to override behavior.

```swift
var callbacks = AgentCallbacks()

callbacks.beforeAgent = { query, state in
    if query.lowercased().contains("delete everything") {
        return "I can't perform destructive actions without explicit confirmation."
    }
    return nil
}

callbacks.beforeTool = { call, context in
    if call.name == "delete_file" {
        return .error(
            toolCallId: call.id,
            toolName: call.name,
            message: "Blocked by app policy."
        )
    }
    return nil
}

callbacks.afterAgent = { response, state in
    response.trimmingCharacters(in: .whitespacesAndNewlines)
}

agent.callbacks = callbacks
```

Callbacks are useful for:

- policy checks
- user-tier gating
- parameter validation
- dangerous tool confirmation
- PII redaction
- fallback responses
- logging and metrics

---

## Progressive disclosure skills

Skills inject extra instructions only when relevant. This keeps prompts smaller, which is especially important for local models.

```swift
agent.registerSkill(AgentSkill(
    name: "database-help",
    triggerKeywords: ["sql", "database", "query"],
    instructions: "When writing SQL, prefer parameterized queries and explain indexes briefly."
))

agent.registerSkill(AgentSkill(
    name: "charts",
    triggerKeywords: ["chart", "graph", "visualize"],
    instructions: "For chart requests, recommend clear labels and accessible colors.",
    tier: "pro"
))
```

If the user asks about SQL, only the database skill is injected. The chart skill remains dormant.

---

## Session persistence

Use `FileSessionStore` for simple JSON-based conversation persistence.

```swift
let store = FileSessionStore(directoryPath: "/tmp/agent-sessions")

try await agent.saveSession(store: store, sessionId: "chat-001")

let restored = Agent(config: AgentConfig(provider: provider, maxTurns: 1))
let didLoad = try await restored.loadSession(store: store, sessionId: "chat-001")

if didLoad {
    let answer = try await restored.run("What did we discuss earlier?")
    print(answer)
}
```

For production apps, you can implement your own `SessionStore` backed by SQLite, Core Data, CloudKit, or your server.

---

## Streaming

For simple non-tool responses:

```swift
for try await chunk in agent.stream("Tell me a short story about Swift actors.") {
    print(chunk, terminator: "")
}
```

For tool-using agents:

```swift
for try await chunk in agent.runStreaming("Use tools, then summarize the result.") {
    print(chunk, terminator: "")
}
```

Important: the actual tool loop is non-streaming internally because tool calls require complete model responses. `runStreaming` runs the loop, then yields the final response.

---

## Error handling

Always wrap agent runs in `do/catch`.

```swift
do {
    let result = try await agent.run("Analyze this project.")
    print(result)
} catch AgentError.maxTurnsReached(let turns) {
    print("The agent reached the max turn limit: \(turns)")
} catch AgentError.cancelled {
    print("The run was cancelled.")
} catch {
    print("Agent failed:", error.localizedDescription)
}
```

Use a reasonable `maxTurns` for tool agents. Small values are safer for UI apps; larger values are useful for complex workflows.

---

## Cancellation

```swift
let task = Task {
    try await agent.run("Do a long multi-step task.")
}

// Later, from a Cancel button:
agent.cancel()
task.cancel()
```

The agent checks cancellation between turns and throws `AgentError.cancelled`.

---

## Designing good tools

Good tools are the difference between a useful agent and an unreliable one.

### Tool design checklist

- Use a short, clear tool name: `read_file`, `search_notes`, `create_event`.
- Write a specific description. The model reads it to decide when to call the tool.
- Keep parameters explicit and typed.
- Return concise results. Long raw output can overflow the model context.
- Validate parameters inside the tool.
- Use `requiresConfirmation` or callbacks for destructive actions.
- Prefer app-scoped capabilities over unrestricted system access.

### Example: safer file reader

```swift
struct ReadWorkspaceFileTool: AgentTool {
    let name = "read_workspace_file"
    let description = "Read a UTF-8 text file inside the configured workspace."
    let parameters = ToolParameters(
        properties: [
            "relativePath": ToolParameterProperty(
                type: "string",
                description: "Path relative to the workspace root"
            )
        ],
        required: ["relativePath"]
    )

    func execute(context: ToolContext) async throws -> AgentToolResult {
        let workspace = context.state.string(forKey: "app:workspace") ?? ""
        let relativePath = context.parameters["relativePath"] as? String ?? ""

        guard !relativePath.contains("..") else {
            return .error(toolCallId: context.callId, toolName: name, message: "Path traversal is not allowed.")
        }

        let url = URL(fileURLWithPath: workspace).appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)

        return .success(toolCallId: context.callId, toolName: name, result: text)
    }

    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .error(toolCallId: "", toolName: name, message: "This tool requires context.")
    }
}
```

---

## Package layout

```text
Sources/SwiftAgentKit/
├── Core/
│   ├── Agent.swift              # AgentConfig and main Agent runtime
│   ├── AgentMessage.swift       # Internal agent messages and tool-call bridge
│   ├── AgentState.swift         # Cross-turn key-value state
│   ├── AgentCallbacks.swift     # Intercept-able lifecycle hooks
│   ├── AgentSkill.swift         # Progressive-disclosure skills
│   ├── AgentEvent.swift         # Event stream and run summaries
│   ├── AgentError.swift         # Typed agent errors
│   └── AgentLLMResponse.swift   # Provider response bridge
├── Tools/
│   ├── AgentTool.swift          # Tool protocol and schemas
│   ├── ToolContext.swift        # Tool execution context
│   └── ToolDispatcher.swift     # Tool dispatch, dedup, parallel execution
├── Memory/
│   ├── Conversation.swift       # Token-aware conversation history
│   └── SessionStore.swift       # Session persistence protocol + file store
├── Planning/
│   ├── AgentPlan.swift          # Plan model and planner protocol
│   └── RepairRetryPolicy.swift  # Repair retry and continuation policies
├── StructuredOutput/
│   └── StructuredOutput.swift   # Tolerant JSON extraction
└── Logging/
    └── AgentLogger.swift        # Lightweight logging
```

---

## Build and test

```bash
swift build
swift test
```

The unit tests are designed to avoid network calls. Live provider validation should be done separately with local Ollama or real API keys.

---

## Alpha limitations

SwiftAgentKit is useful today, but still alpha.

Known alpha expectations:

- Public APIs may change before beta.
- Provider behavior varies by model quality.
- Some models may ignore tools even when tools are available.
- Tool-use reliability depends on prompt quality and provider support.
- Streaming is best for non-tool paths.
- More examples and docs are still needed.
- OpenAI and Anthropic dogfood coverage should be expanded before beta.

Recommended version label:

```text
0.1.0-alpha.1
```

---

## Roadmap

Short-term:

- More real SwiftUI example apps
- Stronger OpenAI and Anthropic validation
- Better provider-specific examples
- Keychain-based API-key sample
- More tool schema examples
- Cancellation stress tests
- Public API review

Before beta:

- Stabilize core APIs
- Add complete README examples as executable examples
- Expand provider regression tests
- Improve docs around model behavior and failure modes
- Publish a tagged GitHub release

Before v1:

- API freeze
- production-ready examples
- package documentation comments review
- Swift Package Index readiness
- semantic versioning policy

---

## Relationship to LLMProviderKit

Use `LLMProviderKit` when you need:

```text
one provider abstraction
streaming/non-streaming LLM calls
model lists
provider-specific request/response translation
```

Use `SwiftAgentKit` when you need:

```text
an agent loop
tool calling
state
memory
planning
callbacks
events
session persistence
structured output
```

Most agentic apps will use both.

---

## License

MIT
