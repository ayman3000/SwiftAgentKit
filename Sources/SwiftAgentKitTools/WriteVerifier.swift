import Foundation

/// Post-write corruption gate for the file tools. Tool-call content sometimes
/// arrives corrupted in transit (model long-argument degradation and/or
/// streaming chunk loss — observed live three times: dropped imports, leaked
/// `+` diff markers, truncation around 6KB). The write tools verify what
/// landed and roll back on failure, so corruption can never persist.
///
/// Design rules:
/// - FALSE POSITIVES ARE WORSE THAN MISSES: a wrongly-rejected valid write
///   blocks the agent. Heuristics are limited to one high-precision signature
///   (mass leaked diff markers); everything else uses a REAL parser for the
///   language, or passes.
/// - Parsers must be fast and side-effect-free (parse/format-check modes).
///   A missing parser binary, timeout, or crash = verification SKIPPED, never
///   a rejection.
public enum WriteVerifier {

    /// Files above this size skip external-parser verification (perf guard).
    public static let maxVerifiedBytes = 2_000_000

    /// Per-extension parse commands (syntax check only, no mutation).
    /// Each is (executable-resolution names, arguments-before-path).
    /// `versionArgs` names the flag that prints the binary's version. When a
    /// machine has several copies of an interpreter, the NEWEST one decides —
    /// see `resolve`.
    private static let parsers: [String: (names: [String], args: [String], versionArgs: [String]?)] = [
        "dart": (["dart"], ["format", "--output=none"], ["--version"]),
        "swift": (["swiftc"], ["-parse"], nil),
        "py": (["python3"], ["-m", "py_compile"], ["-V"]),
        "js": (["node"], ["--check"], ["--version"]),
        "mjs": (["node"], ["--check"], ["--version"]),
    ]

    /// Extensions treated as code for the leaked-diff-marker heuristic.
    private static let codeExtensions: Set<String> = [
        "dart", "swift", "py", "js", "ts", "tsx", "jsx", "mjs", "java", "kt",
        "c", "cc", "cpp", "h", "hpp", "m", "mm", "rs", "go", "rb", "json",
    ]

    /// nil = content looks fine (or is unverifiable — fail open); otherwise a
    /// model-facing reason describing the corruption.
    public static func corruptionReason(path: String, content: String) async -> String? {
        let ext = (path as NSString).pathExtension.lowercased()

        // 1. High-precision transit-corruption signature: many lines carrying
        //    a leaked unified-diff `+` prefix in a non-patch code file.
        if codeExtensions.contains(ext), ext != "diff", ext != "patch" {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let leaked = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("++") }.count
            if leaked >= 5, lines.count > 0, Double(leaked) / Double(lines.count) > 0.2 {
                return "content contains \(leaked) lines with leaked unified-diff '+' prefixes — "
                    + "this is patch syntax bleeding into file content (transit corruption)"
            }
        }

        // 2. JSON: parse in-process (fast, always available).
        if ext == "json" {
            if (try? JSONSerialization.jsonObject(with: Data(content.utf8),
                                                  options: [.fragmentsAllowed])) == nil {
                return "content is not valid JSON"
            }
            return nil
        }

        // 3. Language parser, when available. Fail open on any infrastructure
        //    problem (missing binary, timeout, crash).
        guard content.utf8.count <= maxVerifiedBytes,
              let parser = parsers[ext],
              let executable = resolve(names: parser.names, versionArgs: parser.versionArgs) else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("write-verify-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try Data(content.utf8).write(to: tmp) } catch { return nil }

        switch runParser(executable: executable, args: parser.args + [tmp.path]) {
        case .failed(let diagnostics):
            // Name the interpreter. A rejection is only as trustworthy as the
            // binary that made it, and the reader — model or person — cannot
            // judge it without knowing which one ran.
            return "content failed the syntax check run by \(executable)"
                + (versionString(of: executable, versionArgs: parser.versionArgs).map { " (\($0))" } ?? "")
                + ":\n\(diagnostics)"
        case .passed, .unavailable:
            return nil
        }
    }

    /// Whether a real parser exists for this extension on this machine —
    /// used by tests to skip environment-dependent assertions.
    public static func parserAvailable(forExtension ext: String) -> Bool {
        if ext == "json" { return true }
        guard let parser = parsers[ext.lowercased()] else { return false }
        return resolve(names: parser.names, versionArgs: parser.versionArgs) != nil
    }

