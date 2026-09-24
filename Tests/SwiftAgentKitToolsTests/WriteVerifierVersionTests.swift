import Testing
import Foundation
@testable import SwiftAgentKitTools

/// A syntax rejection is only as good as the binary that made it. macOS ships
/// python3 3.9 in /usr/bin, and picking it over a newer copy turned valid
/// modern Python into a "corrupted content" rejection.
struct WriteVerifierVersionTests {

    @Test func versionBannersAreParsed() {
        #expect(WriteVerifier.parseVersion("Python 3.12.8") == [3, 12, 8])
        #expect(WriteVerifier.parseVersion("Python 3.9.6") == [3, 9, 6])
        #expect(WriteVerifier.parseVersion("v22.3.0") == [22, 3, 0])
        #expect(WriteVerifier.parseVersion("Dart SDK version: 3.5.0 (stable) on macOS") == [3, 5, 0])
    }

    @Test func aBannerWithoutAVersionYieldsNothing() {
        #expect(WriteVerifier.parseVersion("") == [])
        #expect(WriteVerifier.parseVersion("command not found") == [])
    }

    /// The comparison that actually mattered: 3.9 must lose to 3.12. A
    /// string or single-component compare gets this backwards.
    @Test func nineDoesNotOutrankTwelve() {
        #expect(WriteVerifier.lexicographicallyPrecedes([3, 9, 6], [3, 12, 8]))
        #expect(!WriteVerifier.lexicographicallyPrecedes([3, 12, 8], [3, 9, 6]))
    }

    @Test func aMissingComponentCountsAsZero() {
        #expect(WriteVerifier.lexicographicallyPrecedes([3, 12], [3, 12, 1]))
        #expect(!WriteVerifier.lexicographicallyPrecedes([3, 12], [3, 12]))
        #expect(WriteVerifier.lexicographicallyPrecedes([3], [3, 1]))
    }

    @Test func aSingleCandidateNeedsNoProbing() {
        #expect(WriteVerifier.newest(among: ["/usr/bin/python3"], versionArgs: ["-V"]) == "/usr/bin/python3")
        #expect(WriteVerifier.newest(among: [], versionArgs: ["-V"]) == nil)
    }

    /// Without a version flag there is nothing to compare, so list order
    /// stands rather than a guess.
    @Test func noVersionFlagMeansListOrder() {
        let paths = ["/usr/bin/swiftc", "/opt/homebrew/bin/swiftc"]
        #expect(WriteVerifier.newest(among: paths, versionArgs: nil) == paths[0])
    }

    /// Candidates that cannot be run report no version; the choice falls back
    /// to list order instead of picking an arbitrary one.
    @Test func unrunnableCandidatesFallBackToListOrder() {
        let paths = ["/nonexistent/one/python3", "/nonexistent/two/python3"]
        #expect(WriteVerifier.newest(among: paths, versionArgs: ["-V"]) == paths[0])
    }

    /// The end-to-end claim, on this machine only: modern Python must survive
    /// the verifier. Skipped where no python3 exists.
    @Test func modernPythonIsNotCalledCorrupt() async throws {
        // Probes spawn processes and wait: off the cooperative pool (BlockingWork).
        try #require(await BlockingWork.run { WriteVerifier.parserAvailable(forExtension: "py") })
        let source = """
        type Pair[T] = tuple[T, T]

        def classify(x: int) -> str:
            match x:
                case 0:
                    return "zero"
                case _:
                    return f"{x!r}"
        """
        // Only meaningful when this machine actually has a Python new enough
        // to accept it; otherwise there is nothing for the fix to find.
        let newEnough = await BlockingWork.run {
            WriteVerifier.newest(
                among: ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
                    .filter { FileManager.default.isExecutableFile(atPath: $0) },
                versionArgs: ["-V"]
            ).map { WriteVerifier.parseVersion(WriteVerifier.versionString(of: $0, versionArgs: ["-V"]) ?? "") }
        }
        try #require(newEnough.map { !WriteVerifier.lexicographicallyPrecedes($0, [3, 12]) } ?? false,
                     "no Python 3.12+ on this machine")
        let reason = await WriteVerifier.corruptionReason(path: "/tmp/x.py", content: source)
        #expect(reason == nil, "valid modern Python must not be reported as corrupted: \(reason ?? "")")
    }

    /// The gate still catches genuinely broken Python.
    @Test func brokenPythonIsStillCaught() async throws {
        try #require(await BlockingWork.run { WriteVerifier.parserAvailable(forExtension: "py") })
        let reason = await WriteVerifier.corruptionReason(path: "/tmp/x.py", content: "def f(:\n  pass\n")
        #expect(reason != nil)
        #expect(reason!.contains("python3"), "the rejection names the interpreter that made it")
    }
}

