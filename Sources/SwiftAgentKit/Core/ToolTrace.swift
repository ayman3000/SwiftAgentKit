import Foundation
import CryptoKit
#if canImport(os)
import os
#endif

/// A trace of what the reading tools were actually asked for, and what they
/// gave back.
///
/// The expensive failure mode is invisible from the outside: a model that
/// reads a file in 200-character slices looks, in the transcript, exactly like
/// a model reading a file. The cost only shows up later as a token bill. This
/// writes one line per read so the question "is it crawling?" is a single
/// command instead of an archaeology session in the store.
///
///     log stream --predicate 'subsystem == "com.ayman3000.SwiftAgentKit" AND category == "Tools"'
///
/// Paths are NOT logged. The unified log is readable by anything on the
/// machine, and someone's file names are their business; a short digest is
/// enough to see the same file being read over and over, which is the whole
/// point of the trace.
public enum ToolTrace {

    #if canImport(os)
    static let log = Logger(subsystem: "com.ayman3000.SwiftAgentKit", category: "Tools")
    #endif

    /// A stable, non-reversing short tag for a path.
    public static func tag(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return "f#" + digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
    }

    /// One trace line. Pure, so its content can be asserted.
    ///
    /// `total` is optional because not every source knows its own size — an
    /// artifact store hands back a slice and a "there is more" flag, and
    /// inventing a total to fill the field would make the trace lie.
    public static func readLine(tool: String, tag: String, offset: Int, requested: Int?,
                                served: Int, total: Int?, more: Bool) -> String {
        var line = "\(tool) \(tag) offset=\(offset) served=\(served) total=\(total.map(String.init) ?? "?")"
        if let requested {
            line += " requested=\(requested)"
            if served > requested { line += " WIDENED" }
        } else {
            line += " requested=default"
        }
        if more { line += " more" }
        return line
    }

    /// Record a read. Cheap enough to call on every one: the unified log drops
    /// what nobody is streaming.
    public static func read(tool: String, path: String, offset: Int, requested: Int?,
                            served: Int, total: Int?, more: Bool) {
        #if canImport(os)
        let line = readLine(tool: tool, tag: tag(path), offset: offset,
                            requested: requested, served: served, total: total, more: more)
        log.debug("\(line, privacy: .public)")
        #endif
    }
}
