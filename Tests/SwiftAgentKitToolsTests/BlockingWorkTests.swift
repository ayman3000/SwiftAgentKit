#if os(macOS)
import Foundation
import Testing
@testable import SwiftAgentKitTools

/// Blocking work (waiting on a child process, a parser, a pipe) must not sit on
/// Swift's cooperative pool. That pool has one thread per core — three on a CI
/// runner — and every Task.sleep timer needs a free one to wake: with the pool
/// parked on blocking calls, run_shell's 1 s timeout fired after 6.5 s.
@Suite(.serialized)
struct BlockingWorkTests {
    @Test func blockingWorkLeavesThePoolFreeForTimers() async throws {
        let blockers = ProcessInfo.processInfo.activeProcessorCount * 4
        let timerStart = Date()
        async let timer: TimeInterval = {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return Date().timeIntervalSince(timerStart)
        }()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<blockers {
                group.addTask { _ = await BlockingWork.run { usleep(400_000); return 0 } }
            }
        }
        let timerFired = await timer
        // On a starved pool the blockers run in waves of one per core, so the
        // timer waits >= 0.4 s x 4 = 1.6 s (measured: 1.6 s). Half that leaves
        // room for a noisy CI runner and still catches starvation.
        #expect(timerFired < 0.8, "a 100 ms timer fired after \(timerFired)s: blocking work starved the pool")
    }

    @Test func returnsTheBodysValue() async {
        #expect(await BlockingWork.run { 6 * 7 } == 42)
    }
}
#endif
