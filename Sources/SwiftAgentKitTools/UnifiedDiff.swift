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
        case hunkNotFound(index: Int, preview: String)
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
    /// All-or-nothing: any failure returns an error and no partial result.
    static func apply(_ hunks: [Hunk], to source: String) -> Result<String, ApplyError> {
        let hasTrailingNewline = source.hasSuffix("\n")
        var lines = source.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }   // drop the empty element after the final "\n"

        var offset = 0   // cumulative shift from prior hunks

        for (i, hunk) in hunks.enumerated() {
            let before = hunk.before
            let after = hunk.after
            let hint = max(0, hunk.oldStart - 1 + offset)

            if before.isEmpty {
                // Pure insertion — anchor at the hinted line.
                guard hint <= lines.count else { return .failure(.cannotAnchor(index: i)) }
                lines.insert(contentsOf: after, at: hint)
                offset += after.count
                continue
            }

            guard let match = locate(before, in: lines, near: hint) else {
                return .failure(.hunkNotFound(index: i, preview: preview(before)))
            }
            lines.replaceSubrange(match..<(match + before.count), with: after)
            offset += after.count - before.count
        }

        var result = lines.joined(separator: "\n")
        if hasTrailingNewline { result += "\n" }
        return .success(result)
    }

    /// Find the start index where `block` occurs contiguously in `lines`,
    /// choosing the occurrence nearest `hint`. Line numbers are hints only.
    private static func locate(_ block: [String], in lines: [String], near hint: Int) -> Int? {
        guard !block.isEmpty, block.count <= lines.count else { return nil }
        var matches: [Int] = []
        for start in 0...(lines.count - block.count) {
            if Array(lines[start..<(start + block.count)]) == block {
                matches.append(start)
            }
        }
        return matches.min { abs($0 - hint) < abs($1 - hint) }
    }

    private static func preview(_ block: [String]) -> String {
        block.prefix(3).joined(separator: " ⏎ ").prefix(120).description
    }
}
