import Testing
import Foundation
@testable import SwiftAgentKitTools
import SwiftAgentKit

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("doccache-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, ext: String, in dir: URL) -> URL {
    let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
    try! text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Suite(.serialized)
struct DocumentTextCacheTests {
    @Test func storesAndReadsBackByContentDigest() {
        let cache = DocumentTextCache(directory: tempDir())
        let file = write("hello", ext: "bin", in: tempDir())
        let digest = DocumentTextCache.digest(ofFileAt: file.path)!
        #expect(cache.text(digest: digest, key: "docx") == nil)
        cache.store("extracted", digest: digest, key: "docx")
        #expect(cache.text(digest: digest, key: "docx") == "extracted")
        #expect(cache.text(digest: digest, key: "pptx-1-0") == nil, "a different extraction is a different entry")
    }

    /// The same bytes anywhere on disk are the same document.
    @Test func digestFollowsContentNotPath() {
        let dir = tempDir()
        let a = write("same bytes", ext: "txt", in: dir), b = write("same bytes", ext: "txt", in: dir)
        #expect(DocumentTextCache.digest(ofFileAt: a.path) == DocumentTextCache.digest(ofFileAt: b.path))
        let c = write("other bytes", ext: "txt", in: dir)
        #expect(DocumentTextCache.digest(ofFileAt: a.path) != DocumentTextCache.digest(ofFileAt: c.path))
    }

    @Test func evictsTheLeastRecentlyUsedPastTheCap() throws {
        let dir = tempDir()
        let cache = DocumentTextCache(directory: dir, maxBytes: 25)
        cache.store(String(repeating: "a", count: 10), digest: "d1", key: "k")
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: dir.appendingPathComponent("d1-k.txt").path)
        cache.store(String(repeating: "b", count: 10), digest: "d2", key: "k")
        cache.store(String(repeating: "c", count: 10), digest: "d3", key: "k")   // 30 bytes > 25: oldest goes
        #expect(cache.text(digest: "d1", key: "k") == nil)
        #expect(cache.text(digest: "d2", key: "k") != nil)
        #expect(cache.text(digest: "d3", key: "k") != nil)
    }

    /// A cache hit returns before any parsing — so a seeded entry for a file
    /// that is not even a real Word document comes back untouched.
    @Test func officeExtractionReturnsTheCachedTextWithoutParsing() throws {
        let dir = tempDir()
        let cache = DocumentTextCache(directory: dir)
        let fake = write("this is not a docx", ext: "docx", in: dir)
        let digest = DocumentTextCache.digest(ofFileAt: fake.path)!
        cache.store("PROPOSAL AI Copilots — cached", digest: digest, key: "docx")
        let text = try OfficeExtractTextTool.text(at: fake, first: 1, last: nil, cache: cache)
        #expect(text == "PROPOSAL AI Copilots — cached")
    }
}

@Suite(.serialized)
struct DocumentDigestToolTests {
    /// Counts how often the "reading model" is asked, and what it was given.
    final class FakeReader: @unchecked Sendable {
        var calls = 0
        var lastPrompt = ""
        var reply = "1. **What this is**\nA proposal. [line 1]"
        func read(_ prompt: String) async throws -> String { calls += 1; lastPrompt = prompt; return reply }
    }

    @Test func readsOnceWritesNotesAndReusesThemForUnchangedBytes() async throws {
        let dir = tempDir()
        let doc = write("# Proposal\nPhase 1 ships in 12 weeks.\nBudget is undecided.", ext: "md", in: dir)
        let reader = FakeReader()
        let tool = DocumentDigestTool(read: reader.read, cache: DocumentTextCache(directory: tempDir()))

        let first = try await tool.execute(parameters: ["path": doc.path, "focus": "what is undecided"])
        #expect(!first.isError)
        #expect(reader.calls == 1)
        #expect(reader.lastPrompt.contains("Phase 1 ships in 12 weeks."))
        #expect(reader.lastPrompt.contains("Pay particular attention to: what is undecided"))
        #expect(first.result.contains("Notes written at"))
        let notes = dir.appendingPathComponent("naseem/reading/\(doc.deletingPathExtension().lastPathComponent).md")
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(try String(contentsOf: notes, encoding: .utf8).contains("A proposal. [line 1]"))

        let second = try await tool.execute(parameters: ["path": doc.path, "focus": "what is undecided"])
        #expect(reader.calls == 1, "same bytes and focus: the reading model is not asked again")
        #expect(second.result.contains("already existed"))

        // A different focus is a different reading.
        _ = try await tool.execute(parameters: ["path": doc.path, "focus": "who signs off"])
        #expect(reader.calls == 2)
    }

