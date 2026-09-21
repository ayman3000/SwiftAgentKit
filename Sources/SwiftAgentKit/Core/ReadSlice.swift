import Foundation

/// How much of a file one `read_file` call should actually return.
///
/// The model chooses `limit`, and left alone it chooses badly. Measured on a
/// real conversation: it asked for roughly 200 characters at a time, turning a
/// single file into dozens of round trips. A 200-character slice does not cost
/// 200 characters — every tool call re-sends the entire conversation to the
/// provider, so the slice costs a whole call, tens of thousands of tokens.
/// Reading far more than was asked for is close to free by comparison.
///
/// So the tool treats `limit` as a hint, not an instruction: never serve a
/// slice so small that paging dominates, and when the rest of the file would
/// fit in one ordinary read, just send the rest. When the request is widened,
/// say so and say what the crawl would have cost — a model that is told the
/// price stops asking for 200 characters.
public struct ReadSlice: Equatable, Sendable {

    /// Never serve less than this, however little was asked for. Small enough
    /// that a deliberate peek at a huge log is still cheap, large enough that
    /// no real source file needs more than a couple of calls.
    public static let floor = 4_000

    /// What a caller gets when it names no limit, and the size below which a
    /// file is simply served whole.
    public static let defaultLimit = 40_000

    public let start: Int
    public let end: Int
    /// Set when more was served than was asked for, with the reason.
    public let widenedNote: String?
    /// Set when the file continues past `end`, with where to resume.
    public let truncatedNote: String?

    public init(totalChars: Int, offset: Int?, limit: Int?) {
        let total = max(0, totalChars)
        let start = min(max(0, offset ?? 0), total)
        let requested = limit.map { max(0, $0) } ?? Self.defaultLimit
        let remaining = total - start

        // The rest of the file fits in one ordinary read, so paging it serves
        // nobody; otherwise honour the request, but never below the floor.
        let effective = remaining <= Self.defaultLimit ? remaining : max(requested, Self.floor)
        let end = min(start + effective, total)

        self.start = start
        self.end = end
        let served = end - start
        self.widenedNote = served > requested
            ? Self.widenReason(served: served, requested: requested, remaining: remaining)
            : nil
        self.truncatedNote = end < total
            ? "… [truncated at \(end)/\(total) chars — call again with offset \(end)]"
            : nil
    }

    /// The teaching line. It names the number of calls the requested pace
    /// implies, because that is the figure the model is not accounting for.
    static func widenReason(served: Int, requested: Int, remaining: Int) -> String {
        var note = "[Returned \(served) characters, not the \(requested) requested."
        if requested > 0 {
            let calls = Int((Double(remaining) / Double(requested)).rounded(.up))
            if calls > 2 {
                note += " At \(requested) characters a call this file would take \(calls) calls, "
                note += "and every call re-sends the whole conversation — reading more at once is far cheaper."
            }
        }
        note += " Ask for a larger `limit` next time, or use `document_digest` for a long document.]"
        return note
    }

    /// The slice, followed by whichever notes apply.
    public func annotate(_ text: String) -> String {
        var out = text
        if let truncatedNote { out += "\n" + truncatedNote }
        if let widenedNote { out += "\n" + widenedNote }
        return out
    }
}
