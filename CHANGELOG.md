# Changelog

All notable changes to SwiftAgentKit will be documented in this file.

## Unreleased

### Added
- Guard against overlapping `run(_:)` calls on the same `Agent` instance with `AgentError.runInProgress`.
- Regression coverage for same-instance concurrent run rejection.

### Documentation
- Clarified `runStreaming(_:)` behavior for tool-using agents.
- Documented current `@Tool` macro alpha limitations.

## 0.1.0-alpha.4 - 2026-07-06

### Fixed
- Updated dependency constraints to LLMProviderKit 0.1.0-alpha.4.
- Preserved strict tool-call ID correlation through dispatcher stamping and tool-result fan-out.

### Added
- Optional `@Tool` macro support for reducing manual tool boilerplate.
