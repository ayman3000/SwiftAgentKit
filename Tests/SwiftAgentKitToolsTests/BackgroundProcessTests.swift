import Testing
import Foundation
@testable import SwiftAgentKitTools

struct BackgroundProcessTests {

    /// Spawn a sleeper in its own process group, the way ShellTool does.
    private static func spawnSleeper(_ script: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        // Its own group, so a group signal reaches the whole tree.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        try? p.run()
        setpgid(p.processIdentifier, p.processIdentifier)
        return p.processIdentifier
    }

    @Test func stoppingEndsTheProcess() async throws {
        let pid = Self.spawnSleeper("sleep 30")
        #expect(BackgroundProcess.isAlive(pid: pid))
        let stopped = await BackgroundProcess.stop(pid: pid, graceSeconds: 2)
        #expect(stopped)
        #expect(!BackgroundProcess.isAlive(pid: pid))
    }

    /// The reason a naive `kill(pid, 0)` liveness check is wrong: a child that
    /// has exited but not been waited for is a zombie, and answers that probe.
    /// Without reaping, a finished server would read as "running" forever.
    @Test func aFinishedChildIsNotReportedAsAlive() async throws {
        let pid = Self.spawnSleeper("exit 0")
        try await Task.sleep(nanoseconds: 500_000_000)   // it has exited; nobody has waited
        #expect(!BackgroundProcess.isAlive(pid: pid))
    }

    /// A process that ignores SIGTERM must still be stopped — politeness has a
    /// deadline.
    @Test func somethingIgnoringTermIsStillKilled() async throws {
        let pid = Self.spawnSleeper("trap '' TERM; sleep 30")
        #expect(BackgroundProcess.isAlive(pid: pid))
        let stopped = await BackgroundProcess.stop(pid: pid, graceSeconds: 0.5)
        #expect(stopped)
    }

    @Test func stoppingSomethingAlreadyGoneSucceeds() async {
        #expect(await BackgroundProcess.stop(pid: 0) == true)
        #expect(await BackgroundProcess.stop(pid: -1) == true)
    }
}