/// The verifier must judge a file with the interpreter that will actually run
/// it, and must not tell the model a syntax error was a transmission fault —
/// that advice ("resend the write") is a loop with no exit.
struct WriteVerifierJudgeTests {

    private static let appleSystemPython = "/usr/bin/python3"

    /// Python that needs 3.10+.
    private let modern = """
    def classify(x: int) -> str:
        match x:
            case 0:
                return "zero"
            case _:
                return "other"
    """

    /// The host's interpreter is used even when a newer one exists on the
    /// machine — proved by inverting the bug: point it at Apple's 3.9 and the
    /// modern file must be rejected again.
    @Test func theHostsInterpreterWins() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.appleSystemPython))
        let python = Self.appleSystemPython
        let systemVersion = await BlockingWork.run {
            WriteVerifier.parseVersion(WriteVerifier.versionString(of: python, versionArgs: ["-V"]) ?? "")
        }
        try #require(WriteVerifier.lexicographicallyPrecedes(systemVersion, [3, 10]),
                     "this test needs an older /usr/bin/python3 to point at")

        let config = WriteVerifierConfig(interpreters: ["py": Self.appleSystemPython])
        let verdict = await WriteVerifier.rejection(path: "/tmp/x.py", content: modern, config: config)
        #expect(verdict != nil, "the named interpreter decides, not the newest on the machine")
        #expect(verdict!.reason.contains(Self.appleSystemPython))
    }

    /// A path that is not executable is ignored rather than failing the write.
    @Test func aMissingHostedInterpreterFallsBack() async throws {
        try #require(await BlockingWork.run { WriteVerifier.parserAvailable(forExtension: "py") })
        let config = WriteVerifierConfig(interpreters: ["py": "/nowhere/bin/python3"])
        let verdict = await WriteVerifier.rejection(path: "/tmp/x.py", content: "x = 1\n", config: config)
        #expect(verdict == nil)
    }

    /// The loop-breaker: a syntax rejection must not claim transit corruption
    /// or ask for a resend, and must name the judge so the model can write for
    /// the version that will run it.
    @Test func aSyntaxRejectionDoesNotAskForAResend() async throws {
        try #require(await BlockingWork.run { WriteVerifier.parserAvailable(forExtension: "py") })
        let verdict = await WriteVerifier.rejection(path: "/tmp/x.py", content: "def f(:\n  pass\n")
        let rejection = try #require(verdict)
        guard case .syntax = rejection else {
            Issue.record("a syntax error must not be classed as transit corruption")
            return
        }
        #expect(rejection.guidance.contains("NOT transit corruption"))
        #expect(!rejection.guidance.contains("resend the write"))
        #expect(rejection.guidance.contains("python3"), "the model is told which version will run the file")
    }

    /// Real transit corruption keeps the advice that actually helps it.
    @Test func leakedDiffMarkersStillAskForAResend() async {
        let corrupted = (0..<10).map { "+    line \($0)" }.joined(separator: "\n")
        let verdict = await WriteVerifier.rejection(path: "/tmp/x.py", content: corrupted)
        guard case .transitCorruption = verdict else {
            Issue.record("leaked diff markers are transit corruption")
            return
        }
        #expect(verdict!.guidance.contains("resend the write"))
    }

    /// Invalid JSON is the content's fault, not the wire's.
    @Test func invalidJSONIsASyntaxRejection() async {
        let verdict = await WriteVerifier.rejection(path: "/tmp/x.json", content: "{\"a\": }")
        guard case .syntax = verdict else {
            Issue.record("malformed JSON is a syntax error, not transit corruption")
            return
        }
        #expect(!verdict!.guidance.contains("resend the write"))
    }
}
