# Architecture

Detailed engineering diagrams for SwiftAgentKit's internals.

## Agent ReAct loop

The complete decision tree the agent follows on every `run()` call. **Follow the green path for the happy path** — blue is input, purple is SwiftAgentKit internals, orange is LLM calls, green is success, red is error handling:

```mermaid
flowchart TD
    START(("agent.run(query)"))
    START --> BEFORE_AGENT{"beforeAgent<br/>callback?"}
    BEFORE_AGENT -- "returns value" --> SHORT_CIRCUIT["Return intercepted<br/>response immediately"]
    BEFORE_AGENT -- "nil / no callback" --> ADD_USER["Append user message<br/>to conversation"]

    ADD_USER --> TOOLS["Get registered tools<br/>strengthen system prompt<br/>'You MUST use tools...'"]
    TOOLS --> SKILLS{"Query matches<br/>skill keywords?"}
    SKILLS -- "Yes" --> INJECT_SKILLS["Inject matching skill<br/>instructions into prompt"]
    SKILLS -- "No" --> PLAN_CHECK
    INJECT_SKILLS --> PLAN_CHECK{"Planning enabled?<br/>planner.shouldPlan()"}
    PLAN_CHECK -- "Yes" --> PLAN["Generate plan via LLM<br/>emit planGenerated<br/>add plan to conversation"]
    PLAN_CHECK -- "No" --> LOOP_ENTRY

    PLAN --> LOOP_ENTRY{{"Agent Loop — turn N"}}
    LOOP_ENTRY --> CANCEL{"Cancelled?"}
    CANCEL -- "Yes" --> CANCELLED["throw AgentError.cancelled"]
    CANCEL -- "No" --> TRIM["Get messages<br/>trim to context window<br/>emit historyTrimmed if needed"]

    TRIM --> LLM_START["emit llmCallStarted"]
    LLM_START --> BEFORE_MODEL{"beforeModel<br/>callback?"}
    BEFORE_MODEL -- "returns value" --> USE_INTERCEPT["Use intercepted response"]
    BEFORE_MODEL -- "nil / no callback" --> BUILD_REQ["Build LLMRequest<br/>state-templated system prompt<br/>+ tool definitions"]
    USE_INTERCEPT --> HAS_TOOLS_1

    BUILD_REQ --> CALL_LLM["provider.complete(request)"]
    CALL_LLM --> LLM_ERROR{"LLM call<br/>failed?"}
    LLM_ERROR -- "Yes" --> ON_MODEL_ERROR{"onModelError<br/>callback?"}
    ON_MODEL_ERROR -- "returns fallback" --> USE_FALLBACK["Use fallback response"]
    ON_MODEL_ERROR -- "nil / no callback" --> THROW_PROVIDER["throw AgentError.providerError"]
    USE_FALLBACK --> HAS_TOOLS_1{"Response has<br/>tool calls?"}
    LLM_ERROR -- "No" --> PARSE["AgentLLMResponse.from(response)<br/>native toolCalls first,<br/>text-marker fallback"]
    PARSE --> AFTER_MODEL{"afterModel<br/>callback?"}
    AFTER_MODEL -- "returns value" --> MODIFIED["Use modified response"]
    AFTER_MODEL -- "nil / no callback" --> HAS_TOOLS_1
    MODIFIED --> HAS_TOOLS_1

    HAS_TOOLS_1 -- "Yes — happy path" --> EMIT_TOOL_CALLS["emit toolCallsReceived<br/>append assistant msg<br/>with tool calls"]
    EMIT_TOOL_CALLS --> DISPATCH["ToolDispatcher.dispatch()<br/>parallel + dedup + callbacks<br/>stamp each result with call.id"]
    DISPATCH --> UPDATE_PLAN{"Plan active?"}
    UPDATE_PLAN -- "Yes" --> PROGRESS["Update plan step<br/>progress"]
    UPDATE_PLAN -- "No" --> APPEND_RESULTS
    PROGRESS --> APPEND_RESULTS["Append tool results<br/>to conversation<br/>trim history"]
    APPEND_RESULTS --> LOOP_BACK{{"Continue to next turn"}}
    LOOP_BACK --> LOOP_ENTRY

    HAS_TOOLS_1 -- "No" --> REPAIR_CHECK{"Repair-retry?<br/>errors exist &<br/>shouldRetry()"}
    REPAIR_CHECK -- "Yes" --> NUDGE_REPAIR["Append repair nudge<br/>emit repairRetryTriggered"]
    NUDGE_REPAIR --> LOOP_BACK
    REPAIR_CHECK -- "No" --> PLAN_CONT_CHECK{"Plan continuation?<br/>plan incomplete &<br/>shouldContinue()"}
    PLAN_CONT_CHECK -- "Yes" --> NUDGE_PLAN["Append continuation nudge<br/>emit planContinuationTriggered"]
    NUDGE_PLAN --> LOOP_BACK
    PLAN_CONT_CHECK -- "No — done!" --> DONE["Append assistant response<br/>emit finished(summary)<br/>clear temp state"]

    DONE --> AFTER_AGENT{"afterAgent<br/>callback?"}
    AFTER_AGENT -- "returns value" --> RETURN_MOD["Return modified<br/>response"]
    AFTER_AGENT -- "nil / no callback" --> RETURN["Return response"]

    LOOP_ENTRY -.-> |"maxTurns reached"| MAX_TURNS["emit finished(summary)<br/>throw AgentError.maxTurnsReached"]

    style START fill:#4A90D9,stroke:#2C5F8A,stroke-width:2px,color:#fff
    style ADD_USER fill:#9B59B6,stroke:#6C3483,stroke-width:1px,color:#fff
    style TOOLS fill:#9B59B6,stroke:#6C3483,stroke-width:1px,color:#fff
    style INJECT_SKILLS fill:#9B59B6,stroke:#6C3483,stroke-width:1px,color:#fff
    style PLAN fill:#9B59B6,stroke:#6C3483,stroke-width:1px,color:#fff
    style BUILD_REQ fill:#E67E22,stroke:#A04500,stroke-width:1px,color:#fff
    style CALL_LLM fill:#E67E22,stroke:#A04500,stroke-width:1px,color:#fff
    style PARSE fill:#E67E22,stroke:#A04500,stroke-width:1px,color:#fff
    style DISPATCH fill:#9B59B6,stroke:#6C3483,stroke-width:2px,color:#fff
    style APPEND_RESULTS fill:#9B59B6,stroke:#6C3483,stroke-width:1px,color:#fff
    style DONE fill:#27AE60,stroke:#1E8449,stroke-width:3px,color:#fff
    style RETURN fill:#27AE60,stroke:#1E8449,stroke-width:2px,color:#fff
    style RETURN_MOD fill:#27AE60,stroke:#1E8449,stroke-width:2px,color:#fff
    style SHORT_CIRCUIT fill:#95A5A6,stroke:#7F8C8D,stroke-width:1px,color:#fff
    style CANCELLED fill:#E74C3C,stroke:#C0392B,stroke-width:1px,color:#fff
    style THROW_PROVIDER fill:#E74C3C,stroke:#C0392B,stroke-width:1px,color:#fff
    style MAX_TURNS fill:#E74C3C,stroke:#C0392B,stroke-width:1px,color:#fff
    style NUDGE_REPAIR fill:#E67E22,stroke:#A04500,stroke-width:1px,color:#fff
    style NUDGE_PLAN fill:#E67E22,stroke:#A04500,stroke-width:1px,color:#fff
```

