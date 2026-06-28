# SwiftAgentKit Claude Critique Remediation Plan

Status: active remediation plan for the first public alpha tag.

This document captures the technical critique from Claude, our verification against the current SwiftAgentKit/LLMProviderKit codebase, and the concrete work required before tagging `0.1.0-alpha.1`.

## Release judgment

SwiftAgentKit has strong architecture and is suitable for continued dogfooding, but the public alpha tag should wait until the strict-provider tool correlation path is fixed and covered by tests.

Current release interpretation:

- Private/local dogfood alpha: acceptable.
- Public alpha claiming robust multi-provider tool calling: not yet.
- Beta/v1: not ready.

## Verified strengths

- Provider layer and agent layer are cleanly separated.
- SwiftAgentKit remains Foundation-oriented and UI-agnostic.
- Agent configuration supports several useful agent philosophies: single-shot, chat, ReAct, and planner + ReAct.
- Tool registry/dispatcher and skill registry use actors where appropriate.
- State and conversation abstractions are reusable across app types.
- Tolerant JSON/tool parsing is valuable for local models.
- Progressive-disclosure skills are a good token-saving design.
- Existing unit tests cover many pure logic paths without network dependency.
- README quality is strong and honest about alpha limitations.

## P0 blockers before public alpha tag

### P0-1: Stamp tool result correlation metadata in the dispatcher

Problem:

Tools commonly return `AgentToolResult.success(toolCallId: "", ...)`. The dispatcher currently trusts that returned value. For strict providers, the tool result must carry the exact model-provided tool-call ID.

Required fix:

- Add a helper that canonicalizes every `AgentToolResult` returned by `ToolDispatcher`.
- Force `toolCallId` to `AgentToolCall.id`.
- Force/fill `toolName` to `AgentToolCall.name`.
- Apply this to:
  - normal tool output
  - `afterTool` modified output
  - `beforeTool` intercepted output
  - `onToolError` recovered output
  - errors should already carry the right values, but the helper should still be safe.

Acceptance tests:

- A tool that returns an empty `toolCallId` is dispatched as a result with the original call ID.
- A callback/interceptor that returns an empty `toolCallId` is also stamped.

### P0-2: Fan out multiple tool results into one provider message per tool result

Problem:

`AgentMessage.toLLMMessage()` currently collapses multiple tool results into one `LLMMessage.tool(...)` using only the first call ID. Strict providers expect one result message per `tool_call_id` / `tool_use_id`.

Required fix:

- Keep `toLLMMessage()` for backward compatibility / single-message contexts.
- Add a conversion API that can fan out an `AgentMessage` into `[LLMMessage]`, e.g. `toLLMMessages()`.
- For `.tool` messages:
  - return one `LLMMessage.tool(content, toolCallId:)` per `AgentToolResult`.
  - each message must use that result's own `toolCallId`.
  - content should include useful tool name/status/result text.
- Update `Agent.run()` request construction to use the fan-out conversion.
- Update `Agent.stream()` if it converts conversation messages to provider messages.

Acceptance tests:

- Two tool results with IDs `call_1`, `call_2` produce two `LLMMessage` values.
- The first has `toolCallId == call_1`; the second has `toolCallId == call_2`.
- `Agent` request construction or a conversion helper uses the fan-out path.

### P0-3: Public source hygiene

Problem:

README is clean, but several public source comments still mention source/internal app names.

Required fix:

- Remove private/source app names from public source comments.
- Replace with generic wording such as “inspired by production app patterns.”

Acceptance tests:

- Grep/search over public `.swift` and `.md` files shows no private source app names.

## P1 before beta

### P1-1: Planner progress tracking

Problem:

`LLMPlanner.generatePlan()` creates `AgentPlanStep` with `targets == []`, while `updateProgress()` only matches on targets. Plan continuation can therefore keep nudging until max attempts.

Options:

1. Parse target keywords from plan steps.
2. Mark the first pending step complete after a successful relevant tool call.
3. Add explicit tool-to-step matching metadata in planner output.

Recommended alpha approach:

- Defer full planner semantics, but document limitation.
- Add a simple conservative fallback in beta: first pending step moves to completed after non-error tool result when no targets exist.

### P1-2: Confirmation flow

Problem:

`requiresConfirmation` and `toolConfirmationRequired` exist, but `ToolDispatcher` does not consult them. Currently guardrails must use `beforeTool`.

Recommended fix:

- Add confirmation decision callback plumbing before tool execution.
- If a tool requires confirmation and no confirmer is configured, fail closed or return a confirmation-required error depending on config.

### P1-3: Concurrent runs on the same Agent

Problem:

One `Agent` instance shares conversation/state and has mutable runtime properties. Concurrent `run()` calls are not documented or guarded.

Recommended fix:

- Document one-run-at-a-time semantics now.
- Later add a run lock or actor-isolate the runtime.

### P1-4: Streaming asymmetry

Problem:

`runStreaming()` is not true streaming for tool agents; `stream()` bypasses the full agent machinery.

Recommended fix:

- Document clearly in README and API comments.
- Consider renaming or adding true final-response streaming later.

## P2 later improvements

- Real token accounting using provider usage metadata.
- MCP client integration.
- Built-in reference tools with sandboxing.
- True final-response streaming after tool loop.
- More strict-provider integration tests using OpenAI and Anthropic.

## Execution order

1. Write this plan file.
2. Add regression tests for P0-1 and P0-2 if straightforward.
3. Implement dispatcher result stamping.
4. Implement fan-out conversion and update request construction.
5. Scrub public source comments.
6. Run `swift test`.
7. Run public hygiene scans.
8. Commit and push when green.

## Alpha tag gate

Do not tag `0.1.0-alpha.1` until:

- [x] P0-1 fixed and tested.
- [x] P0-2 fixed and tested.
- [x] P0-3 source hygiene scan passes.
- [x] `swift test` passes.
- [x] git status/diff reviewed.

## Progress log

### 2026-06-28

Completed P0 remediation pass:

- Added dispatcher-side result stamping so tool outputs, callback interceptions, and callback recoveries always carry the original model-provided `AgentToolCall.id` and tool name.
- Added `AgentMessage.toLLMMessages()` so a single `.tool(results:)` agent message fans out to one provider-level `LLMMessage.tool` per tool result.
- Updated `Agent.run()` and `Agent.stream()` provider request construction to use fan-out conversion.
- Added regression tests for strict tool-call ID stamping, callback-intercepted result stamping, and multi-tool result fan-out.
- Removed private/source app names from public Swift comments.
- Verified `swift test` passes with 54 tests.
