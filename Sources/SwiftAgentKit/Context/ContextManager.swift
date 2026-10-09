//
//  ContextManager.swift
//  SwiftAgentKit
//
//  ContextSift-style context management: keep the full main conversation, but
//  move *completed* tool exchanges out of active model context — each replaced,
//  in its own place, by compact receipts, with full outputs preserved in an
//  `ArtifactStore` and retrievable on demand via `artifact_read` / `artifact_search`.
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

    /// No longer used (0.4.0-alpha.120): every evicted step keeps its own
    /// receipts in its own place, so there is no ledger to cap. Kept so
    /// callers compile; compaction bounds the growth.
    public var ledgerEntries: Int

    /// Length of the receipt summary drawn from a tool result.
    public var summaryLength: Int

    private let lock = NSLock()
    private var receiptCache: [String: ToolReceipt] = [:]
    /// tool-call id → artifact id, so a large *active* result spills only once.
    private var activeArtifactCache: [String: String] = [:]

    /// Tools whose output IS the retrieval mechanism — never re-truncate or
    /// re-spill their results, or the model loops calling them to "get the full
    /// output" that keeps getting bounded. `use_skill` is here for a related
    /// reason: a loaded skill's instructions must stay live for the whole run
    /// (a skill loaded at step 3 evicted by step 60 silently derails the task).
    private static let retrievalToolNames: Set<String> = ["artifact_read", "artifact_search", "artifact_list", "use_skill"]

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

    /// Tool names whose (non-error) result is a "read of a stable surface" whose
    /// latest-per-target output should be kept inline. A set so the generic manager
    /// isn't coupled to any particular tools product. Not limited to files — a UI
    /// snapshot tool (e.g. `sim_ui`/`mac_ui`, keyed by the app it inspects) counts,
    /// so the agent stops re-snapshotting the same surface in a loop.
    public var readToolNames: Set<String>

    /// Per-tool name of the parameter that identifies WHAT a read targets, used to
    /// keep only the newest read per target inline. Defaults to `path` for any tool
    /// not listed (so `read_file`/`list_dir` work with no config); a UI tool keyed
    /// by app maps to `bundle_id`, etc. A read whose identity param is absent/empty
    /// is not protected (treated as un-targetable).
    public var readIdentityParams: [String: String]

    public init(
        store: any ArtifactStore = InMemoryArtifactStore(),
        maxActiveResultChars: Int = 8_000,
        ledgerEntries: Int = 20,
        summaryLength: Int = 320,
        inlineBudgetChars: Int = 16_000,
        keepLatestReadsInline: Bool = true,
        readToolNames: Set<String> = ["read_file"],
        readIdentityParams: [String: String] = [:]
    ) {
        self.store = store
        self.maxActiveResultChars = maxActiveResultChars
        self.ledgerEntries = ledgerEntries
        self.summaryLength = summaryLength
        self.inlineBudgetChars = inlineBudgetChars
        self.keepLatestReadsInline = keepLatestReadsInline
        self.readToolNames = readToolNames
        self.readIdentityParams = readIdentityParams
    }

    /// The retrieval tools the model uses to pull full outputs back from the
    /// store. Auto-registered by the agent when a context manager is set.
    /// `artifact_list` joins them when the store can enumerate its contents.
    public var artifactTools: [any AgentTool] {
        var tools: [any AgentTool] = [ArtifactReadTool(store: store), ArtifactSearchTool(store: store)]
        if let listable = store as? any ListableArtifactStore {
            tools.append(ArtifactListTool(store: listable))
        }
        return tools
    }

    /// Minimum characters for eager persistence — "exit 0"-style outputs
    /// aren't worth a disk write.
    public var eagerPersistMinChars = 1_000

    /// Low watermark for eviction hysteresis: a budget breach evicts down to
    /// this fraction of `inlineBudgetChars`, then the evicted set FREEZES
    /// until the budget is breached again. Keeps the model-facing prefix
    /// byte-stable between eviction events so provider prompt caches hit.
    public var evictionTargetFraction: Double = 0.5

    /// A batch happens only when at least this share of the message budget
    /// can be evicted at once. Between batches the model-facing prefix is
    /// byte-identical, so provider prompt caches hit — even when what cannot
    /// be evicted (the floor) already fills the budget, where evicting one
    /// step per call used to change the prefix on every call.
    public var minEvictionBatchFraction: Double = 0.25

    /// Headroom above the floor a batch evicts down to, as a share of the
    /// message budget: the target is `max(budget × evictionTargetFraction,
    /// floor + budget × evictionSlackFraction)`.
    public var evictionSlackFraction: Double = 0.10

    /// The messages' budget never drops below this share of
    /// `inlineBudgetChars`, however long the system prompt is.
    public var minMessageBudgetFraction: Double = 0.25

    /// What the messages may use: the inline budget less the system prompt,
    /// so system + messages keep the ceiling `inlineBudgetChars` always
    /// meant. The system prompt itself is not sifted — it is the same on
    /// every call and nothing here can shrink it.
    public func messageBudget(systemChars: Int) -> Int {
        let floor = Int(Double(inlineBudgetChars) * min(1, max(0, minMessageBudgetFraction)))
        return max(floor, inlineBudgetChars - systemChars)
    }

    /// A fresh manager over the same store with every setting copied — for a
    /// sub-agent. Evictions, receipts and spill ids are per conversation and
    /// start empty.
    public func childManager() -> ContextManager {
        let child = ContextManager(store: store, maxActiveResultChars: maxActiveResultChars,
                                   ledgerEntries: ledgerEntries, summaryLength: summaryLength,
                                   inlineBudgetChars: inlineBudgetChars,
                                   keepLatestReadsInline: keepLatestReadsInline,
                                   readToolNames: readToolNames, readIdentityParams: readIdentityParams)
        child.eagerPersistMinChars = eagerPersistMinChars
        child.evictionTargetFraction = evictionTargetFraction
        child.minEvictionBatchFraction = minEvictionBatchFraction
        child.evictionSlackFraction = evictionSlackFraction
        child.minMessageBudgetFraction = minMessageBudgetFraction
        return child
    }

    /// How many of `candidates` (sizes of the evictable steps, oldest first)
    /// one pass evicts. Pure.
    /// - `remaining`: message characters still sent inline (earlier
    ///   evictions already taken off).
    /// - Nothing goes while `remaining` fits the budget, or while less than a
    ///   minimum batch is evictable. Otherwise a batch frees at least
    ///   `max(remaining − target, minimum batch)`, where target is
    ///   `max(budget × targetFraction, floor + budget × slackFraction)` and
    ///   the floor is what cannot be evicted.
    public static func evictionCount(candidates: [Int], remaining: Int, budget: Int,
                                     targetFraction: Double, minBatchFraction: Double,
                                     slackFraction: Double) -> Int {
        guard remaining > budget, !candidates.isEmpty else { return 0 }
        func share(_ fraction: Double) -> Int { Int((Double(budget) * min(1, max(0, fraction))).rounded(.up)) }
        let evictable = candidates.reduce(0, +)
        let minBatch = share(minBatchFraction)
        guard evictable >= max(1, minBatch) else { return 0 }
        let floor = remaining - evictable
        let target = max(Int(Double(budget) * min(1, max(0, targetFraction))), floor + share(slackFraction))
        let needed = max(remaining - target, minBatch)
        var freed = 0
        var count = 0
        for size in candidates where freed < needed {
            freed += size
            count += 1
        }
        return count
    }

    /// What a message weighs for sifting: its text plus its tool results.
    static func size(of message: AgentMessage) -> Int {
        message.content.count + (message.toolResults?.reduce(0) { $0 + $1.result.count } ?? 0)
    }

    /// Head-message ids of exchanges evicted by previous calls. Sticky —
    /// never un-evicted — so the prefix cannot flap.
    private var stickyEvicted: Set<UUID> = []

    private func currentStickyEvicted() -> Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return stickyEvicted
    }

    private func rememberEvicted(_ ids: [UUID]) {
        lock.lock(); defer { lock.unlock() }
        stickyEvicted.formUnion(ids)
    }

    /// Completed tool exchanges before `activeStart`: the assistant tool-call
    /// turn (`head`), the indices of the whole exchange, and its char size.
    private struct ExchangeSpan {
        let head: Int
        let indices: [Int]
        let chars: Int
    }

    private func exchangeSpans(in rest: [AgentMessage], upTo activeStart: Int) -> [ExchangeSpan] {
        var spans: [ExchangeSpan] = []
        var i = 0
        while i < activeStart {
            guard rest[i].role == .assistant, rest[i].toolCalls?.isEmpty == false else { i += 1; continue }
            var j = i + 1
            var indices = [i]
            while j < activeStart, rest[j].role == .tool {
                indices.append(j)
                j += 1
            }
            let chars = indices.reduce(0) { $0 + Self.size(of: rest[$1]) }
            spans.append(ExchangeSpan(head: i, indices: indices, chars: chars))
            i = j
        }
        return spans
    }

    /// Save completed tool results to the store AS THEY FINISH, not only when
    /// sifting later spills them. Without this, a short run that never exceeds
    /// the inline budget stores nothing — and a restart-surviving store
    /// (FileArtifactStore) has no history to serve. Deduped with the spill
    /// paths per tool-call id; errors, retrieval tools, and tiny outputs skip.
    /// The store's own persistFilter still decides what reaches disk.
    public func recordCompletedResults(_ results: [AgentToolResult]) async {
        for result in results {
            let name = result.toolName ?? "tool"
            guard !result.isError,
                  !Self.retrievalToolNames.contains(name),
                  result.result.count >= eagerPersistMinChars,
                  cachedActiveArtifact(result.toolCallId) == nil
            else { continue }
            let artifact = await store.save(result.result, description: "\(name) output",
                                            toolCallID: result.toolCallId, toolName: name)
            cacheActiveArtifact(result.toolCallId, artifact.id)
        }
    }

    // MARK: - Build

    /// Build the model-facing messages: the system prompt, then the main
    /// messages (each evicted step replaced in place by its receipts), then
    /// the active tool exchange (bounded).
    public func modelMessages(
        _ messages: [AgentMessage],
        systemTemplate: (String) -> String
    ) async -> [LLMMessage] {
        let systemBlocks = messages
            .filter { $0.role == .system }
            .map { systemTemplate($0.content) }
            .filter { !$0.isEmpty }
        let systemText = systemBlocks.joined(separator: "\n\n")

        let rest = messages.filter { $0.role != .system }

        // What sifting measures is the messages, not the system prompt: that
        // is the same on every call and nothing here can shrink it. It comes
        // off the budget instead (`messageBudget`).
        let budget = messageBudget(systemChars: systemText.count)
        let restChars = rest.reduce(0) { $0 + Self.size(of: $1) }

        // Budget gate: while the messages are small, keep everything inline
        // (full tool calls + results, no receipts) so the model has its
        // complete recent history. Only externalize once they grow large.
        if restChars <= budget {
            var inline: [LLMMessage] = []
            if !systemText.isEmpty { inline.append(.system(systemText)) }
            for message in rest {
                inline.append(contentsOf: message.toLLMMessages())
            }
            return inline
        }

        let activeStart = activeExchangeStart(in: rest) ?? rest.count

        // Map each tool-call id → its call, so a receipt can name the invocation
        // (e.g. the shell command), not just the tool. Built here (before the
        // eviction pass) so we can look up a read's file path while deciding
        // what to keep.
        var callsByID: [String: AgentToolCall] = [:]
        for message in rest where message.role == .assistant {
            for call in message.toolCalls ?? [] { callsByID[call.id] = call }
        }

        // The `rest` index of the most-recent read of each distinct target —
        // these exchanges are kept inline so the model doesn't re-read it.
        let latestReadIndexByPath = keepLatestReadsInline
            ? latestReadIndices(in: rest, upTo: activeStart, callsByID: callsByID)
            : [:]
        let protectedIndices = Set(latestReadIndexByPath.values)

        // Over budget: externalize whole tool exchanges OLDEST-FIRST, in
        // BATCHES. An exchange is an assistant-with-toolCalls turn plus its
        // following tool-result messages; evicting whole exchanges keeps
        // tool_call/result pairing valid. Evictions are sticky (remembered by
        // message id, never undone), and a new batch happens only when at
        // least `minEvictionBatchFraction` of the budget can go at once
        // (`evictionCount`): between batches the prefix stays byte-identical.
        var externalized = Set<Int>()   // indices in `rest` that are evicted
        var remaining = restChars
        let spans = exchangeSpans(in: rest, upTo: activeStart)
        let sticky = currentStickyEvicted()
        for span in spans where sticky.contains(rest[span.head].id) {
            span.indices.forEach { externalized.insert($0) }
            remaining -= span.chars
        }
        // A step holding a latest-per-target read is part of the floor.
        let candidates = spans.filter { span in
            !externalized.contains(span.head) && !span.indices.contains { protectedIndices.contains($0) }
        }
        let count = Self.evictionCount(
            candidates: candidates.map(\.chars), remaining: remaining, budget: budget,
            targetFraction: evictionTargetFraction, minBatchFraction: minEvictionBatchFraction,
            slackFraction: evictionSlackFraction)
        if count > 0 {
            let batch = candidates.prefix(count)
            for span in batch { span.indices.forEach { externalized.insert($0) } }
            rememberEvicted(batch.map { rest[$0.head].id })
        }

        // Receipts, per evicted step, for that step's own place.
        var receiptsByHead: [Int: [ToolReceipt]] = [:]
        for span in spans where externalized.contains(span.head) {
            var receipts: [ToolReceipt] = []
            for index in span.indices where rest[index].role == .tool {
                for result in rest[index].toolResults ?? [] {
                    receipts.append(await receipt(for: result, call: callsByID[result.toolCallId]))
                }
            }
            receiptsByHead[span.head] = receipts
        }

        // A completed result is bounded (preview + artifact reference) only
        // as part of a batch, like an eviction, or when it already was while
        // active: crossing into sifting alone must not change what the normal
        // path sent whole. A batch starts at its first evicted step, so only
        // results after it may change.
        let batchStart = count > 0 ? candidates.first?.head : nil

        var out: [LLMMessage] = []
        // The system prompt alone. Receipts used to join it, so every batch
        // changed the start of the request and the whole conversation missed
        // the prompt cache; in place, a batch changes nothing before its
        // first evicted step.
        if !systemText.isEmpty { out.append(.system(systemText)) }

        for (index, message) in rest.enumerated() {
            let isExternalized = externalized.contains(index)
            switch message.role {
            case .user:
                out.append(contentsOf: message.toLLMMessages())
            case .assistant:
                if isExternalized {
                    // The evicted step in its own place: its text, then one
                    // receipt per call (the calls themselves are dropped and
                    // their results are in the store).
                    if let text = Self.receiptMessage(text: message.content, receipts: receiptsByHead[index] ?? []) {
                        out.append(.assistant(text))
                    }
                } else {
                    out.append(contentsOf: message.toLLMMessages())  // keep tool calls (recent/active)
                }
            case .tool:
                if !isExternalized, let results = message.toolResults {
                    let mayBound = index >= activeStart || (batchStart.map { index > $0 } ?? false)
                    for result in results {
                        let display = mayBound || isBounded(result.toolCallId)
                            ? await activeDisplay(for: result)
                            : Self.fullDisplay(for: result)
                        // Images stay with their result, the active one included:
                        // a chat past the budget used to stop seeing screenshots.
                        out.append(LLMMessage(role: .tool, content: display, images: result.images,
                                              toolCallId: result.toolCallId))
                    }
                }
                // evicted tool results are represented by their step's receipts
            case .system:
                break
            }
        }

        return out
    }

    /// Opens an evicted step's receipts (the bracketed-evidence style the
    /// app's own history replay uses).
    public static let receiptHeader = "[Tool calls in this step — their output was moved out of context; artifact_read / artifact_search with the artifact id in brackets fetch it:"

    /// The assistant message an evicted step becomes: its text, then one
    /// receipt line per call, in brackets. nil when there is nothing to say.
    static func receiptMessage(text: String, receipts: [ToolReceipt]) -> String? {
        guard !receipts.isEmpty else { return text.isEmpty ? nil : text }
        let block = receiptHeader + "\n" + receipts.map { "- " + $0.ledgerLine() }.joined(separator: "\n") + "\n]"
        return text.isEmpty ? block : text + "\n\n" + block
    }

    /// A tool result exactly as the normal (un-sifted) path sends it.
    private static func fullDisplay(for result: AgentToolResult) -> String {
        "[Tool: \(result.toolName ?? "tool")] \(result.isError ? "ERROR" : "OK")\n\(result.result)"
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
            // Reuse an artifact already saved for this call (eager persistence
            // or an active-display spill) instead of storing a duplicate.
            if let existing = cachedActiveArtifact(result.toolCallId) {
                artifactIDs = [existing]
            } else {
                let artifact = await store.save(result.result, description: "\(name) output", toolCallID: result.toolCallId, toolName: name)
                cacheActiveArtifact(result.toolCallId, artifact.id)
                artifactIDs = [artifact.id]
            }
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
                          let target = identityArgument(for: call)
                    else { continue }
                    // Namespace by tool so a list_dir "/x" and a read_file "/x"
                    // (or a sim_ui bundle id) don't collide into one slot.
                    byPath["\(call.name)\u{0}\(target)"] = index   // ascending → newest per target
                }
            }
            index += 1
        }
        return byPath
    }

    /// The file path a call targets (the `path` argument), trimmed; nil if absent.
    /// The value identifying what a read targets: the tool's mapped identity param
    /// (`readIdentityParams`), defaulting to `path` for tools not listed. Absent or
    /// empty → nil (not protectable).
    private func identityArgument(for call: AgentToolCall) -> String? {
        let param = readIdentityParams[call.name] ?? "path"
        guard let value = call.parameters[param]?.value as? String else { return nil }
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
        rememberBounded(result.toolCallId)
        // `modelMessages` runs every turn, so a large result that stays the active
        // exchange would spill a fresh artifact each turn. Reuse the artifact id
        // for this tool-call id instead of duplicating the content in the store.
        let artifactID: String
        if let cached = cachedActiveArtifact(result.toolCallId) {
            artifactID = cached
        } else {
            let artifact = await store.save(result.result, description: "\(name) output", toolCallID: result.toolCallId, toolName: name)
            cacheActiveArtifact(result.toolCallId, artifact.id)
            artifactID = artifact.id
        }
        // Build/test logs put the verdict at the END (a compiler head is
        // boilerplate); a head-only preview hides it and sends the model
        // grepping the artifact keyword-by-keyword. Keep a head AND a tail,
        // cutting in the middle — same reasoning as the receipt summarizer.
        let headLen = maxActiveResultChars / 3
        let tailLen = maxActiveResultChars - headLen
        let head = String(result.result.prefix(headLen))
        let tail = String(result.result.suffix(tailLen))
        // Say exactly what is missing and the one call that fetches it: a bare
        // "middle truncated" sent a model re-reading the same files until the
        // no-progress guard stopped it (2026-10-04).
        let total = result.result.count
        let gap = total - headLen - tailLen
        let cut = "… [middle truncated: showing characters 1–\(Self.grouped(headLen)) and "
            + "\(Self.grouped(total - tailLen + 1))–\(Self.grouped(total)) of \(Self.grouped(total)). "
            + "The missing \(Self.grouped(gap)) characters: artifact_read(artifact_id: \"\(artifactID)\", "
            + "offset: \(headLen), limit: \(gap)); or artifact_search it] …"
        return "[Tool: \(name)] \(status)\n\(head)\n\(cut)\n\(tail)"
    }

    /// 18090 → "18,090" — fixed separator, whatever the user's locale.
    static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return out
    }

    /// Tool-call ids whose result has been sent bounded: it stays bounded,
    /// so the prefix does not flip back to the whole output.
    private var boundedCallIDs: Set<String> = []

    private func isBounded(_ callID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return boundedCallIDs.contains(callID)
    }

    private func rememberBounded(_ callID: String) {
        guard !callID.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        boundedCallIDs.insert(callID)
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
