import Testing
import Foundation
@testable import SwiftAgentKit

/// Level 3 of progressive disclosure: a skill's bundled files cost nothing
/// until the model reads one. The store's only job is to say where they are —
/// nothing here fetches, parses or lists them, because listing would push the
/// model to read files the task never needed.
struct SkillResourcesTests {
    private func store() -> (FileAgentSkillStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-\(UUID().uuidString)")
        return (FileAgentSkillStore(directory: dir), dir)
    }

    @Test func aSkillWithoutFilesHasNoResourcesPath() async throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.save(AgentSkill(name: "prose only", description: "d", instructions: "do it"))
        let loaded = try #require(try await store.loadAll().first)
        #expect(loaded.resourcesPath == nil)
        // …and its render is unchanged, so every existing skill reads as before.
        #expect(!loaded.render().contains("ships files"))
    }

    @Test func aSiblingDirectoryBecomesTheResourcesPath() async throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.save(AgentSkill(name: "delegate", description: "d", instructions: "see refs"))
        let resources = store.resourcesDirectory(forSkillNamed: "delegate")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "# brief".write(to: resources.appendingPathComponent("brief.md"),
                            atomically: true, encoding: .utf8)

        let loaded = try #require(try await store.loadAll().first)
        #expect(loaded.resourcesPath == resources.path)
    }

    /// The render names the directory and nothing inside it.
    @Test func theRenderGivesTheBasePathOnly() async throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.save(AgentSkill(name: "delegate", description: "d", instructions: "see refs"))
        let resources = store.resourcesDirectory(forSkillNamed: "delegate")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "x".write(to: resources.appendingPathComponent("secret-reference.md"),
                      atomically: true, encoding: .utf8)

        let rendered = try #require(try await store.loadAll().first).render()
        #expect(rendered.contains(resources.path))
        #expect(!rendered.contains("secret-reference.md"), "listing files defeats progressive disclosure")
    }

    /// A deleted skill takes its files with it — otherwise scripts outlive the
    /// skill and a later one of the same name inherits them.
    @Test func deletingASkillRemovesItsFiles() async throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.save(AgentSkill(name: "delegate", description: "d", instructions: "x"))
        let resources = store.resourcesDirectory(forSkillNamed: "delegate")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "console.log(1)".write(to: resources.appendingPathComponent("relay.mjs"),
                                   atomically: true, encoding: .utf8)

        try await store.delete(name: "delegate")
        #expect(!FileManager.default.fileExists(atPath: resources.path))
        #expect(try await store.loadAll().isEmpty)
    }

    /// Re-saving a skill must not destroy its files: the store writes the
    /// document, never the directory.
    @Test func savingAgainKeepsTheFiles() async throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.save(AgentSkill(name: "delegate", description: "d", instructions: "v1"))
        let resources = store.resourcesDirectory(forSkillNamed: "delegate")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "x".write(to: resources.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)

        try await store.save(AgentSkill(name: "delegate", description: "d", instructions: "v2"))
        let loaded = try #require(try await store.loadAll().first)
        #expect(loaded.instructions.contains("v2"))
        #expect(loaded.resourcesPath == resources.path)
        #expect(FileManager.default.fileExists(atPath: resources.appendingPathComponent("brief.md").path))
    }

    /// A blank name must still resolve to a SUBdirectory, never the store root
    /// — `delete` removes that directory, and the root holds every skill.
    @Test func aBlankNameNeverResolvesToTheStoreRoot() {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["   ", "", "///", "!!!"] {
            let resolved = store.resourcesDirectory(forSkillNamed: name).standardizedFileURL
            #expect(resolved != dir.standardizedFileURL, "\(name.debugDescription) resolved to the root")
            #expect(resolved.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        }
    }
}
