# SwiftAgentKitReplay

Deterministic, offline regression harness for the SwiftAgentKit runtime.

## Two seams
- **Loop replay** — `ReplayProvider` returns scripted `LLMResponse`s through the
  `Agent`'s `provider:` seam. Assert loop behavior + the requests the loop builds
  with `ReplayRun`.
- **Wire snapshot** — `assertWireSnapshot` runs a real provider's `prepareRequest`
  and golden-compares the request body. Regenerate goldens with
  `SAK_UPDATE_SNAPSHOTS=1 swift test`.

## Recording a scenario
Wrap a real provider in `RecordingProvider`, run one session, then
`writeScenario(named:to:)`. Replay it later with `ReplayProvider`/`ReplayRun`.

## Scope
v1 covers single-agent runs. Deferred:
- Sub-agent (multi-agent) scenarios are not yet supported.
- Response-side snapshots (`parseResponse` goldens) are not yet covered — response-decoding regressions are unguarded for now.
- v1 fixtures are response-only (`ScriptedTurn`); serializing full `LLMRequest`s into fixtures (`CodableLLMRequest`) is deferred — wire seeds build their requests in code.