    // MARK: - Process plumbing

    private enum ParseOutcome { case passed, failed(String), unavailable }

    /// Thread-safe accumulator for a pipe drained on the reader's queue.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); bytes.append(chunk); lock.unlock()
        }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    private static let resolveLock = NSLock()
    nonisolated(unsafe) private static var resolved: [String: String?] = [:]

    private static func resolve(names: [String], versionArgs: [String]?) -> String? {
        for name in names {
            resolveLock.lock()
            if let cached = resolved[name] { resolveLock.unlock(); return cached }
            resolveLock.unlock()

            let found = newest(among: candidates(for: name), versionArgs: versionArgs)

            resolveLock.lock()
            resolved[name] = found
            resolveLock.unlock()
            if let found { return found }
        }
        return nil
    }

    /// Every copy of a binary this machine has: the usual install prefixes,
    /// plus whatever PATH resolves to (version managers like fvm or asdf).
    private static func candidates(for name: String) -> [String] {
        var paths = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
            .map { "\($0)/\(name)" }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        if let viaPath = which(name), !paths.contains(viaPath) { paths.append(viaPath) }
        return paths
    }

    /// Pick the newest of several copies.
    ///
    /// This is the fix for a real false rejection: macOS ships
    /// /usr/bin/python3 3.9, and a machine with a modern Python installed
    /// alongside it still hit the 3.9 one first, so any file using `match`
    /// (3.10) or `type` aliases (3.12) was reported to the model as corrupted
    /// content and rolled back. The file was fine; the judge was eleven
    /// releases out of date. Order on a list is not a judgement about which
    /// interpreter the user meant — the version is.
    static func newest(among candidates: [String], versionArgs: [String]?) -> String? {
        guard candidates.count > 1, let versionArgs else { return candidates.first }
        let ranked = candidates.map { (path: $0, version: parseVersion(versionString(of: $0, versionArgs: versionArgs) ?? "")) }
        // Nobody reported a version: fall back to list order rather than guess.
        guard ranked.contains(where: { !$0.version.isEmpty }) else { return candidates.first }
        return ranked.max(by: { lexicographicallyPrecedes($0.version, $1.version) })?.path
    }

    /// Compare version components, treating a missing component as zero, so
    /// 3.12 beats 3.9 and 3.12.1 beats 3.12.
    static func lexicographicallyPrecedes(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// The first dotted number in a version banner ("Python 3.12.8",
    /// "v22.3.0", "Dart SDK version: 3.5.0 (stable)"), as components.
    static func parseVersion(_ banner: String) -> [Int] {
        guard let match = banner.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return [] }
        return banner[match].split(separator: ".").compactMap { Int($0) }
    }

    /// Run a binary's version flag and return the banner, or nil.
    static func versionString(of executable: String, versionArgs: [String]?) -> String? {
        guard let versionArgs else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = versionArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe          // python 3.9 and older print -V to stderr
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let banner = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (banner?.isEmpty ?? true) ? nil : banner
    }

    private static func which(_ name: String) -> String? {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        probe.arguments = [name]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func runParser(executable: String, args: [String]) -> ParseOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        // Drain the pipe WHILE the parser runs. Reading only after it exits
        // deadlocks any parser whose diagnostics exceed the 64 KB pipe buffer:
        // it blocks on write, never exits, and the wait below times out.
        let collected = OutputBox()
        out.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        do { try process.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return .unavailable
        }

        // Bounded wait (10s) — a hung parser must never hang the write tool.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            out.fileHandleForReading.readabilityHandler = nil
            return .unavailable
        }
        out.fileHandleForReading.readabilityHandler = nil
        collected.append(out.fileHandleForReading.readDataToEndOfFile())
        let data = collected.data
        guard process.terminationStatus != 0 else { return .passed }
        let diagnostics = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failed(String(diagnostics.prefix(600)))
    }

    /// Model-facing retry guidance appended to every corruption error.
    static let retryGuidance = """
    The file was NOT changed (original restored). The content arrived corrupted \
    in transit — resend the write; for large files write in chunks: an initial \
    write_file under ~4KB, then append:true pieces, each under ~4KB.
    """
}
