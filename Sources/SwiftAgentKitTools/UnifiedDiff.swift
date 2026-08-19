//
//  UnifiedDiff.swift
//  SwiftAgentKitTools
//
//  A small, Foundation-only unified-diff parser and applier. Applies hunks by
//  matching their context (line numbers in `@@` headers are treated as hints,
//  not authority), so a patch whose line numbers drifted still applies — the
//  reliability property that makes LLM-generated diffs usable. Pure and
//  side-effect free, so it unit-tests directly on strings.
//

import Foundation

enum UnifiedDiff {

    /// One line within a hunk body.
    enum Line: Equatable {
        case context(String)
        case remove(String)
        case add(String)
    }

    /// A single `@@ … @@` hunk.
    struct Hunk: Equatable {
        /// 1-based old-file start line from the header (a hint for locating the hunk).
        var oldStart: Int
        var lines: [Line]

        /// Lines expected to exist in the source (context + removed), in order.
        var before: [String] {
            lines.compactMap {
                switch $0 {
                case .context(let s), .remove(let s): return s
                case .add: return nil
                }
            }
        }
        /// Lines after applying the hunk (context + added), in order.
        var after: [String] {
            lines.compactMap {
                switch $0 {
                case .context(let s), .add(let s): return s
                case .remove: return nil
                }
            }
        }
    }

    enum ApplyError: Error, Equatable {
        /// A hunk's context/removed block was found nowhere in the source.
        /// `nearby` is the file's actual, line-numbered content around the
        /// hunk's hint line — handed back so the caller (an LLM) can regenerate
        /// the diff anchored on reality instead of a stale mental copy.
        case hunkNotFound(index: Int, preview: String, nearby: String)
        /// An insertion-only hunk couldn't be anchored (its line number is out of range).
        case cannotAnchor(index: Int)
    }

    // MARK: - Parse

