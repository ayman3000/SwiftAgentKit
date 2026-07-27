//
//  ContextManager.swift
//  SwiftAgentKit
//
//  ContextSift-style context management: keep the full main conversation, but
//  move *completed* tool exchanges out of active model context — replaced by a
//  compact receipt ledger, with full outputs preserved in an `ArtifactStore` and
//  retrievable on demand via `artifact_read` / `artifact_search`.
//
//  Opt-in: set `AgentConfig.contextManager`. When nil, the agent uses its normal
//  (trim-based) context handling and behaves exactly as before.
//

import Foundation
import LLMProviderKit

/// Transforms an agent conversation into the model-facing message set, keeping
/// tool history out of routine context without losing it.
public final class ContextManager: @unchecked Sendable {

    /// External store for full tool outputs.
    public let store: any ArtifactStore

    /// Tool results longer than this (characters) are spilled to an artifact and
    /// shown to the model as a bounded preview + reference — even while active.
    public var maxActiveResultChars: Int

    /// How many recent completed-tool receipts to include in the ledger.
    public var ledgerEntries: Int

    /// Length of the receipt summary drawn from a tool result.
    public var summaryLength: Int

    private let lock = NSLock()
    private var receiptCache: [String: ToolReceipt] = [:]

    /// Tools whose output IS the retrieval mechanism — never re-truncate or
    /// re-spill their results, or the model loops calling them to "get the full
    /// output" that keeps getting bounded.
    private static let retrievalToolNames: Set<String> = ["artifact_read", "artifact_search"]

    public init(
        store: any ArtifactStore = InMemoryArtifactStore(),
        maxActiveResultChars: Int = 8_000,
        ledgerEntries: Int = 20,
        summaryLength: Int = 200
    ) {
        self.store = store
        self.maxActiveResultChars = maxActiveResultChars
        self.ledgerEntries = ledgerEntries
        self.summaryLength = summaryLength
    }

    /// The retrieval tools the model uses to pull full outputs back from the
    /// store. Auto-registered by the agent when a context manager is set.
    public var artifactTools: [any AgentTool] {
        [ArtifactReadTool(store: store), ArtifactSearchTool(store: store)]
    }

    // MARK: - Build

    /// Build the model-facing messages: identity/system + receipt ledger, then
    /// main messages (completed assistant turns keep only their text), then the
    /// active tool exchange (bounded).
    public func modelMessages(
        _ messages: [AgentMessage],
        systemTemplate: (String) -> String
    ) async -> [LLMMessage] {
        let systemBlocks = messages
            .filter { $0.role == .system }
            .map { systemTemplate($0.content) }
            .filter { !$0.isEmpty }

        let rest = messages.filter { $0.role != .system }
        let activeStart = activeExchangeStart(in: rest)

        // Receipts for every completed tool result (spilled to artifacts as needed).
        var receipts: [ToolReceipt] = []
        for (index, message) in rest.enumerated() where index < (activeStart ?? rest.count) {
            if message.role == .tool, let results = message.toolResults {
                for result in results {
                    receipts.append(await receipt(for: result))
                }
            }
        }

        var out: [LLMMessage] = []

        // One combined system message (identity + ledger) — provider-safe
        // (some providers keep only a single system block).
        var systemParts = systemBlocks
        if !receipts.isEmpty {
            let lines = receipts.suffix(ledgerEntries).map { "- " + $0.ledgerLine() }.joined(separator: "\n")
            systemParts.append(
                "Recent tool ledger — these tool calls already completed. Their full output is "
                + "NOT in this message; retrieve it with artifact_read / artifact_search using the "
                + "artifact id in brackets when you need the details:\n" + lines
            )
        }
        if !systemParts.isEmpty {
            out.append(.system(systemParts.joined(separator: "\n\n")))
        }

        // Main messages + the active exchange.
        for (index, message) in rest.enumerated() {
            let isActive = activeStart.map { index >= $0 } ?? false
            switch message.role {
            case .user:
                out.append(contentsOf: message.toLLMMessages())
            case .assistant:
                if isActive {
                    out.append(contentsOf: message.toLLMMessages()) // keep tool calls
                } else if !message.content.isEmpty {
                    out.append(.assistant(message.content))          // drop completed tool calls
                }
            case .tool:
                if isActive, let results = message.toolResults {
                    for result in results {
                        let display = await activeDisplay(for: result)
                        out.append(.tool(display, toolCallId: result.toolCallId))
                    }
                }
                // completed tool results are dropped (represented in the ledger)
            case .system:
                break
            }
        }

        return out
    }

    // MARK: - Private

    /// Index in `rest` where the active tool exchange begins, or nil if there is
    /// no active exchange (the last assistant tool-call turn has already been
    /// answered with a new assistant message).
    private func activeExchangeStart(in rest: [AgentMessage]) -> Int? {
        guard let lastToolCallIdx = rest.lastIndex(where: {
            $0.role == .assistant && ($0.toolCalls?.isEmpty == false)
        }) else { return nil }
        // Active only if nothing but tool messages follow it.
        let after = rest[(lastToolCallIdx + 1)...]
        return after.allSatisfy { $0.role == .tool } ? lastToolCallIdx : nil
    }

    /// A cached receipt for a completed tool result — spilling the full output to
    /// an artifact when it exceeds the summary length.
    private func receipt(for result: AgentToolResult) async -> ToolReceipt {
        if let cached = cachedReceipt(result.toolCallId) { return cached }

        let name = result.toolName ?? "tool"
        let summary = singleLine(String(result.result.prefix(summaryLength)))
        var artifactIDs: [String] = []
        // Don't spill retrieval-tool output to a new artifact — that would nest
        // artifacts of artifacts and never surface the real content.
        if result.result.count > summaryLength && !Self.retrievalToolNames.contains(name) {
            let artifact = await store.save(result.result, description: "\(name) output", toolCallID: result.toolCallId)
            artifactIDs = [artifact.id]
        }
        let receipt = ToolReceipt(
            callID: result.toolCallId,
            toolName: name,
            isError: result.isError,
            summary: summary,
            artifactIDs: artifactIDs
        )
        cache(receipt)
        return receipt
    }

    /// The bounded display for an *active* tool result: full if small, otherwise
    /// a preview plus an artifact reference.
    private func activeDisplay(for result: AgentToolResult) async -> String {
        let name = result.toolName ?? "tool"
        let status = result.isError ? "ERROR" : "OK"
        // Retrieval-tool output is how full content gets surfaced — show it in
        // full (the tool already pages via offset/limit); truncating it here is
        // self-defeating and makes the model loop calling artifact_read.
        if Self.retrievalToolNames.contains(name) || result.result.count <= maxActiveResultChars {
            return "[Tool: \(name)] \(status)\n\(result.result)"
        }
        let artifact = await store.save(result.result, description: "\(name) output", toolCallID: result.toolCallId)
        let preview = String(result.result.prefix(maxActiveResultChars))
        return "[Tool: \(name)] \(status)\n\(preview)\n… [truncated — full output in artifact \(artifact.id); use artifact_read]"
    }

    private func cachedReceipt(_ callID: String) -> ToolReceipt? {
        lock.lock(); defer { lock.unlock() }
        return receiptCache[callID]
    }

    private func cache(_ receipt: ToolReceipt) {
        lock.lock(); defer { lock.unlock() }
        receiptCache[receipt.callID] = receipt
    }

    private func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
