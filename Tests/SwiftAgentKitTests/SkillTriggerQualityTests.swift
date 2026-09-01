//
//  SkillIndexQualityTests.swift — model-driven skill selection.
//
//  Selection used to be keyword-trigger matching (see git history for the
//  trigger-quality suite). The model now chooses from an always-present
//  index and loads instructions with use_skill; these tests cover the file
//  format's Description line and legacy-file fallback.
//

import Testing
import Foundation
@testable import SwiftAgentKit

@Test func parsesDescriptionLine() {
    let md = """
    # deploy
    Description: Ships a release to production safely.
    Triggers: legacy, words

    1. Run the tests.
    2. Tag and push.
    """
    let skill = FileAgentSkillStore.parse(md)
    #expect(skill?.name == "deploy")
    #expect(skill?.description == "Ships a release to production safely.")
    #expect(skill?.triggerKeywords == ["legacy", "words"])   // preserved, unused
    #expect(skill?.instructions.hasPrefix("1. Run the tests.") == true)
}

@Test func legacyFileWithoutDescriptionDerivesOne() {
    let md = """
    # project-builder
    Triggers: create project, new project

    Building a project? Work like an engineer, not a chatbot:
    1. Think.
    """
    let skill = FileAgentSkillStore.parse(md)
    #expect(skill?.description == "Building a project? Work like an engineer, not a chatbot:")
}

@Test func headerLinesParseInAnyOrder() {
    let md = """
    # x
    Triggers: a, b
    Description: Does x.

    Body here.
    """
    let skill = FileAgentSkillStore.parse(md)
    #expect(skill?.description == "Does x.")
    #expect(skill?.instructions == "Body here.")
}

@Test func saveRoundTripsDescription() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileAgentSkillStore(directory: dir)
    try await store.save(AgentSkill(name: "round trip",
                                    description: "Round-trips descriptions.",
                                    instructions: "Do the thing."))
    let loaded = try await store.loadAll()
    #expect(loaded.count == 1)
    #expect(loaded.first?.description == "Round-trips descriptions.")
    #expect(loaded.first?.instructions == "Do the thing.")
}