    /// Parse unified-diff text into hunks. File headers (`diff --git`, `index`,
    /// `--- `, `+++ `) are tolerated and ignored — the caller already knows the
    /// target path. Returns nil if there are no hunks.
    static func parse(_ patch: String) -> [Hunk]? {
        var hunks: [Hunk] = []
        var current: Hunk?

        func flush() {
            if let c = current, !c.lines.isEmpty { hunks.append(c) }
            current = nil
        }

        // Split into lines, dropping trailing empties (the patch string's own
        // trailing newline — a blank *context* line in a real diff is " ", not "").
        var rawLines = patch.components(separatedBy: "\n")
        while rawLines.last == "" { rawLines.removeLast() }

        for raw in rawLines {
            if raw.hasPrefix("@@") {
                flush()
                current = Hunk(oldStart: parseOldStart(raw) ?? 1, lines: [])
                continue
            }
            // Ignore file headers whether or not we're inside a hunk yet.
            if raw.hasPrefix("diff --git") || raw.hasPrefix("index ")
                || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") {
                continue
            }
            guard current != nil else { continue }   // skip preamble before the first hunk
            if raw.hasPrefix("\\") { continue }       // "\ No newline at end of file"

            if raw.isEmpty {
                current?.lines.append(.context(""))   // tolerate a bare blank context line
            } else {
                let body = String(raw.dropFirst())
                switch raw.first {
                case "+": current?.lines.append(.add(body))
                case "-": current?.lines.append(.remove(body))
                case " ": current?.lines.append(.context(body))
                default:  continue                    // unknown line — ignore
                }
            }
        }
        flush()
        return hunks.isEmpty ? nil : hunks
    }

    /// Extract the old-file start line from an `@@ -a,b +c,d @@` header.
    private static func parseOldStart(_ header: String) -> Int? {
        guard let dash = header.firstIndex(of: "-") else { return nil }
        let rest = header[header.index(after: dash)...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - Apply

    /// Apply hunks to `source`, matching each by context near its hint line.
    /// Resilient to LLM drift: falls back to trailing-whitespace-tolerant
    /// matching, then GNU-patch-style fuzz (dropping up to 2 drifted edge
    /// CONTEXT lines — never +/- lines). Context lines are preserved from the
    /// SOURCE, so a tolerant match never rewrites whitespace it didn't touch.
    /// All-or-nothing: any failure returns an error and no partial result.
    static func apply(_ hunks: [Hunk], to source: String) -> Result<String, ApplyError> {
        let hasTrailingNewline = source.hasSuffix("\n")
        var lines = source.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }   // drop the empty element after the final "\n"

        var offset = 0   // cumulative shift from prior hunks

        for (i, hunk) in hunks.enumerated() {
            let hint = max(0, hunk.oldStart - 1 + offset)

            if hunk.before.isEmpty {
                // Pure insertion — anchor at the hinted line.
                let after = hunk.after
                guard hint <= lines.count else { return .failure(.cannotAnchor(index: i)) }
                lines.insert(contentsOf: after, at: hint)
                offset += after.count
                continue
            }

            guard let (match, core) = resolve(hunk, in: lines, near: hint) else {
                return .failure(.hunkNotFound(index: i, preview: preview(hunk.before),
                                              nearby: nearbyRegion(lines, around: hint)))
            }

            // Rebuild the region from the hunk's line kinds so context lines
            // keep the source's exact text (matters for tolerant matches).
            var replacement: [String] = []
            var beforeCount = 0
            var si = match
            for l in core {
                switch l {
                case .context: replacement.append(lines[si]); si += 1; beforeCount += 1
                case .remove: si += 1; beforeCount += 1
                case .add(let s): replacement.append(s)
                }
            }
            lines.replaceSubrange(match..<(match + beforeCount), with: replacement)
            offset += replacement.count - beforeCount
        }

        var result = lines.joined(separator: "\n")
        if hasTrailingNewline { result += "\n" }
        return .success(result)
    }

    /// Find where a hunk applies: exact match first, then trailing-whitespace-
    /// tolerant, then fuzz 1–2 (eliding drifted edge context lines only).
    /// Returns the match start and the (possibly edge-trimmed) hunk lines.
    private static func resolve(_ hunk: Hunk, in lines: [String], near hint: Int)
        -> (start: Int, core: [Line])? {
        if let m = locate(hunk.before, in: lines, near: hint) { return (m, hunk.lines) }
        if let m = locate(hunk.before, in: lines, near: hint, tolerant: true) { return (m, hunk.lines) }

        // Fuzz: only leading/trailing runs of CONTEXT lines may be dropped.
        let leadCtx = hunk.lines.prefix(while: { if case .context = $0 { return true }; return false }).count
        let trailCtx = hunk.lines.reversed().prefix(while: { if case .context = $0 { return true }; return false }).count
        for fuzz in 1...2 {
            for lead in 0...min(fuzz, leadCtx) {
                for trail in 0...min(fuzz, trailCtx) where max(lead, trail) == fuzz {
                    let core = Array(hunk.lines.dropFirst(lead).dropLast(trail))
                    let before = Hunk(oldStart: 0, lines: core).before
                    guard !before.isEmpty else { continue }
                    if let m = locate(before, in: lines, near: hint + lead)
                        ?? locate(before, in: lines, near: hint + lead, tolerant: true) {
                        return (m, core)
                    }
                }
            }
        }
        return nil
    }

    /// Find the start index where `block` occurs contiguously in `lines`,
    /// choosing the occurrence nearest `hint`. Line numbers are hints only.
    /// `tolerant` compares with trailing whitespace stripped.
    private static func locate(_ block: [String], in lines: [String], near hint: Int,
                               tolerant: Bool = false) -> Int? {
        guard !block.isEmpty, block.count <= lines.count else { return nil }
        func eq(_ a: String, _ b: String) -> Bool {
            tolerant ? rstrip(a) == rstrip(b) : a == b
        }
        var matches: [Int] = []
        outer: for start in 0...(lines.count - block.count) {
            for j in 0..<block.count where !eq(lines[start + j], block[j]) { continue outer }
            matches.append(start)
        }
        return matches.min { abs($0 - hint) < abs($1 - hint) }
    }

    private static func rstrip(_ s: String) -> Substring {
        var v = Substring(s)
        while let last = v.last, last == " " || last == "\t" { v.removeLast() }
        return v
    }

    /// The file's actual, line-numbered content around `hint` — returned in
    /// hunkNotFound errors so an LLM can regenerate its diff against reality.
    private static func nearbyRegion(_ lines: [String], around hint: Int, radius: Int = 8) -> String {
        guard !lines.isEmpty else { return "(file is empty)" }
        let center = min(max(hint, 0), lines.count - 1)
        let lo = max(0, center - radius)
        let hi = min(lines.count - 1, center + radius)
        return (lo...hi).map { "\($0 + 1) | \(lines[$0])" }.joined(separator: "\n")
    }

    private static func preview(_ block: [String]) -> String {
        block.prefix(3).joined(separator: " ⏎ ").prefix(120).description
    }
}
