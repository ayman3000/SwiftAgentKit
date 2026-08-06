//
//  SubAgentTests.swift
//  SwiftAgentKit
//
//  Unit tests for sub-agent delegation: events, spawner inheritance rules,
//  DelegateTaskTool behavior — no network calls.
//

import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

// MARK: - Event cases

@Test func testSubAgentEventCasesExist() {
    let id = UUID()
    let started = AgentEvent.subAgentStarted(id: id, label: "research task")
    let wrapped = AgentEvent.subAgentEvent(id: id, event: .started(query: "inner"))
    let finished = AgentEvent.subAgentFinished(id: id, summary: "done")

    if case .subAgentStarted(let eid, let label) = started {
        #expect(eid == id)
        #expect(label == "research task")
    } else { Issue.record("expected subAgentStarted") }

    if case .subAgentEvent(let eid, let inner) = wrapped {
        #expect(eid == id)
        if case .started(let query) = inner { #expect(query == "inner") }
        else { Issue.record("expected wrapped .started") }
    } else { Issue.record("expected subAgentEvent") }

    if case .subAgentFinished(let eid, let summary) = finished {
        #expect(eid == id)
        #expect(summary == "done")
    } else { Issue.record("expected subAgentFinished") }
}
