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
        try #require(WriteVerifier.parserAvailable(forExtension: "py"))
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
        let newEnough = WriteVerifier.newest(
            among: ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
                .filter { FileManager.default.isExecutableFile(atPath: $0) },
            versionArgs: ["-V"]
        ).map { WriteVerifier.parseVersion(WriteVerifier.versionString(of: $0, versionArgs: ["-V"]) ?? "") }
        try #require(newEnough.map { !WriteVerifier.lexicographicallyPrecedes($0, [3, 12]) } ?? false,
                     "no Python 3.12+ on this machine")
        let reason = await WriteVerifier.corruptionReason(path: "/tmp/x.py", content: source)
        #expect(reason == nil, "valid modern Python must not be reported as corrupted: \(reason ?? "")")
    }

    /// The gate still catches genuinely broken Python.
    @Test func brokenPythonIsStillCaught() async throws {
        try #require(WriteVerifier.parserAvailable(forExtension: "py"))
        let reason = await WriteVerifier.corruptionReason(path: "/tmp/x.py", content: "def f(:\n  pass\n")
        #expect(reason != nil)
        #expect(reason!.contains("python3"), "the rejection names the interpreter that made it")
    }
}
