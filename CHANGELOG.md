# Changelog

All notable changes to SwiftAgentKit will be documented in this file.

## Unreleased

### Fixed
- **ContextSift: single-shot retrieval to avoid paging loops.** `artifact_read`'s default read limit is raised 8000 → 24000 so a retrieval typically returns the whole artifact in one call. Paginated reads (repeated "call again with offset…") could make weaker models loop instead of converging. Validated live against `glm-5.2:cloud` (a large >8k tool output resolves with no retrieval spiral). Gated live regression added (`liveContextSiftNoArtifactReadLoop`).
- **ContextSift: stop the `artifact_read` retrieval loop.** A large *active* tool result was bounded to `maxActiveResultChars` and spilled to an artifact with a "use artifact_read" hint; when the model then called `artifact_read`, that retrieval result was *itself* re-truncated and re-spilled — so the model kept calling `artifact_read` to "get the full output" that never fully surfaced (observed as ~6 repeated `artifact_read` calls until `maxTurns` ran out). Fix: retrieval tools (`artifact_read`, `artifact_search`) are now exempt from active-display truncation and receipt spilling — their output is shown in full (the tools already page via `offset`/`limit`). Also raised the default `maxActiveResultChars` 2000 → 8000 so ordinary tool outputs fit inline without any artifact round-trip. Regression coverage added (an active `artifact_read` result larger than the bound is shown in full, never re-truncated).

### Added
- **Self-improving skills — persist skills the agent authors at runtime.** New `AgentSkillStore` protocol + `FileAgentSkillStore` (one human-editable markdown file per skill: `# name` / `Triggers:` / instructions) and a built-in `LearnSkillTool` (`learn_skill`). Set `agent.skillStore = …` and the agent (a) loads previously authored skills into its `SkillRegistry` and (b) auto-registers `learn_skill` — so it can turn a recurring task, or a corrected mistake, into a reusable keyword-triggered skill that fires immediately (added to the live registry) and persists across sessions. Mirrors the `memoryStore` → `RememberTool` pattern. Regression coverage added (store round-trip; `learn_skill` persists + activates on a matching query).
- **`SwiftAgentKitTools` — a new opt-in product of ready-made native tools.** Import it and register the ones you want; the app supplies the confirmation UI/policy via `AgentCallbacks.onToolConfirmation`.
  - **Filesystem** (Foundation-only, cross-platform): `read_file` (paged), `write_file` (append/overwrite, `requiresConfirmation`), `list_dir`, `search_files` (name and/or content substring, bounded traversal).
  - **Shell** (`run_shell`, `requiresConfirmation`, macOS-only via `#if os(macOS)`): runs `zsh -lc`, reads to EOF (no pipe deadlock), bounded output, configurable default working directory. Promoted from the Naseem app so any consumer gets it.
  - **PDF** (`#if canImport(PDFKit)`): `pdf_info`, `pdf_extract_text` (page range, bounded), `pdf_merge` / `pdf_split` (`requiresConfirmation`). Gated so the package still builds on platforms without PDFKit.
  - Read tools are unconfirmed; tools that mutate disk are `requiresConfirmation`. New `SwiftAgentKitToolsTests` target (filesystem round-trips, search, shell exit/cwd, PDF merge→split).
- **Autonomous mode.** `AgentConfig(autonomousMode:)` (default `false`) and a runtime `Agent.setAutonomousMode(_:)` / `ToolDispatcher.setAutonomousMode(_:)` let an app skip the `requiresConfirmation` gate so the agent runs confirmation-required tools without prompting `AgentCallbacks.onToolConfirmation`. Off by default (confirmation-gated / fail-closed unchanged); flip it on for full-autonomy runs. Regression coverage added (autonomous mode bypasses the gate with no handler present).
- **Context management (ContextSift), opt-in.** A new `ContextManager` (in `Sources/SwiftAgentKit/Context/`) keeps the main user/assistant conversation intact while externalizing *completed* tool exchanges: each finished tool result becomes a compact one-line receipt in a tool ledger (folded into the system prompt), and its full output is offloaded to an `ArtifactStore` (default `InMemoryArtifactStore`) so it can be retrieved losslessly on demand rather than resent every turn. The single in-flight ("active") tool exchange is preserved in full (bounded by `maxActiveResultChars`), so the model always has what it needs to act next. Two retrieval tools — `artifact_read` (paged) and `artifact_search` (line-level substring) — are auto-registered when a `ContextManager` is set, letting the model pull back any offloaded output by its `artifact-…` id. Enable per-agent via `AgentConfig(contextManager:)`; leaving it `nil` preserves the previous behavior exactly (`makeLLMRequest` is unchanged when unset). Ports the Python ContextSift approach (compact receipts + artifact store + on-demand retrieval) into the framework. Regression coverage added (completed exchanges → ledger + artifact and dropped from context; active exchange kept; large results spilled and round-tripped via `artifact_read`; artifact store read/search).
- Guard against overlapping `run(_:)` calls on the same `Agent` instance with `AgentError.runInProgress`.
- Regression coverage for same-instance concurrent run rejection.
- `Conversation.tokenCounter` — an injectable synchronous token counter that overrides the built-in heuristic used for context-window trimming, so apps can plug in an exact per-provider tokenizer (or cached count-tokens results) for precise trimming. Regression coverage added.

### Changed
- Context-window token estimation is now more conservative by default: `charsPerToken` lowered 4.0 → 3.5 and a per-message framing overhead (`tokensPerMessageOverhead`, default 4) is added, so trimming errs toward staying under the real window for code/JSON/non-ASCII-heavy histories.
- `Agent.removeObserver(_:)` and a return value from `onEvent(_:)` (the observer token, `@discardableResult`) so observers can be detached. Prevents observer accumulation when a long-lived agent outlives the views observing it. Regression coverage added.
- Gated live-model smoke test (`liveOllamaStreamingWithToolCall`) exercising streaming-with-tools end-to-end against a real Ollama model (`glm-5.2:cloud`). Runs only when `SAK_LIVE_TESTS=1`, so CI and normal `swift test` stay hermetic (the test is skipped otherwise).
- **Streaming with tools:** `runStreaming(_:)` streams assistant text token-by-token — including the final answer — instead of yielding it as a single post-hoc chunk. It now shares the exact ReAct implementation as `run(_:)` (planning, skills, repair-retry, lifecycle callbacks, and events all apply) via a common `runLoop(onText:)`; the streaming vs non-streaming difference is isolated to a single per-turn executor. Turns that signal tool use are re-issued non-streaming to obtain reliable tool-call arguments, then tools execute and the loop continues. Regression coverage added (streamed answer after a tool turn; event-parity with `run`).
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
