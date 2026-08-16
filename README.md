<p align="center">
  <h1 align="center">SwiftAgentKit</h1>
  <p align="center"><strong>Build AI agents in native Swift.</strong></p>
  <p align="center">Tools · Memory · Planning · Sessions · Callbacks · Events · Multi-provider</p>
  <p align="center">Powered by <a href="https://github.com/ayman3000/LLMProviderKit">LLMProviderKit</a></p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.2%2B-orange" alt="Swift 6.2+">
  <img src="https://img.shields.io/badge/platforms-macOS%2013%2B%20%7C%20iOS%2016%2B%20%7C%20tvOS%2016%2B%20%7C%20watchOS%209%2B%20%7C%20visionOS%201%2B-blue" alt="Platforms">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
  <img src="https://img.shields.io/badge/release-0.4.0--alpha-yellow" alt="Alpha">
</p>

<h2 align="center">Watch SwiftAgentKit in action</h2>

<p align="center">
  <a href="https://github.com/ayman3000/SwiftAgentKit/raw/main/Media/SwiftAgentKitExplainer.mp4">
    <img src="https://raw.githubusercontent.com/ayman3000/SwiftAgentKit/main/Media/SwiftAgentKitPreview.gif" width="800" alt="Animated preview of the SwiftAgentKit technical overview">
  </a>
</p>

<p align="center">
  <a href="https://github.com/ayman3000/SwiftAgentKit/raw/main/Media/SwiftAgentKitExplainer.mp4"><strong>▶ CLICK TO WATCH THE FULL 74-SECOND VIDEO</strong></a>
</p>

---

