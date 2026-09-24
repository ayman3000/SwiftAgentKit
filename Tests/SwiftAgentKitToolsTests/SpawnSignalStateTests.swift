#if os(macOS)
import Foundation
import Testing
@testable import SwiftAgentKitTools

/// A spawned command must start with a clean signal state. posix_spawn copies
/// the calling thread's blocked-signal mask, and Swift's worker threads block
/// most signals — so every command started with SIGTERM blocked. Flutter
/// stops its compiler with SIGTERM and waits for it to exit; blocked, it never
/// did, and `flutter test` hung for the full 300 s after the tests had passed.
struct SpawnSignalStateTests {
    /// Signals blocked in the child, as perl sees them ("" when none).
    private static let blockedSignals = #"perl -MPOSIX -e 'my $o=POSIX::SigSet->new; sigprocmask(SIG_BLOCK, POSIX::SigSet->new, $o); print "blocked=[", join(",", grep { $o->ismember($_) } 1..31), "]\n"'"#

    @Test func shellCommandsStartWithNoBlockedSignals() async throws {
        let result = try await ShellTool().execute(parameters: ["command": Self.blockedSignals])
        #expect(result.result.contains("blocked=[]"), "\(result.result)")
    }

    @Test func pythonToolCommandsStartWithNoBlockedSignals() async {
        let outcome = await ProcessGroupRunner.run(command: Self.blockedSignals, timeoutSeconds: 20)
        #expect(outcome.output.contains("blocked=[]"), "\(outcome.output)")
    }

    /// The Flutter case in miniature: a command stops its own child with
    /// SIGTERM and waits for it. It must return promptly, not at the timeout.
    @Test func aChildStoppedWithSigtermActuallyStops() async throws {
        let start = Date()
        let result = try await ShellTool().execute(parameters: [
            "command": "sleep 20 & child=$!; kill -TERM $child; wait $child; echo child-exit=$?",
            "timeout_seconds": 15,
        ])
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5, "took \(elapsed)s — SIGTERM did not stop the child")
        #expect(result.result.contains("child-exit=143"), "\(result.result)")
    }
}
#endif
