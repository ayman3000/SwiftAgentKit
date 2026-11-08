# Examples

Runnable examples for SwiftAgentKit, one capability each. They are all compiled as part of the package's `Runner` target, so `swift build` catches an example that falls behind the API.

## Running

```bash
swift run Runner        # list the examples
swift run Runner 02     # run one
```

## Prerequisites

- **Ollama** running locally (`ollama serve`)
- The model the example uses, pulled: most use `llama3.2` (`ollama pull llama3.2`); 03 uses `gemma4:latest`. To use another model, change the name in the example.
- **Node.js** for 03 (its MCP server runs with `npx`)

## The examples

| # | File | Shows |
|---|---|---|
| 01 | [01-HelloAgent.swift](01-HelloAgent.swift) | the smallest agent: one LLM call, no tools |
| 02 | [02-ToolCalling.swift](02-ToolCalling.swift) | a Swift tool the model decides to call |
| 03 | [03-MCPIntegration.swift](03-MCPIntegration.swift) | connect an MCP server and bridge its tools into the agent |
| 04 | [04-SimpleChat.swift](04-SimpleChat.swift) | plain text, structured (JSON) output, and streaming |
| 05 | [05-CodingQA.swift](05-CodingQA.swift) | a multi-turn chat that keeps history |
| 06 | [06-FileAgent.swift](06-FileAgent.swift) | a ReAct loop over read-only file tools |
| 07 | [07-ProjectScaffolder.swift](07-ProjectScaffolder.swift) | planner + ReAct: plan the steps, then carry them out |
| 08 | [08-StatefulAgent.swift](08-StatefulAgent.swift) | agent state, events, and saving/restoring a session |
| 09 | [09-Guardrails.swift](09-Guardrails.swift) | callbacks that block a tool, rewrite input and redact output |
| 10 | [10-Skills.swift](10-Skills.swift) | skills: instructions loaded only when a task needs them |

## A complete app

[sak](https://github.com/ayman3000/sak) is a terminal coding agent built on SwiftAgentKit: several providers, slash commands, approval prompts, piped input and JSON output for CI — a few hundred lines worth reading after these examples.
