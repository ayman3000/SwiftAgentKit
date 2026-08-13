import Testing
@testable import SwiftAgentKit

struct LoopDetectorTests {
    @Test func signatureIsStableAcrossArgOrder() {
        let a = LoopDetector.signature(name: "sim_ui", arguments: ["bundle_id": AnyCodable("x"), "z": AnyCodable(1)])
        let b = LoopDetector.signature(name: "sim_ui", arguments: ["z": AnyCodable(1), "bundle_id": AnyCodable("x")])
        #expect(a == b)
    }

    @Test func signatureNoArgsIsNameOnly() {
        #expect(LoopDetector.signature(name: "sim_apps", arguments: [:]) == "sim_apps")
    }

    @Test func distinctArgsDistinctSignature() {
        let a = LoopDetector.signature(name: "read_file", arguments: ["path": AnyCodable("/a")])
        let b = LoopDetector.signature(name: "read_file", arguments: ["path": AnyCodable("/b")])
        #expect(a != b)
    }

    @Test func threeInWindowNudgesOnceThenSilentUntilStop() {
        let d = LoopDetector(config: .default)   // window 6, nudge 3, stop 5
        #expect(d.record(["s"]) == .none)                       // count 1
        #expect(d.record(["s"]) == .none)                       // count 2
        #expect(d.record(["s"]) == .nudge(signature: "s", count: 3))  // count 3 → nudge
        #expect(d.record(["s"]) == .none)                       // count 4 → already nudged, not yet stop
        #expect(d.record(["s"]) == .stop(signature: "s", count: 5))   // count 5 → stop
    }

    @Test func interleavedStillCounts() {
        let d = LoopDetector(config: LoopDetectionConfig(windowSize: 6, nudgeThreshold: 3, stopThreshold: 5))
        #expect(d.record(["s"]) == .none)
        #expect(d.record(["other"]) == .none)
        #expect(d.record(["s"]) == .none)
        #expect(d.record(["other2"]) == .none)
        #expect(d.record(["s"]) == .nudge(signature: "s", count: 3))   // 3 of "s" within last 6
    }

    @Test func fallsOutOfWindow() {
        let d = LoopDetector(config: LoopDetectionConfig(windowSize: 3, nudgeThreshold: 3, stopThreshold: 5))
        #expect(d.record(["s"]) == .none)
        #expect(d.record(["a"]) == .none)
        #expect(d.record(["b"]) == .none)   // window now [s,a,b]
        #expect(d.record(["s"]) == .none)   // window [a,b,s] → only 1 "s" → no trip
    }

    @Test func windowingIsDiscriminative() {
        // nudgeThreshold 2, windowSize 3. Record "s", then 3 non-"s" turns that
        // push "s" out of the last-3 window, then one more "s". Whole-history
        // count of "s" is 2 (would trip nudge if counting all history), but within
        // the last-3 window there's only 1 "s" → must NOT trip. Proves suffix(window).
        let d = LoopDetector(config: LoopDetectionConfig(windowSize: 3, nudgeThreshold: 2, stopThreshold: 5))
        #expect(d.record(["s"]) == .none)   // history [s]
        #expect(d.record(["a"]) == .none)   // [s,a]
        #expect(d.record(["b"]) == .none)   // [s,a,b]
        #expect(d.record(["c"]) == .none)   // window [a,b,c] — s fell out
        #expect(d.record(["s"]) == .none)   // window [b,c,s] → only 1 "s" (whole-history=2). Must be .none.
    }

    @Test func stopBeatsNudgeInSameTurn() {
        // "s" already at 4; a turn that pushes it to 5 AND introduces a fresh 3rd
        // of "t" must return .stop (for s), not .nudge.
        let d = LoopDetector(config: LoopDetectionConfig(windowSize: 12, nudgeThreshold: 3, stopThreshold: 5))
        _ = d.record(["s"]); _ = d.record(["s"]); _ = d.record(["s"]); _ = d.record(["s"])   // s=4 (nudged at 3)
        _ = d.record(["t"]); _ = d.record(["t"])                                              // t=2
        #expect(d.record(["s", "t"]) == .stop(signature: "s", count: 5))
    }
}