A modern AI agent framework for Swift. Native tool calling, conversation memory, planning, state, callbacks, session persistence, and a ReAct-style loop — all protocol-oriented, all Swift, zero UI dependencies. Designed for macOS/iOS apps, CLI agents, and local-first Ollama workflows. Works with **Ollama**, **OpenAI**, **Google Gemini**, and **Anthropic** through [LLMProviderKit](https://github.com/ayman3000/LLMProviderKit).

---

## Table of Contents

- [30-Second Example](#30-second-example)
- [Features](#features)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Examples](#examples)
- [MCP Server Integration](#mcp-server-integration)
- [Native macOS App Automation](#native-macos-app-automation-swiftagentkitmac)
- [iOS Simulator Automation](#ios-simulator-automation-swiftagentkitsimulator)
- [@Tool Macro (Optional)](#tool-macro-optional)
- [Design Principles](#design-principles)
- [Alpha Status](#alpha-status)
- [Contributing](#contributing)
- [License](#license)

---

## 30-Second Example

```swift
import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

// 1. Pick any provider
let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

// 2. Define a tool — any Swift struct conforming to AgentTool
struct CurrentTimeTool: AgentTool {
    let name = "current_time"
    let description = "Return the current date and time."
    let parameters = ToolParameters.empty

    func execute(context: ToolContext) async throws -> AgentToolResult {
        .success(toolCallId: context.callId, toolName: name,
                 result: Date().formatted(date: .complete, time: .standard))
    }
}

// 3. Create an agent — pass tools inline at init time
let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "You are a helpful assistant. Use tools when needed.",
    maxTurns: 6,
    tools: [CurrentTimeTool()]
))

// 4. Run — the model decides to call the tool, Swift executes it, results go back
let response = try await agent.run("What time is it? Use the tool.")
print(response)
```

That's a real agent — a tool-using loop where the model acts through your Swift code.

---

## Features

| Feature | Description |
|---|---|
| 🔧 **Tool system** | Define Swift tools with JSON-Schema parameters. Models call them natively. Sequential dispatch by default (opt-in parallel) + dedup. |
| ✨ **@Tool macro** | Optional `@Tool` macro converts Swift functions to `AgentTool` structs — less boilerplate. |
| 🧠 **Conversation memory** | Token-aware history that trims to fit the context window automatically. |
| 🧠 **Persistent memory store** | Markdown-based long-term memory the agent can read and write across sessions. |
| 🎯 **Goal tracking** | Track user requests as persistent goals with status and progress. |
| 📋 **Planning** | Optional planning step before execution for complex multi-step tasks. |
| 🔄 **Repair retry** | Nudges the model when tools fail instead of accepting false success. |
| 📊 **Plan continuation** | Nudges the model if it stops before completing a plan. |
| 🗂️ **Agent state** | Cross-turn key-value store with `{key}` prompt templating. |
| 📡 **Lifecycle callbacks** | 8 intercept-able hooks: beforeAgent, afterAgent, beforeModel, afterModel, beforeTool, afterTool, onModelError, onToolError. |
| 📡 **Event stream** | Observe starts, LLM calls, tool calls, tool results, retries, finish summaries. |
| 💾 **Session persistence** | Save/restore conversations via `SessionStore` protocol + `FileSessionStore`. |
| 📝 **Structured output** | Tolerant JSON extraction from imperfect model responses. |
| 🎯 **Progressive disclosure skills** | Inject domain instructions only when query keywords match — keeps prompts small for local models. |
| 🌊 **Streaming** | Token-by-token streaming for non-tool responses. |
| 🖥️ **Local LLMs** | Full Ollama support — run agents entirely offline. |
| ☁️ **Cloud providers** | OpenAI, Gemini, Anthropic — swap providers, keep everything else. |
| ⚡ **Async/await** | Native Swift concurrency throughout. No completion handlers. |
| 🔒 **Cancellation** | Cooperative cancellation between turns. |

### Provider support

| Provider | Tool calling | Streaming | Model discovery |
|---|---|---|---|
| **Ollama** | ✅ Native `tools` | ✅ | ✅ `GET /api/tags` |
| **OpenAI** | ✅ Native `tools` + `tool_choice` | ✅ | ✅ `GET /v1/models` |
| **Gemini** | ✅ `functionDeclarations` | ✅ | ✅ `GET /v1beta/models` |
| **Anthropic** | ✅ `tool_use` content blocks | ✅ | ✅ Curated list |

---

## Architecture

### Two-layer stack

```mermaid
graph TD
    APP["Your Swift App<br/>SwiftUI / AppKit / CLI / Server"]
    SAK["SwiftAgentKit<br/>Agent loop · Tools · Memory · State<br/>Planning · Callbacks · Events · Sessions"]
    LPK["LLMProviderKit<br/>Provider protocol · Request/Response · Streaming"]
    OLLAMA["Ollama<br/>Local"]
    OPENAI["OpenAI<br/>Cloud"]
    GEMINI["Gemini<br/>Cloud"]
    ANTHROPIC["Anthropic<br/>Cloud"]

    APP --> SAK
    SAK --> LPK
    LPK --> OLLAMA
    LPK --> OPENAI
    LPK --> GEMINI
    LPK --> ANTHROPIC

    style APP fill:#4A90D9,stroke:#2C5F8A,stroke-width:2px,color:#fff
    style SAK fill:#9B59B6,stroke:#6C3483,stroke-width:3px,color:#fff
    style LPK fill:#E67E22,stroke:#A04500,stroke-width:2px,color:#fff
    style OLLAMA fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
    style OPENAI fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
    style GEMINI fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
    style ANTHROPIC fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
```

SwiftAgentKit does **not** implement provider networking itself. It depends on `LLMProviderKit`'s `LLMProvider` protocol, so the same agent can run on local or cloud models.

### Agent loop

On each `run()` call the agent appends the user message, optionally generates a plan, then enters a ReAct loop: it sends the conversation + tool definitions to the model, parses any tool calls, executes them in Swift (sequential by default, deduplicated, ID-stamped; set `parallelToolCalls` to run a turn's calls concurrently), feeds results back, and repeats until the model returns a final answer or `maxTurns` is reached. Callbacks and events fire at every stage; repair-retry and plan-continuation nudge the model back on track when needed.

### Package layout

```
Sources/SwiftAgentKit/
├── Core/
│   ├── Agent.swift              # AgentConfig + main Agent runtime
│   ├── AgentMessage.swift       # Messages, tool calls, tool results
│   ├── AgentState.swift         # Cross-turn key-value state + {key} templating
│   ├── AgentCallbacks.swift     # 8 intercept-able lifecycle hooks
│   ├── AgentSkill.swift         # Progressive-disclosure skills
│   ├── AgentEvent.swift         # Event stream + run summaries
│   ├── AgentError.swift         # Typed errors
│   └── AgentLLMResponse.swift   # Provider response bridge
├── Tools/
│   ├── AgentTool.swift          # Tool protocol + JSON-Schema params
│   ├── ToolContext.swift        # Rich context (state, call info, actions)
│   └── ToolDispatcher.swift     # Sequential/parallel dispatch, dedup, confirmation
├── Memory/
│   ├── Conversation.swift       # Token-aware conversation history
│   ├── SessionStore.swift      # Session persistence protocol + file store
│   ├── AgentMemoryStore.swift   # Long-term memory store protocol + file-backed impl
│   └── RememberTool.swift       # Built-in tool for agents to persist memory
├── Planning/
│   ├── AgentPlan.swift          # Plan model + LLMPlanner
│   ├── AgentGoal.swift          # Goal model + goal store persistence
│   └── RepairRetryPolicy.swift  # Repair-retry + plan continuation
├── StructuredOutput/
│   └── StructuredOutput.swift   # Tolerant JSON extraction
├── Logging/
│   └── AgentLogger.swift        # Lightweight logger
Sources/SwiftAgentKitMCP/
├── MCPClientConfig.swift        # stdio/HTTP connection config
├── MCPToolBridge.swift          # MCP Tool → AgentTool bridge
└── MCPManager.swift             # Connection lifecycle + tool discovery
```

---

## Quick Start

### Installation

**Xcode:** File ▸ Add Package Dependencies → add `https://github.com/ayman3000/SwiftAgentKit` and `https://github.com/ayman3000/LLMProviderKit`

**Package.swift:**

```swift
.dependencies: [
    .package(url: "https://github.com/ayman3000/SwiftAgentKit.git", from: "0.3.0-alpha.52"),
    .package(url: "https://github.com/ayman3000/LLMProviderKit.git", from: "0.1.0-alpha.14"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
        .product(name: "LLMProviderKit", package: "LLMProviderKit"),
        .product(name: "LLMProviderKitOllama", package: "LLMProviderKit"),
        // Add the providers you need:
        // .product(name: "LLMProviderKitOpenAI", package: "LLMProviderKit"),
        // .product(name: "LLMProviderKitGemini", package: "LLMProviderKit"),
        // .product(name: "LLMProviderKitAnthropic", package: "LLMProviderKit"),
    ])
]
```

### First agent

```swift
import SwiftAgentKit
import LLMProviderKit
import LLMProviderKitOllama

let provider = OllamaProvider(configuration: .local(model: "llama3.2"))

let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "You are a helpful Swift assistant.",
    maxTurns: 1
))

let answer = try await agent.run("Explain async/await in one sentence.")
print(answer)
```

### First tool

```swift
struct EchoTool: AgentTool {
    let name = "echo"
    let description = "Echo a message back."
    let parameters = ToolParameters(
        properties: ["message": ToolParameterProperty(type: "string", description: "Message to echo")],
        required: ["message"]
    )

    func execute(context: ToolContext) async throws -> AgentToolResult {
        let msg = context.parameters["message"] as? String ?? ""
        return .success(toolCallId: context.callId, toolName: name, result: "Echo: \(msg)")
    }
}

let agent = Agent(config: AgentConfig(
    provider: provider,
    maxTurns: 6,
    tools: [EchoTool()]
))
let response = try await agent.run("Echo the message 'Hello from SwiftAgentKit!'")
```

---

## Examples

### Tool calling

```swift
struct CurrentTimeTool: AgentTool {
    let name = "current_time"
    let description = "Return the current date and time."
    let parameters = ToolParameters.empty

    func execute(context: ToolContext) async throws -> AgentToolResult {
        .success(toolCallId: context.callId, toolName: name,
                 result: Date().formatted(date: .complete, time: .standard))
    }
}

let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "You are a helpful assistant. Use tools when needed.",
    maxTurns: 6
))
await agent.register(CurrentTimeTool())

let response = try await agent.run("What time is it? Use the tool.")
```

### Multiple tools

Tool calls in a turn run **sequentially by default**, in the order the model issued them — models routinely emit order-dependent batches (write a file then read it, several patches to one file). If your tools are safe to interleave, opt in with `AgentConfig(parallelToolCalls: true)` and a turn's calls run concurrently (deduplicated, order of results preserved).

```swift
struct CalculatorTool: AgentTool {
    let name = "calculator"
    let description = "Calculate a basic arithmetic expression."
    let parameters = ToolParameters(
        properties: ["expression": ToolParameterProperty(type: "string", description: "e.g. 38 * 17")],
        required: ["expression"]
    )

    func execute(context: ToolContext) async throws -> AgentToolResult {
        let expr = context.parameters["expression"] as? String ?? ""
        // Replace with a real safe parser in production
        if expr.trimmingCharacters(in: .whitespaces) == "38 * 17" {
            return .success(toolCallId: context.callId, toolName: name, result: "646")
        }
        return .error(toolCallId: context.callId, toolName: name, message: "Unsupported expression.")
    }
}

await agent.registerAll([CurrentTimeTool(), EchoTool(), CalculatorTool()])
let result = try await agent.run("Get the time, echo 'hello', then calculate 38 * 17.")
```

When the model requests multiple tools in one turn, SwiftAgentKit executes them sequentially in the order the model issued them (concurrently when `parallelToolCalls` is enabled) and preserves order when feeding results back.

### Persistent memory

SwiftAgentKit supports long-term, cross-session memory. The app chooses where memory lives — the library never hardcodes a folder name.

```swift
import Foundation
import SwiftAgentKit

// App names the folder; SwiftAgentKit provides a convenience helper
let store = FileAgentMemoryStore.defaultStore(named: "myapp")

// Or use any explicit directory URL
// let store = FileAgentMemoryStore(directory: fileURL)

let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "You are a helpful assistant. Remember user facts across sessions.",
    maxTurns: 6
))

// Attaching a memory store:
// 1. Injects the memory context block into the system prompt
// 2. Auto-registers the built-in `remember` tool
try await agent.setMemoryStore(store)
```

The file-backed store uses a markdown layout similar to production agent patterns:

```
~/.myapp/
├── AGENT.md          # Agent identity / instructions
├── USER.md           # User profile
├── MEMORY.md         # Index / summary of facts
└── memory/
    ├── fact-001.md   # Individual fact
    └── fact-002.md
```

### Goal tracking

Track user requests as persistent goals. Enable tracking on any `run(_:)` call and the agent saves the goal with final status and a summary.

```swift
let goalStore = FileAgentGoalStore(directory: someDirectoryURL)
try await agent.setGoalStore(goalStore)

let answer = try await agent.run("Analyze this project and write a README summary.", trackGoal: true)

// Later, inspect or resume goals
let goals = try await goalStore.loadAll()
for goal in goals {
    print(goal.status, goal.query, goal.summary ?? "")
}
```

Goals carry status (`pending`, `inProgress`, `completed`, `failed`, `abandoned`), a progress percentage derived from the active plan, and a final summary once the run finishes.

### Streaming

```swift
// Simple non-tool responses — token by token
for try await chunk in agent.runStreaming("Tell me a short story about Swift actors.") {
    print(chunk, terminator: "")
}

// Tool-using agents — same API: the loop runs, tools execute, text streams
for try await chunk in agent.runStreaming("Use tools, then summarize.") {
    print(chunk, terminator: "")
}
```

> `runStreaming` shares the exact ReAct lifecycle used by `run(_:)` — planning, tools, repair-retry, callbacks. Tool-calling turns are re-issued non-streaming internally (tool calls need complete model responses), so don't rely on token-by-token visibility during tool execution. `stream(_:)` is a deprecated alias of `runStreaming(_:)`; earlier releases gave it a reduced path that dropped tool calls.

### Event monitoring

```swift
agent.onEvent { event in
    switch event {
    case .started(let query):
        print("Started:", query)
    case .llmCallStarted(let turn):
        print("LLM call — turn \(turn)")
    case .toolCallsReceived(let calls):
        print("Tools:", calls.map(\.name).joined(separator: ", "))
    case .toolExecutionFinished(let call, let result):
        print("✓ \(call.name): \(result.isError ? "ERROR" : "OK")")
    case .finished(let summary):
        print("Done: \(summary.totalTurns) turns, \(summary.toolsExecuted) tools, \(String(format: "%.1f", summary.elapsed))s")
    default: break
    }
}
```

Perfect for debug panels, progress UIs, and audit logs.

### Callbacks + guardrails

```swift
var callbacks = AgentCallbacks()

// Block destructive requests
callbacks.beforeAgent = { query, state in
    query.lowercased().contains("delete everything")
        ? "I can't perform destructive actions without confirmation."
        : nil
}

// Block dangerous tools
callbacks.beforeTool = { call, context in
    call.name == "delete_file"
        ? .error(toolCallId: call.id, toolName: call.name, message: "Blocked by policy.")
        : nil
}

// Post-process responses
callbacks.afterAgent = { response, state in
    response.trimmingCharacters(in: .whitespacesAndNewlines)
}

try await agent.setCallbacks(callbacks)
```

### Planning

```swift
let agent = Agent(config: AgentConfig(
    provider: provider,
    systemPrompt: "You are a systematic implementation assistant.",
    maxTurns: 12,
    enablePlanning: true,
    enablePlanContinuation: true,
    enableRepairRetry: true
))

await agent.registerAll([ReadFileTool(), WriteFileTool(), ListFilesTool()])
let result = try await agent.run("Inspect this project and write a README summary.")
```

Planning is optional. Keep it off for simple tasks; enable it for multi-step workflows.

---

## MCP Server Integration

SwiftAgentKit can connect to any [Model Context Protocol](https://modelcontextprotocol.io) server and use its tools as native `AgentTool`s. This gives your agents instant access to the growing MCP ecosystem — filesystem, GitHub, databases, browser automation, and more — without writing tools in Swift.

MCP support is an **optional product** (`SwiftAgentKitMCP`) so it doesn't add weight to the core library.

### Installation

Add `SwiftAgentKitMCP` to your dependencies:

```swift
.dependencies: [
    .package(url: "https://github.com/ayman3000/SwiftAgentKit.git", from: "0.3.0-alpha.52"),
    .package(url: "https://github.com/ayman3000/LLMProviderKit.git", from: "0.1.0-alpha.14"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
        .product(name: "SwiftAgentKitMCP", package: "SwiftAgentKit"),
        .product(name: "LLMProviderKitOllama", package: "LLMProviderKit"),
    ])
]
```

### Usage

```swift
import SwiftAgentKit
import SwiftAgentKitMCP
import LLMProviderKitOllama

let agent = Agent(config: AgentConfig(
    provider: OllamaProvider(configuration: OllamaProvider.local(model: "llama3.2")),
    systemPrompt: "You are a helpful assistant with filesystem tools.",
    maxTurns: 10
))

// Connect to MCP servers — tools are auto-discovered and bridged
let mcp = MCPManager()
try await mcp.connect(.stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]))
try await mcp.connect(.http(endpoint: URL(string: "http://localhost:8080")!))

// Bridge all MCP tools into the agent
for tool in try await mcp.bridgedTools() {
    await agent.register(tool)
}

// Run — the agent can now use filesystem tools
let response = try await agent.run("List the files in /tmp and summarize what's there.")
print(response)

// Clean up when done
await mcp.disconnectAll()
```

### What's supported

- **Stdio transport** — connect to local MCP servers via subprocess
- **HTTP transport** — connect to remote MCP servers
- **Tool discovery** — `listTools()` → `AgentTool` bridge (name, description, schema, execution)
- **Resource discovery** — `listResources()` → `MCPResourceInfo`, `readResource(uri:)`, `resourcesContextBlock()`
- **Multi-server** — connect to multiple MCP servers simultaneously; all tools and resources merge

### What's not yet supported

- MCP prompts, completions, sampling, elicitation — tools and resources only for now
- MCP server hosting (SwiftAgentKit is a client, not a server)

---

## Native macOS App Automation (SwiftAgentKitMac)

`SwiftAgentKitMac` is a **macOS-only** optional product that gives your agent a set of tools for driving native macOS applications via the Accessibility API — snapshot the UI tree, click elements, type text, press key combos, wait for UI changes, launch apps, and list running processes.

### Installation

Add `SwiftAgentKitMac` to your target dependencies:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
    .product(name: "SwiftAgentKitMac", package: "SwiftAgentKit"),
])
```

### One-call registration

```swift
import SwiftAgentKit
import SwiftAgentKitMac

// The allowlist provider returns the set of bundle IDs the current conversation
// is permitted to drive. The toggle, allowlist, and confirmation UX all live
// in your app — SwiftAgentKitMac enforces the boundary but does not own it.
let client = AXClient()
let tools = makeMacTools(
    allowlistProvider: { conversationAllowlist },
    client: client
)
await agent.registerAll(tools)
```

### What the agent can do

| Tool | Description |
|---|---|
| `mac_apps` | List running macOS applications (name + bundle ID) |
| `mac_ui` | Snapshot the Accessibility tree of a running app |
| `mac_click` | Click an element by ref, title, or identifier |
| `mac_type` | Type text into the focused element or a targeted element |
| `mac_key` | Press a key combo (e.g. `cmd+s`, `return`, `tab`) |
| `mac_wait` | Wait event-driven until an element appears or disappears |
| `mac_launch` | Launch an app by bundle ID |

### Three-brake safety model

Every mac_* tool passes through three independent safety gates before touching the Accessibility driver:

- **Off-by-default toggle** — the consumer app controls whether mac automation is enabled at all; a disabled toggle blocks all tools before any AX call.
- **Per-conversation allowlist** — each conversation maintains a set of permitted bundle IDs; a tool call for any app not in the set is denied with a model-facing error asking the user to approve it.
- **Per-action confirmation** — the consuming app can require explicit user confirmation before any destructive action (click, type, key) is dispatched.

The toggle, allowlist, and confirmation UX all live in the consuming application. `SwiftAgentKitMac` enforces the boundary but does not own the policy.

### Accessibility permission

macOS requires Accessibility access before any AX API call can succeed. The test runner (Terminal, your app's process) must be listed under **System Settings → Privacy & Security → Accessibility**. `AXPermission.isTrusted()` returns `false` and all AX tools fail with a model-facing error until this grant is present.

```swift
// Check trust status (nonisolated, safe to call from anywhere)
guard AXPermission.isTrusted() else { /* prompt or inform the user */ }

// Optionally prompt the user via the system dialog
AXPermission.promptForTrust()
```

### Live end-to-end test

The live test requires AX granted to the `swift test` runner **and** two environment variables:

```bash
SAK_LIVE_TESTS=1 SAK_MAC_TESTS=1 swift test --filter MacLiveTests
```

The test launches TextEdit, waits for the app's AX tree to appear, types into the focused text area, and takes a final snapshot asserting the AX tree is reachable. If Accessibility is not granted to the shell running `swift test`, the test XCTSkips automatically — no false pass.

### Testing / known limitation

The live test fully exercises snapshot/type/verify from a properly code-signed host (e.g. Naseem.app). Under `swift test` (ad-hoc signed) on macOS 26, the Accessibility server returns self-referential results for the AX root, hiding window content — the live test falls back to asserting the menu bar is captured, confirming real AX data is being read. Full window-content end-to-end verification is validated in the signed Naseem app.

---

## iOS Simulator Automation (SwiftAgentKitSimulator)

`SwiftAgentKitSimulator` is a **macOS-only** optional product that gives your agent a set of tools for driving real iOS simulators — launch apps, inspect UI trees, tap elements, type text, install builds, and capture screenshots — all through an XCUITest-backed driver that runs inside the simulator.

### Installation

Add `SwiftAgentKitSimulator` to your target dependencies:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
    .product(name: "SwiftAgentKitSimulator", package: "SwiftAgentKit"),
])
```

### One-call registration

```swift
import SwiftAgentKit
import SwiftAgentKitSimulator

// Register all simulator tools with the agent in one call.
// manager handles driver build + launch on first use.
let manager = SimDriverManager()
let session = SimSession()
let client = await SimClient(manager: manager, udid: udid, runtime: runtime)
await agent.registerAll(makeSimulatorTools(session: session, client: client))
```

The first time the driver is used for a given Xcode / runtime pair it builds the XCUITest harness (~30–60 s); subsequent runs reuse the cached build.

### What the agent can do

| Tool | Description |
|---|---|
| `sim_list` | List all available iOS simulators with their UDID, name, runtime, and boot state |
| `sim_boot` | Boot an iOS simulator by UDID or name; sets the active device for subsequent sim_* calls |
| `sim_launch` | Launch an app by bundle ID in the currently booted simulator |
| `sim_terminate` | Terminate a running app in the simulator |
| `sim_ui` | Read the current UI of the iOS simulator app as an accessibility tree with element refs and labels |
| `sim_tap` | Tap (or long-press) an element in the simulator by ref/label/identifier |
| `sim_type` | Type text into the focused field or a target element in the simulator |
| `sim_swipe` | Swipe in a direction (up/down/left/right) on the simulator screen or a specific element |
| `sim_press` | Press a hardware button on the simulator (currently supports home) |
| `sim_wait` | Wait event-driven until an element exists or disappears, then return the fresh UI tree |
| `sim_alert` | Accept or dismiss the currently visible system alert in the simulator |
| `sim_screenshot` | Capture a PNG screenshot of the simulator screen |
| `sim_build_install` | Build an Xcode project or workspace and install the resulting app on the simulator |
| `sim_logs` | Stream simulator app logs to a temp file (non-blocking) or stop a previous stream |

### Live end-to-end test

The live test is gated behind two environment variables so it never runs in CI without an attached simulator:

```bash
SAK_LIVE_TESTS=1 SAK_SIM_TESTS=1 swift test --filter SimLiveTests
```

The test launches the iOS Settings app, waits for the General row, taps it, waits for the About row, and asserts that a screenshot is a valid PNG (> 10 KB). First run includes the driver build.

---

## @Tool Macro (Optional)

Use the `@Tool` macro to convert any Swift function into an `AgentTool` with less boilerplate:

```swift
import SwiftAgentKit

struct MyTools {
    @Tool("Return the current date and time.")
    func currentTime() async throws -> String {
        Date().formatted(date: .complete, time: .standard)
    }

    @Tool("Calculate a basic arithmetic expression.")
    func calculator(expression: String) async throws -> String {
        "646"
    }
}

let tools = MyTools()
let agent = Agent(config: AgentConfig(
    provider: provider,
    maxTurns: 6,
    tools: [tools.currentTimeTool(), tools.calculatorTool()]
))
```

The macro generates an `AgentTool`-conforming struct with a snake_case name, JSON-Schema parameters from the function signature (String, Int, Double, Bool), result wrapping with `context.callId`, and a `funcNameTool()` factory that captures `self`.

Current alpha limitations: parameters are generated as required; only primitive types are supported (use manual `AgentTool` for arrays, nested objects, or enums); grouped `- Parameters:` DocC blocks aren't fully parsed yet. The `AgentTool` protocol remains the primary API — the macro is optional.

---

## Design Principles

1. **Native Swift first.** Built for Swift developers who want agents in their apps — not a port or a wrapper. Protocol-oriented, async/await throughout, zero UI dependencies.
2. **Minimal dependencies.** The core agent runtime uses Foundation + LLMProviderKit only. SwiftSyntax is pulled in solely for the `@Tool` macro target, and the MCP Swift SDK only by the optional MCP target — import only the products you need. Local-first capable with Ollama as a first-class provider.
3. **Composable.** Use what you need — tools without planning, memory without sessions, state without skills. Every feature is independent.
4. **Provider-agnostic.** Swap Ollama for OpenAI, Gemini, or Anthropic; the agent code doesn't change. Everything (`AgentTool`, `LLMProvider`, `SessionStore`, `AgentPlanner`) is a protocol.

---

## Alpha Status

**Breaking changes:**
- **0.4.0:** `Agent` is now an actor. Configure via construction or `try await agent.set…(…)` (idle-only); `register`/`setAutonomousMode` remain callable any time. Streaming APIs are unchanged.
- `lastPromptTokens` is now actor-isolated; read it with `await agent.lastPromptTokens`.
- `config` is immutable after construction (`let`), and `setToolContext(_:)` requires a freshly built (region-disconnected) dictionary under Swift 6.

**Known alpha limitations:**
- Public APIs may change before beta
- Provider behavior varies by model quality — some models ignore tools even when available
- `stream(_:)` is deprecated (alias of `runStreaming(_:)`); `runStreaming(_:)` does not stream intermediate tool-loop tokens
- One `Agent` instance is intended for one active `run(_:)` at a time
- The `@Tool` macro is best for primitive required parameters; use manual `AgentTool` definitions for complex schemas

Feedback from real Swift apps is very welcome.

**Build and test:**

```bash
swift build
swift test
```

358 tests (115 XCTest + 243 Swift Testing) across the core loop, tools, context management, replay, and MCP — no network calls.

**Tool security** (SwiftAgentKitTools):

- `import_skill` requires confirmation and refuses URLs that are — or resolve to — private, loopback, or link-local addresses (SSRF guard); redirects are re-validated and downloads are memory-bounded.
- Filesystem tools accept an optional `FileToolPolicy(allowedRoots:)` that canonicalizes paths (tilde, `..`, symlinks) before checking containment — opt-in; without a policy they remain unrestricted.
- `run_shell` and `run_python` both run commands in their own process group and SIGKILL the whole group on timeout, so orphaned children can't hang a run.

---

## Contributing

Issues, pull requests, and feedback are all welcome.

- 🐛 [Open an issue](https://github.com/ayman3000/SwiftAgentKit/issues)
- 🔀 [Submit a pull request](https://github.com/ayman3000/SwiftAgentKit/pulls)

---

## License

MIT