    @Test func aChangedFileIsReadAgain() async throws {
        let dir = tempDir()
        let doc = write("v1", ext: "txt", in: dir)
        let reader = FakeReader()
        let tool = DocumentDigestTool(read: reader.read, cache: DocumentTextCache(directory: tempDir()))
        _ = try await tool.execute(parameters: ["path": doc.path])
        try "v2".write(to: doc, atomically: true, encoding: .utf8)
        _ = try await tool.execute(parameters: ["path": doc.path])
        #expect(reader.calls == 2)
    }

    @Test func emptyAndUnsupportedDocumentsAreSaidPlainly() async throws {
        let dir = tempDir()
        let reader = FakeReader()
        let tool = DocumentDigestTool(read: reader.read, cache: DocumentTextCache(directory: tempDir()))
        let empty = write("   \n", ext: "txt", in: dir)
        let r1 = try await tool.execute(parameters: ["path": empty.path])
        #expect(!r1.isError && r1.result.contains("no extractable text"))
        let odd = write("x", ext: "sketch", in: dir)
        let r2 = try await tool.execute(parameters: ["path": odd.path])
        #expect(r2.isError && r2.result.contains(".sketch"))
        #expect(reader.calls == 0)
    }

    @Test func aFailingReaderIsAnErrorNotACachedBlank() async throws {
        struct Boom: Error {}
        let dir = tempDir()
        let doc = write("content", ext: "txt", in: dir)
        let cache = DocumentTextCache(directory: tempDir())
        let tool = DocumentDigestTool(read: { _ in throw Boom() }, cache: cache)
        let r = try await tool.execute(parameters: ["path": doc.path])
        #expect(r.isError && r.result.contains("reading model failed"))
        #expect(cache.text(digest: DocumentTextCache.digest(ofFileAt: doc.path)!, key: "digest") == nil)
    }

    @Test func officeFilesAreRefusedWithTheHostsNoteWhenGated() async throws {
        let dir = tempDir()
        let doc = write("not really a docx", ext: "docx", in: dir)
        let reader = FakeReader()
        let tool = DocumentDigestTool(read: reader.read, cache: DocumentTextCache(directory: tempDir()),
                                      officeUnavailableNote: "Word files need Naseem Pro.")
        let r = try await tool.execute(parameters: ["path": doc.path])
        #expect(r.isError && r.result == "Word files need Naseem Pro.")
        #expect(reader.calls == 0)
    }

    /// An empty answer must not invite three more identical calls.
    @Test func anEmptyAnswerTellsTheCallerToReadTheFileDirectly() async throws {
        let dir = tempDir()
        let doc = write("content", ext: "txt", in: dir)
        let tool = DocumentDigestTool(read: { _ in "   \n  " }, cache: DocumentTextCache(directory: tempDir()))
        let r = try await tool.execute(parameters: ["path": doc.path])
        #expect(r.isError)
        #expect(r.result.contains("Do NOT call document_digest again"))
        #expect(r.result.contains("read_file"))
        #expect(r.result.contains("non-reasoning"))
        #expect(r.result.contains(doc.lastPathComponent))
    }

    @Test func promptAsksForLocationsAndFaithfulness() {
        let p = DocumentDigestTool.prompt(document: "spec.pdf", kind: "PDF", units: "page", focus: "", truncated: true, text: "body")
        #expect(p.contains("[page N]"))
        #expect(p.contains("never invent"))
        #expect(p.contains("Open questions"))
        #expect(p.contains("cut at"))
        #expect(DocumentDigestTool.cacheKey(focus: "") == "digest")
        #expect(DocumentDigestTool.cacheKey(focus: "a") != DocumentDigestTool.cacheKey(focus: "b"))
    }
}
