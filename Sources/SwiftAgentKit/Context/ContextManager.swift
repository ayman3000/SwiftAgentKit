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
    /// tool-call id → artifact id, so a large *active* result spills only once.
    private var activeArtifactCache: [String: String] = [:]

    /// Tools whose output IS the retrieval mechanism — never re-truncate or
    /// re-spill their results, or the model loops calling them to "get the full
    /// output" that keeps getting bounded.
    private static let retrievalToolNames: Set<String> = ["artifact_read", "artifact_search"]

    /// Keep the whole conversation inline (no externalization) while its total
    /// size is under this many characters. ContextSift only earns its keep when
    /// context is large; externalizing tool exchanges in a small conversation just
    /// hands the model receipts for its own recent steps and can make it lose the
    /// thread. Above this budget, completed tool exchanges are externalized as
    /// before. A single huge tool result still trips the budget (so it's offloaded).
    public var inlineBudgetChars: Int

    /// Keep the most-recent read of each distinct file inline instead of
    /// externalizing it, so the agent stops re-reading the same file in a loop.
    /// Only the newest read per path is protected, and only if it's not an error
    /// and is within `maxActiveResultChars` (large reads still externalize).
    public var keepLatestReadsInline: Bool

    /// Tool names whose (non-error) result is a file read whose latest-per-path
    /// output should be kept inline. A set so the generic manager isn't coupled to
    /// any particular tools product.
    public var readToolNames: Set<String>

    public init(
        store: any ArtifactStore = InMemoryArtifactStore(),
        maxActiveResultChars: Int = 8_000,
        ledgerEntries: Int = 20,
        summaryLength: Int = 320,
        inlineBudgetChars: Int = 16_000,
        keepLatestReadsInline: Bool = true,
        readToolNames: Set<String> = ["read_file"]
    ) {
        self.store = store
        self.maxActiveResultChars = maxActiveResultChars
        self.ledgerEntries = ledgerEntries
        self.summaryLength = summaryLength
        self.inlineBudgetChars = inlineBudgetChars
        self.keepLatestReadsInline = keepLatestReadsInline
        self.readToolNames = readToolNames
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

        // Budget gate: while the whole conversation is small, keep everything
        // inline (full tool calls + results, no ledger) so the model has its
        // complete recent history. Only externalize once context grows large.
        let totalChars = messages.reduce(0) { sum, m in
            sum + m.content.count + (m.toolResults?.reduce(0) { $0 + $1.result.count } ?? 0)
        }
        if totalChars <= inlineBudgetChars {
            var inline: [LLMMessage] = []
            if !systemBlocks.isEmpty { inline.append(.system(systemBlocks.joined(separator: "\n\n"))) }
            for message in rest where message.role != .system {
                inline.append(contentsOf: message.toLLMMessages())
            }
            return inline
        }

        let activeStart = activeExchangeStart(in: rest) ?? rest.count

        // Map each tool-call id → its call, so a receipt can name the invocation
        // (e.g. the shell command), not just the tool. Built here (before the
        // eviction loop) so we can look up a read's file path while deciding what
        // to keep.
        var callsByID: [String: AgentToolCall] = [:]
        for message in rest where message.role == .assistant {
            for call in message.toolCalls ?? [] { callsByID[call.id] = call }
        }

        // The `rest` index of the most-recent read of each distinct file path —
        // these exchanges are kept inline so the model doesn't re-read the file.
        let latestReadIndexByPath = keepLatestReadsInline
            ? latestReadIndices(in: rest, upTo: activeStart, callsByID: callsByID)
            : [:]
        let protectedIndices = Set(latestReadIndexByPath.values)

        // Over budget: externalize whole tool exchanges OLDEST-FIRST until we're
        // back under budget, keeping the most RECENT tool results inline. This
        // preserves the working set an iterative task needs (run → read error →
        // fix → rerun) while still capping growth. An exchange is an
        // assistant-with-toolCalls turn plus its following tool-result messages;
        // evicting whole exchanges keeps tool_call/result pairing valid.
        var externalized = Set<Int>()   // indices in `rest` to move to the ledger
        var remaining = totalChars
        var i = 0
        while i < activeStart && remaining > inlineBudgetChars {
            if rest[i].role == .assistant, rest[i].toolCalls?.isEmpty == false {
                var j = i + 1
                var span = [i]
                while j < activeStart, rest[j].role == .tool {
                    span.append(j)
                    j += 1
                }
                // Keep the whole exchange inline if it holds a latest-per-path
                // read (preserving tool_call/result pairing); evict the rest.
                if span.contains(where: { protectedIndices.contains($0) }) {
                    i = j
                    continue
                }
                let exchangeChars = span.reduce(0) { sum, idx in
                    sum + rest[idx].content.count
                        + (rest[idx].toolResults?.reduce(0) { $0 + $1.result.count } ?? 0)
                }
                span.forEach { externalized.insert($0) }
                remaining -= exchangeChars
                i = j
            } else {
                i += 1
            }
        }

        // Receipts for the externalized (older) tool results only.
        var receipts: [ToolReceipt] = []
        for index in externalized.sorted() where rest[index].role == .tool {
            for result in rest[index].toolResults ?? [] {
                receipts.append(await receipt(for: result, call: callsByID[result.toolCallId]))
            }
        }

        var out: [LLMMessage] = []

        // One combined system message (identity + ledger) — provider-safe
        // (some providers keep only a single system block).
        var systemParts = systemBlocks
        if !receipts.isEmpty {
            let lines = receipts.suffix(ledgerEntries).map { "- " + $0.ledgerLine() }.joined(separator: "\n")
            systemParts.append(
                "Older tool ledger — these tool calls already completed and their full output is "
                + "NOT in this message; retrieve it with artifact_read / artifact_search using the "
                + "artifact id in brackets when you need the details:\n" + lines
            )
        }
        if !systemParts.isEmpty {
            out.append(.system(systemParts.joined(separator: "\n\n")))
        }

        // Main messages. Externalized exchanges collapse to a ledger line
        // (assistant keeps text only, tool results dropped); everything else —
        // recent completed exchanges and the active exchange — stays inline
        // (tool results bounded by `activeDisplay`).
        for (index, message) in rest.enumerated() {
            let isExternalized = externalized.contains(index)
            switch message.role {
            case .user:
                out.append(contentsOf: message.toLLMMessages())
            case .assistant:
                if isExternalized {
                    if !message.content.isEmpty { out.append(.assistant(message.content)) }  // drop tool calls
                } else {
                    out.append(contentsOf: message.toLLMMessages())  // keep tool calls (recent/active)
                }
            case .tool:
                if !isExternalized, let results = message.toolResults {
                    for result in results {
                        let display = await activeDisplay(for: result)
                        out.append(.tool(display, toolCallId: result.toolCallId))
                    }
                }
                // externalized tool results are dropped (represented in the ledger)
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
    /// an artifact when it exceeds the summary length. `call` (when available)
    /// supplies a short arg hint (e.g. the shell command) so the ledger names the
    /// invocation.
    private func receipt(for result: AgentToolResult, call: AgentToolCall?) async -> ToolReceipt {
        if let cached = cachedReceipt(result.toolCallId) { return cached }

        let name = result.toolName ?? "tool"
        let summary = conclusionSummary(result.result)
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
            artifactIDs: artifactIDs,
            argHint: call.flatMap { Self.argHint(for: $0) }
        )
        cache(receipt)
        return receipt
    }

    /// For each distinct file path, the highest `rest` index (< `activeStart`) of a
    /// keep-worthy read of that path: a `readToolNames` result that isn't an error
    /// and is within `maxActiveResultChars`. Reads appear in order, so the last
    /// seen per path wins.
    private func latestReadIndices(
        in rest: [AgentMessage],
        upTo activeStart: Int,
        callsByID: [String: AgentToolCall]
    ) -> [String: Int] {
        var byPath: [String: Int] = [:]
        var index = 0
        while index < activeStart {
            let message = rest[index]
            if message.role == .tool {
                for result in message.toolResults ?? [] {
                    guard readToolNames.contains(result.toolName ?? ""),
                          !result.isError,
                          result.result.count <= maxActiveResultChars,
                          let call = callsByID[result.toolCallId],
                          let path = Self.pathArgument(for: call)
                    else { continue }
                    byPath[path] = index   // ascending index → newest per path
                }
            }
            index += 1
        }
        return byPath
    }

    /// The file path a call targets (the `path` argument), trimmed; nil if absent.
    private static func pathArgument(for call: AgentToolCall) -> String? {
        guard let value = call.parameters["path"]?.value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A short, single-line hint of a call's most salient argument (the command,
    /// path, query, etc.) for the ledger line.
    private static func argHint(for call: AgentToolCall) -> String? {
        let params = call.parameters
        let keys = ["command", "path", "input", "reference", "query", "url", "name"]
        for key in keys {
            if let value = params[key]?.value as? String, !value.isEmpty {
                let flat = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
            }
        }
        return nil
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
        // `modelMessages` runs every turn, so a large result that stays the active
        // exchange would spill a fresh artifact each turn. Reuse the artifact id
        // for this tool-call id instead of duplicating the content in the store.
        let artifactID: String
        if let cached = cachedActiveArtifact(result.toolCallId) {
            artifactID = cached
        } else {
            let artifact = await store.save(result.result, description: "\(name) output", toolCallID: result.toolCallId)
            cacheActiveArtifact(result.toolCallId, artifact.id)
            artifactID = artifact.id
        }
        let preview = String(result.result.prefix(maxActiveResultChars))
        return "[Tool: \(name)] \(status)\n\(preview)\n… [truncated — full output in artifact \(artifactID); use artifact_read]"
    }

    private func cachedActiveArtifact(_ callID: String) -> String? {
        guard !callID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return activeArtifactCache[callID]
    }

    private func cacheActiveArtifact(_ callID: String, _ artifactID: String) {
        guard !callID.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        activeArtifactCache[callID] = artifactID
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

    /// A one-line receipt summary that preserves the tool's CONCLUSION. For long
    /// output the meaningful result is often at the END (a shell exit line, a
    /// written path, or — for a failure — the exception at the bottom of a
    /// traceback), so we keep a head AND a tail rather than only the first N
    /// characters. This is what lets the agent still know the outcome of a tool
    /// call after its raw output has been compacted out of context.
    private func conclusionSummary(_ text: String) -> String {
        let flat = singleLine(text)
        guard flat.count > summaryLength else { return flat }
        let headLen = summaryLength / 2
        let tailLen = summaryLength - headLen
        let head = String(flat.prefix(headLen)).trimmingCharacters(in: .whitespaces)
        let tail = String(flat.suffix(tailLen)).trimmingCharacters(in: .whitespaces)
        return "\(head) … \(tail)"
    }
}
