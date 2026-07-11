# Examples

Runnable examples for SwiftAgentKit. Each file demonstrates a different capability.

## Running

```bash
# From the repo root:
swift run Runner 01    # Hello Agent — simplest single-shot LLM call
swift run Runner 02    # Tool Calling — define a Swift tool, let the model use it
swift run Runner 03    # MCP Integration — connect to an MCP server, bridge tools
```

## Prerequisites

- **Ollama** running locally (`ollama serve`)
- A model pulled (`ollama pull llama3.2` or `ollama pull gemma4:latest`)
- **Node.js** installed (for Example 03 — MCP server uses `npx`)

## Examples

### 01 — Hello Agent

The simplest possible agent: one LLM call, no tools, no loop.

### 02 — Tool Calling

Define a `CurrentTimeTool` in Swift, register it with the agent, and let the model decide when to call it. The agent runs a ReAct loop: model → tool → result → model → final answer.

### 03 — MCP Integration

Connect to `@modelcontextprotocol/server-filesystem` via stdio, discover 14 filesystem tools, bridge them all into the agent, and run a query that uses them. No Swift tool code required — the agent uses tools from the MCP ecosystem directly.