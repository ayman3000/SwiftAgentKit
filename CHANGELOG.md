# Changelog

All notable changes to SwiftAgentKit will be documented in this file.

## Unreleased

### Added
- Guard against overlapping `run(_:)` calls on the same `Agent` instance with `AgentError.runInProgress`.
- Regression coverage for same-instance concurrent run rejection.
- **Streaming with tools (prototype):** `runStreaming(_:)` now runs a real streaming ReAct loop — each turn is streamed, and the final (tool-free) turn streams its answer token-by-token instead of being yielded as a single post-hoc chunk. Turns that signal tool use are re-issued non-streaming to obtain reliable tool-call arguments, then tools execute and the loop continues. (Prototype: this path does not yet apply planning, skills, repair-retry, or lifecycle callbacks.) Regression coverage added.
- Wired up tool confirmation gating: tools with `requiresConfirmation == true` now require approval via the new `AgentCallbacks.onToolConfirmation` callback before executing (bypassed when autonomous mode is on). Without a handler the dispatcher fails closed — the tool is denied rather than run unconfirmed. Regression coverage added.

### Fixed
- Context-window trimming now evicts assistant tool_call turns together with their tool_result message(s), so history is never left with an orphaned tool_call or tool_result (strict providers such as OpenAI/Anthropic reject unpaired tool messages with HTTP 400). Applies to the message-count and token-budget trim paths.
- Plan progress now advances for target-less (LLM-generated) plans — the earliest unfinished step is completed on each successful tool call. Previously such plans never progressed, so plan-continuation nudged the model until it exhausted its attempt budget.
- Regression coverage for tool_call/tool_result pairing during trim and for target-less plan progress.
- **MCP**: all MCP requests are now bounded by a wall-clock timeout (`MCPManager.connectTimeout` / `requestTimeout`, and a per-tool timeout on `MCPToolBridge`) so a hung or unresponsive stdio server no longer blocks the caller forever. A failed/timed-out handshake now terminates the spawned server process instead of leaking it. `readResource` swallows per-server errors and tries the next connection instead of failing on the first server that doesn't own the URI. Server `stderr` is routed to `/dev/null` (an unread pipe could fill its buffer and stall the server). Argument conversion checks `Bool` before `Int` to avoid mis-sending a boolean as `1`/`0`.
- **Persistence**: `FileAgentMemoryStore` serializes `save`/`delete` so concurrent calls no longer race on the read-modify-write of `USER.md` and the memory index. `FileSessionStore` and `FileAgentGoalStore` now write atomically, avoiding truncated/corrupt files on crash.
- **StructuredOutput**: extraction now balances the first `{`/`[` directly and no longer does fragile code-fence stripping — fixing single-line ```` ```json {…} ```` fences, JSON string values containing ```` ``` ````, and root-level JSON arrays (`T == [Foo]`).
- **@Tool macro**: unsupported parameter types (optionals, arrays, enums, `Int32`/`Float`, custom types) and unusable label shapes (wildcard `_`, separate external/internal names) now emit a clear compile-time diagnostic instead of silently generating code that fails to compile. Supported parameter types are `String`, `Int`, `Double`, `Bool`.

### Changed
- **Breaking:** `AgentEvent.toolConfirmationRequired` no longer carries a `decision` closure (`case toolConfirmationRequired(call:)`); it is now an informational event. Approval decisions are made via `AgentCallbacks.onToolConfirmation`.

### Documentation
- Clarified `runStreaming(_:)` behavior for tool-using agents.
- Documented current `@Tool` macro alpha limitations.

## 0.1.0-alpha.4 - 2026-07-06

### Fixed
- Updated dependency constraints to LLMProviderKit 0.1.0-alpha.4.
- Preserved strict tool-call ID correlation through dispatcher stamping and tool-result fan-out.

### Added
- Optional `@Tool` macro support for reducing manual tool boilerplate.
