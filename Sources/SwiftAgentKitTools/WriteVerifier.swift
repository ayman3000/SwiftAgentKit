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
    private static let parsers: [String: (names: [String], args: [String])] = [
        "dart": (["dart"], ["format", "--output=none"]),
        "swift": (["swiftc"], ["-parse"]),
        "py": (["python3"], ["-m", "py_compile"]),
        "js": (["node"], ["--check"]),
        "mjs": (["node"], ["--check"]),
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
              let executable = resolve(names: parser.names) else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("write-verify-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try Data(content.utf8).write(to: tmp) } catch { return nil }

        switch runParser(executable: executable, args: parser.args + [tmp.path]) {
        case .failed(let diagnostics):
            return "content failed the \(parser.names[0]) syntax check:\n\(diagnostics)"
        case .passed, .unavailable:
            return nil
        }
    }

    /// Whether a real parser exists for this extension on this machine —
    /// used by tests to skip environment-dependent assertions.
    public static func parserAvailable(forExtension ext: String) -> Bool {
        if ext == "json" { return true }
        guard let parser = parsers[ext.lowercased()] else { return false }
        return resolve(names: parser.names) != nil
    }

    // MARK: - Process plumbing

    private enum ParseOutcome { case passed, failed(String), unavailable }

    private static let resolveLock = NSLock()
    nonisolated(unsafe) private static var resolved: [String: String?] = [:]

    private static func resolve(names: [String]) -> String? {
        for name in names {
            resolveLock.lock()
            if let cached = resolved[name] { resolveLock.unlock(); return cached }
            resolveLock.unlock()

            let candidates = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
                .map { "\($0)/\(name)" }
            var found: String? = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            if found == nil {
                // PATH lookup via /usr/bin/env — covers version managers (fvm, asdf…).
                let probe = Process()
                probe.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                probe.arguments = [name]
                let pipe = Pipe()
                probe.standardOutput = pipe
                probe.standardError = FileHandle.nullDevice
                if (try? probe.run()) != nil {
                    probe.waitUntilExit()
                    if probe.terminationStatus == 0,
                       let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                        encoding: .utf8) {
                        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !path.isEmpty { found = path }
                    }
                }
            }
            resolveLock.lock()
            resolved[name] = found
            resolveLock.unlock()
            if let found { return found }
        }
        return nil
    }

    private static func runParser(executable: String, args: [String]) -> ParseOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        do { try process.run() } catch { return .unavailable }

        // Bounded wait (10s) — a hung parser must never hang the write tool.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return .unavailable
        }
        guard process.terminationStatus != 0 else { return .passed }
        let data = out.fileHandleForReading.readDataToEndOfFile()
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
