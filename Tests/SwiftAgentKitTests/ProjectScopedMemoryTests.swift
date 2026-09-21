import Testing
import Foundation
@testable import SwiftAgentKit

/// A fact learned inside one project must not be presented as standing truth
/// in another. That is not a tidiness concern: an agent handed another
/// project's decisions acts on them.
struct ProjectScopedMemoryTests {

    private func makeStore() -> (FileAgentMemoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memtest-\(UUID().uuidString)")
        return (FileAgentMemoryStore(directory: dir), dir)
    }

    @Test func aProjectFactIsInvisibleToAnotherProject() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.save(AgentMemoryEntry(kind: .fact, title: "Phase order",
                                              content: "Phase 1 starts with the voice agent",
                                              project: "XonTel"))

        let inXonTel = await store.loadContextBlock(project: "XonTel")
        #expect(inXonTel.contains("Phase order"))
        #expect(inXonTel.contains("XonTel"))

        let inQuakely = await store.loadContextBlock(project: "Quakely")
        #expect(!inQuakely.contains("Phase order"), "another project must not see it")

        let noProject = await store.loadContextBlock(project: nil)
        #expect(!noProject.contains("Phase order"), "a projectless chat must not see it either")
    }

    @Test func aGlobalFactIsVisibleEverywhere() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.save(AgentMemoryEntry(kind: .fact, title: "Editor of choice",
                                              content: "Xcode", project: nil))
        for project in ["XonTel", "Quakely", nil] {
            let block = await store.loadContextBlock(project: project)
            #expect(block.contains("Editor of choice"), "global memory holds everywhere")
        }
    }

    /// Two projects may legitimately have a fact with the same title.
    @Test func projectsDoNotCollideOnTitle() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.save(AgentMemoryEntry(kind: .fact, title: "Pricing",
                                              content: "9 dollars", project: "Quakely"))
        try await store.save(AgentMemoryEntry(kind: .fact, title: "Pricing",
                                              content: "free tier only", project: "XonTel"))

        let all = try await store.loadAll().filter { $0.kind == .fact }
        #expect(all.count == 2)
        #expect(all.first { $0.project == "Quakely" }!.content.contains("9 dollars"))
        #expect(all.first { $0.project == "XonTel" }!.content.contains("free tier"))
    }

    @Test func loadAllReportsWhichProjectOwnsEachFact() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.save(AgentMemoryEntry(kind: .fact, title: "Global thing", content: "x"))
        try await store.save(AgentMemoryEntry(kind: .fact, title: "Project thing",
                                              content: "y", project: "XonTel"))

        let facts = try await store.loadAll().filter { $0.kind == .fact }
        #expect(facts.first { $0.title == "Global thing" }!.project == nil)
        #expect(facts.first { $0.title == "Project thing" }!.project == "XonTel")
        #expect(store.knownProjects == ["XonTel"], "the name the caller used, not the folder slug")
    }

    /// The inspector deletes by title and does not track where a fact lives.
    @Test func deletingByTitleClearsAProjectFactToo() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.save(AgentMemoryEntry(kind: .fact, title: "Phase order",
                                              content: "z", project: "XonTel"))
        try await store.delete(id: "Phase order")

        #expect(try await store.loadAll().filter { $0.kind == .fact }.isEmpty)
        let block = await store.loadContextBlock(project: "XonTel")
        #expect(!block.contains("Phase order"), "the project index is cleaned up as well")
    }

    /// User and agent memories describe the person and the agent, so a project
    /// scope is meaningless for them.
    @Test func onlyFactsAreScoped() {
        #expect(RememberTool.project(for: .fact, scope: nil, activeProject: "XonTel") == "XonTel")
        #expect(RememberTool.project(for: .fact, scope: "project", activeProject: "XonTel") == "XonTel")
        #expect(RememberTool.project(for: .fact, scope: "global", activeProject: "XonTel") == nil)
        #expect(RememberTool.project(for: .user, scope: "project", activeProject: "XonTel") == nil)
        #expect(RememberTool.project(for: .agent, scope: "project", activeProject: "XonTel") == nil)
    }

    /// Outside a project there is nothing to scope to, whatever is asked for.
    @Test func withoutAnActiveProjectEverythingIsGlobal() {
        #expect(RememberTool.project(for: .fact, scope: "project", activeProject: nil) == nil)
        #expect(RememberTool.project(for: .fact, scope: nil, activeProject: nil) == nil)
    }
}
