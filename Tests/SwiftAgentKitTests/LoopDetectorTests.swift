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

    @Test func errorDescribesTheLoop() {
        let e = AgentError.loopDetected(signature: "sim_ui:{\"bundle_id\":\"x\"}", count: 5)
        #expect(e.errorDescription?.contains("sim_ui") == true)
        #expect(e.errorDescription?.lowercased().contains("without progress") == true)
    }

    @Test func configDefaultsLoopDetectionOn() {
        let cfg = AgentConfig(provider: PlainAnswerProvider(text: "test"))
        #expect(cfg.loopDetection == .default)
    }

    @Test func loopDetectedRecoverySuggestionMentionsDifferentApproach() {
        let err = AgentError.loopDetected(signature: "x", count: 5)
        let suggestion = err.recoverySuggestion
        #expect(suggestion != nil)
        #expect(suggestion?.contains("different approach") == true)
    }
}

// MARK: - Repeating-cycle guard (A→B→A→B evades per-signature counting)

@Test func alternatingCycleNudgesThenStops() {
    // The observed live failure: sim_rotate → sim_screenshot repeated
    // endlessly. Per-signature counting peaks at windowSize/2 = 3 < stop(5),
    // so the old detector could NEVER stop it. The cycle guard must.
    let d = LoopDetector(config: .default)   // nudge 3, stop 5
    let rotate = "sim_rotate:{\"orientation\":\"landscape_left\"}"
    let shot = "sim_screenshot"
    var actions: [LoopAction] = []
    for _ in 0..<6 {
        actions.append(d.record([rotate]))
        actions.append(d.record([shot]))
    }
    // A nudge fires once the block has repeated nudgeThreshold times…
    #expect(actions.contains { if case .nudge(let s, _) = $0 { return s.hasPrefix("cycle[") } ; return false })
    // …and the run STOPS at stopThreshold repetitions instead of spinning forever.
    #expect(actions.contains { if case .stop(let s, _) = $0 { return s.hasPrefix("cycle[") } ; return false })
}

@Test func cycleSignatureUsesToolNamesOnly() {
    // Per-signature nudges legitimately fire first (each tool hits count 3);
    // the CYCLE guard is what eventually STOPS the run — and its label must
    // read as tool names, not raw signatures with JSON args.
    let d = LoopDetector(config: .default)
    let a = "tool_a:{\"x\":1}", b = "tool_b:{\"y\":2}"
    var stopLabel: String?
    for _ in 0..<8 {
        if case .stop(let s, _) = d.record([a, b]) { stopLabel = s; break }
    }
    #expect(stopLabel == "cycle[tool_a → tool_b]")
}

@Test func threeToolCycleDetected() {
    let d = LoopDetector(config: .default)
    var stopped = false
    for _ in 0..<6 {
        for sig in ["a:1", "b:2", "c:3"] {
            if case .stop(let s, _) = d.record([sig]), s.hasPrefix("cycle[") { stopped = true }
        }
    }
    #expect(stopped)
}

@Test func variedWorkIsNotACycle() {
    // Legitimate iterative work (read → patch → build with CHANGING args)
    // must never trip the cycle guard.
    let d = LoopDetector(config: .default)
    var tripped = false
    for i in 0..<12 {
        let sigs = ["read_file:{\"path\":\"f\(i)\"}", "apply_patch:{\"n\":\(i)}", "run_shell:{\"c\":\(i)}"]
        for sig in sigs {
            if case .none = d.record([sig]) { continue } else { tripped = true }
        }
    }
    #expect(!tripped)
}

@Test func uniformRunsStillHandledByPerSignatureGuard() {
    // AAAA… must keep its original nudge/stop shape (not double-fire as a cycle).
    let d = LoopDetector(config: .default)
    var stops = 0, cycleActions = 0
    for _ in 0..<8 {
        switch d.record(["same:call"]) {
        case .stop(let s, _): stops += 1; if s.hasPrefix("cycle[") { cycleActions += 1 }
        case .nudge(let s, _): if s.hasPrefix("cycle[") { cycleActions += 1 }
        case .none: break
        }
    }
    #expect(stops >= 1)
    #expect(cycleActions == 0)
}

@Test func fourToolCycleFromLiveRunIsStopped() {
    // The exact live evasion after the length-3 guard shipped: a 4-tool
    // cycle (terminate → launch → wait → screenshot) that ALSO starves the
    // per-signature window (6 calls = 1.5 cycles → count 2, no nudge).
    let d = LoopDetector(config: .default)
    let cycle = ["sim_terminate:{\"b\":\"x\"}", "sim_launch:{\"b\":\"x\"}",
                 "sim_wait:{\"b\":\"x\"}", "sim_screenshot"]
    var nudgedAt: Int?, stoppedAt: Int?
    for rep in 1...6 {
        for sig in cycle {
            switch d.record([sig]) {
            case .nudge(let s, _) where s.hasPrefix("cycle["): nudgedAt = nudgedAt ?? rep
            case .stop(let s, _) where s.hasPrefix("cycle["): stoppedAt = stoppedAt ?? rep
            default: break
            }
        }
        if stoppedAt != nil { break }
    }
    #expect(nudgedAt == 3)    // warned at 3 verbatim repetitions
    #expect(stoppedAt == 4)   // stopped one repetition later, not at 5
}

@Test func fiveToolCycleDetected() {
    let d = LoopDetector(config: .default)
    let cycle = (0..<5).map { "t\($0):a" }
    var stopped = false
    for _ in 1...5 {
        for sig in cycle {
            if case .stop(let s, _) = d.record([sig]), s.hasPrefix("cycle[") { stopped = true }
        }
    }
    #expect(stopped)
}
