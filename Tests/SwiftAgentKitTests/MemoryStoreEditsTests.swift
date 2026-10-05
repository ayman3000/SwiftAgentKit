import Testing
import Foundation
@testable import SwiftAgentKit

/// Store-level edits: every write follows MemoryDocuments' rules and returns
/// before/after text, so an undo restores exactly what was there.
struct MemoryStoreEditsTests {

    private func makeStore(defaultAgentProfile: String? = nil) -> (FileAgentMemoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memedits-\(UUID().uuidString)", isDirectory: true)
        return (FileAgentMemoryStore(directory: dir, defaultAgentProfile: defaultAgentProfile), dir)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func aUserSaveReplacesByKey() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.save(AgentMemoryEntry(kind: .user, title: "Name", content: "A"))
        try await store.save(AgentMemoryEntry(kind: .user, title: "Name", content: "B"))
        let doc = read(dir.appendingPathComponent("USER.md")) ?? ""
        #expect(MemoryDocuments.userKeys(doc).filter { $0.key == "Name" }.map { $0.value } == ["B"])
    }

    @Test func anAgentSaveNeverOverwritesTheProfile() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.seedIfNeeded()
        try await store.save(AgentMemoryEntry(kind: .agent, title: "Paywall copy", content: "Check the finder first"))
        let doc = read(dir.appendingPathComponent("AGENT.md")) ?? ""
        #expect(MemoryDocuments.isStructuredAgentProfile(doc))
        #expect(MemoryDocuments.agentSection(.mission, in: doc) == MemoryDocuments.agentSection(.mission, in: MemoryDocuments.defaultAgentProfile))
        #expect(MemoryDocuments.agentSection(.principles, in: doc) == "- Paywall copy: Check the finder first")
    }

    @Test func anAppSuppliedDefaultIsSeeded() {
        let (store, dir) = makeStore(defaultAgentProfile: "# Custom\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        store.seedIfNeeded()
        #expect(read(dir.appendingPathComponent("AGENT.md")) == "# Custom\n")
        #expect(store.defaultAgentProfile == "# Custom\n")
    }

    @Test func aSectionEditReturnsBeforeAndAfterAndRestoreUndoesIt() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.seedIfNeeded()
        let change = try store.editAgentProfile(section: .identity, change: "Name: Nemo")
        #expect(change.target == .agentProfile)
        #expect(change.before == MemoryDocuments.defaultAgentProfile)
        #expect(store.currentText(of: .agentProfile) == change.after)
        try store.restore(change)
        #expect(store.currentText(of: .agentProfile) == MemoryDocuments.defaultAgentProfile)
    }

    @Test func movingAFactKeepsOneHeadingAndUpdatesBothIndexes() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsertFact(title: "Phase order", body: "Voice agent first", project: nil)
        let changes = try store.moveFact(title: "Phase order", from: nil, to: "XonTel")
        #expect(changes.count == 2)
        let moved = dir.appendingPathComponent("memory/projects/xontel/phase-order.md")
        #expect(read(moved) == "# Phase order\n\nVoice agent first\n")
        #expect(read(dir.appendingPathComponent("memory/phase-order.md")) == nil)
        #expect(await store.loadContextBlock(project: "XonTel").contains("Phase order"))
        #expect(!(await store.loadContextBlock(project: nil)).contains("Phase order"))
    }

    @Test func movingHealsAnAlreadyDoubledHeading() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsertFact(title: "T", body: "x", project: nil)
        try "# T\n\n# T\n\n# T\n\nbody\n".write(to: dir.appendingPathComponent("memory/t.md"), atomically: true, encoding: .utf8)
        try store.moveFact(title: "T", from: nil, to: "Quakely")
        #expect(read(dir.appendingPathComponent("memory/projects/quakely/t.md")) == "# T\n\nbody\n")
    }

    @Test func restoringAMoveInReverseOrderPutsItBack() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsertFact(title: "T", body: "body", project: nil)
        let changes = try store.moveFact(title: "T", from: nil, to: "Quakely")
        for change in changes.reversed() { try store.restore(change) }
        let facts = store.snapshot().facts
        #expect(facts == [MemoryFact(title: "T", body: "body", project: nil)])
    }

    @Test func deletingAMissingFactThrows() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: MemoryStoreError.factNotFound("Nope")) {
            try store.deleteFact(title: "Nope", project: nil)
        }
    }

    @Test func theSnapshotStripsHeadings() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsertFact(title: "Editor", body: "Xcode", project: nil)
        try store.upsertFact(title: "Pricing", body: "9 dollars", project: "Quakely")
        try store.setUserKey("Name", value: "Ayman")
        let snap = store.snapshot()
        #expect(Set(snap.facts) == [MemoryFact(title: "Editor", body: "Xcode", project: nil),
                                    MemoryFact(title: "Pricing", body: "9 dollars", project: "Quakely")])
        #expect(MemoryDocuments.userValue("Name", in: snap.userProfile) == "Ayman")
    }

    @Test func anUnchangedWriteReportsEqualBeforeAndAfter() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.setUserKey("Name", value: "Ayman")
        let again = try store.setUserKey("Name", value: "Ayman")
        #expect(again.before == again.after)
    }
}