## Tool dispatch pipeline

Every tool call goes through this pipeline — dedup, lookup, callbacks, execution, and ID stamping:

```mermaid
flowchart TD
    CALLS["Tool calls from LLM<br/>[AgentToolCall]"]
    PARITY{"parallel &&<br/>calls.count > 1?"}
    SEQ["Sequential dispatch"]
    PAR["Parallel dispatch<br/>Task array — preserves order"]

    CALLS --> PARITY
    PARITY -- "Yes" --> PAR
    PARITY -- "No" --> SEQ

    PAR --> DEDUP["Dedup pass<br/>deduplicationKey per call<br/>skip duplicates → error result"]
    SEQ --> SINGLE

    DEDUP --> UNIQUE["Unique calls only<br/>emit toolCallSkippedDuplicate<br/>for skipped calls"]
    UNIQUE --> TASKS["Spawn Task per call<br/>all run concurrently"]
    TASKS --> SINGLE

    SINGLE["executeSingleCall"] --> DEDUP_CHECK{"Already seen<br/>this turn?"}
    DEDUP_CHECK -- "Yes" --> SKIP_DUP["Return error result<br/>emit toolCallSkippedDuplicate"]
    DEDUP_CHECK -- "No" --> MARK_SEEN["Add to seenKeys"]
    MARK_SEEN --> LOOKUP{"Tool registered?"}
    LOOKUP -- "No" --> NOT_FOUND["Return error result<br/>'Tool not registered'"]
    LOOKUP -- "Yes" --> NORMALIZE["Normalize params<br/>apply aliases<br/>inject context fields"]
    NORMALIZE --> BUILD_CTX["Build ToolContext<br/>callId · parameters · state<br/>turn · query"]
    BUILD_CTX --> BEFORE_TOOL{"beforeTool<br/>callback?"}
    BEFORE_TOOL -- "returns value" --> INTERCEPT["Stamp with call.id<br/>emit toolExecutionFinished<br/>return intercepted result"]
    BEFORE_TOOL -- "nil / no callback" --> EMIT_START["emit toolExecutionStarted"]
    EMIT_START --> EXECUTE["tool.execute(context:)<br/>Your Swift code runs"]
    EXECUTE --> EXEC_OK{"Execution<br/>succeeded?"}
    EXEC_OK -- "Yes" --> AFTER_TOOL{"afterTool<br/>callback?"}
    AFTER_TOOL -- "returns value" --> STAMP_MOD["Stamp modified result<br/>with call.id"]
    AFTER_TOOL -- "nil / no callback" --> STAMP_RAW["Stamp raw result<br/>with call.id"]
    EXEC_OK -- "throws" --> ON_TOOL_ERR{"onToolError<br/>callback?"}
    ON_TOOL_ERR -- "returns value" --> STAMP_REC["Stamp recovered result<br/>with call.id"]
    ON_TOOL_ERR -- "nil / no callback" --> ERR_RESULT["Error result<br/>with call.id + message"]

    STAMP_MOD --> EMIT_FINISH["emit toolExecutionFinished"]
    STAMP_RAW --> EMIT_FINISH
    STAMP_REC --> EMIT_FINISH
    INTERCEPT --> EMIT_FINISH_RET
    SKIP_DUP --> EMIT_FINISH_RET
    NOT_FOUND --> EMIT_FINISH_RET
    ERR_RESULT --> EMIT_FINISH
    EMIT_FINISH --> RESULT["AgentToolResult<br/>stamped with call.id<br/>+ toolName"]
    EMIT_FINISH_RET --> RESULT

    style CALLS fill:#4A90D9,stroke:#2C5F8A,stroke-width:2px,color:#fff
    style EXECUTE fill:#9B59B6,stroke:#6C3483,stroke-width:3px,color:#fff
    style RESULT fill:#27AE60,stroke:#1E8449,stroke-width:3px,color:#fff
    style SKIP_DUP fill:#E74C3C,stroke:#C0392B,stroke-width:1px,color:#fff
    style NOT_FOUND fill:#E74C3C,stroke:#C0392B,stroke-width:1px,color:#fff
    style ERR_RESULT fill:#E74C3C,stroke:#C0392B,stroke-width:1px,color:#fff
    style STAMP_RAW fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
    style STAMP_MOD fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
    style STAMP_REC fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
    style INTERCEPT fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
```

