# Changelog

All notable changes to SwiftAgentKit will be documented in this file.

## Unreleased

### Added
- Guard against overlapping `run(_:)` calls on the same `Agent` instance with `AgentError.runInProgress`.
- Regression coverage for same-instance concurrent run rejection.

### Fixed
- **MCP**: all MCP requests are now bounded by a wall-clock timeout (`MCPManager.connectTimeout` / `requestTimeout`, and a per-tool timeout on `MCPToolBridge`) so a hung or unresponsive stdio server no longer blocks the caller forever. A failed/timed-out handshake now terminates the spawned server process instead of leaking it. `readResource` swallows per-server errors and tries the next connection instead of failing on the first server that doesn't own the URI. Server `stderr` is routed to `/dev/null` (an unread pipe could fill its buffer and stall the server). Argument conversion checks `Bool` before `Int` to avoid mis-sending a boolean as `1`/`0`.
- **Persistence**: `FileAgentMemoryStore` serializes `save`/`delete` so concurrent calls no longer race on the read-modify-write of `USER.md` and the memory index. `FileSessionStore` and `FileAgentGoalStore` now write atomically, avoiding truncated/corrupt files on crash.
- **StructuredOutput**: extraction now balances the first `{`/`[` directly and no longer does fragile code-fence stripping — fixing single-line ```` ```json {…} ```` fences, JSON string values containing ```` ``` ````, and root-level JSON arrays (`T == [Foo]`).
- **@Tool macro**: unsupported parameter types (optionals, arrays, enums, `Int32`/`Float`, custom types) and unusable label shapes (wildcard `_`, separate external/internal names) now emit a clear compile-time diagnostic instead of silently generating code that fails to compile. Supported parameter types are `String`, `Int`, `Double`, `Bool`.

### Documentation
- Clarified `runStreaming(_:)` behavior for tool-using agents.
- Documented current `@Tool` macro alpha limitations.

## 0.1.0-alpha.4 - 2026-07-06

### Fixed
- Updated dependency constraints to LLMProviderKit 0.1.0-alpha.4.
- Preserved strict tool-call ID correlation through dispatcher stamping and tool-result fan-out.

### Added
- Optional `@Tool` macro support for reducing manual tool boilerplate.