> **ID stamping** is critical for strict providers (OpenAI, Anthropic). Every result — whether from normal execution, callback interception, or error recovery — is stamped with the original `AgentToolCall.id` before entering conversation memory. Without this, providers reject or mis-correlate tool results.

## Message flow

How messages transform through the system — from user query to tool results and back:

```mermaid
flowchart LR
    subgraph Input
        Q["User query<br/>String"]
    end

    subgraph AgentMessage Layer
        UM[".user(text)"]
        AM[".assistant(content,<br/>toolCalls: [AgentToolCall])"]
        TR[".tool(results:<br/>[AgentToolResult])"]
    end

    subgraph LLM Layer
        REQ["LLMRequest<br/>messages: [LLMMessage]<br/>tools: [LLMToolDefinition]"]
        RESP["LLMResponse<br/>text + toolCalls"]
    end

    subgraph Provider Wire
        OLL["Ollama<br/>role: tool + tool_call_id"]
        OAI["OpenAI<br/>role: tool + tool_call_id"]
        ANT["Anthropic<br/>user + tool_result blocks"]
        GEM["Gemini<br/>model + functionResponse"]
    end

    Q --> UM
    UM -->|"toLLMMessages()"| REQ
    AM -->|"toLLMMessages()"| REQ
    TR -->|"toLLMMessages() — fan out:<br/>one .tool per result"| REQ

    REQ -->|"provider.complete()"| RESP
    RESP -->|"AgentLLMResponse.from()<br/>native toolCalls first<br/>text-marker fallback"| AM

    RESP --> OLL
    RESP --> OAI
    RESP --> ANT
    RESP --> GEM

    AM -->|"toolCalls extracted"| DISPATCH["ToolDispatcher<br/>parallel + dedup"]
    DISPATCH --> TR

    style Q fill:#4A90D9,stroke:#2C5F8A,stroke-width:2px,color:#fff
    style UM fill:#9B59B6,stroke:#6C3483,stroke-width:1px,color:#fff
    style AM fill:#9B59B6,stroke:#6C3483,stroke-width:1px,color:#fff
    style TR fill:#9B59B6,stroke:#6C3483,stroke-width:1px,color:#fff
    style REQ fill:#E67E22,stroke:#A04500,stroke-width:2px,color:#fff
    style RESP fill:#E67E22,stroke:#A04500,stroke-width:2px,color:#fff
    style DISPATCH fill:#9B59B6,stroke:#6C3483,stroke-width:2px,color:#fff
    style OLL fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
    style OAI fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
    style ANT fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
    style GEM fill:#27AE60,stroke:#1E8449,stroke-width:1px,color:#fff
```

> **Fan-out**: A single `.tool(results: [r1, r2, r3])` agent message fans out to **three** separate `LLMMessage.tool(content:toolCallId:)` messages — one per result, each carrying its own `toolCallId`. Collapsing them under one ID breaks strict providers.