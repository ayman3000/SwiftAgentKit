import Testing
import Foundation
import SwiftAgentKit
import LLMProviderKitOllama
@testable import SwiftAgentKitTools

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sakt-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Filesystem

@Test func fileWriteThenReadRoundTrips() async throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("note.txt").path

    let write = try await FileWriteTool().execute(parameters: ["path": path, "content": "hello world"])
    #expect(write.isError == false)

    let read = try await FileReadTool().execute(parameters: ["path": path])
    #expect(read.result.contains("hello world"))
}

@Test func fileWriteAppends() async throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("log.txt").path
    _ = try await FileWriteTool().execute(parameters: ["path": path, "content": "a"])
    _ = try await FileWriteTool().execute(parameters: ["path": path, "content": "b", "append": true])
    let read = try await FileReadTool().execute(parameters: ["path": path])
    #expect(read.result.contains("ab"))
}

@Test func fileWriteRequiresConfirmation() {
    #expect(FileWriteTool().requiresConfirmation == true)
    #expect(FileReadTool().requiresConfirmation == false)
}

@Test func readMissingFileErrors() async throws {
    let result = try await FileReadTool().execute(parameters: ["path": "/no/such/file.xyz"])
    #expect(result.isError == true)
}

@Test func listDirShowsEntriesAndMarksDirs() async throws {
    let dir = tempDir()
    try "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

    let result = try await ListDirTool().execute(parameters: ["path": dir.path])
    #expect(result.result.contains("a.txt"))
    #expect(result.result.contains("sub/"))
}

@Test func searchFilesMatchesNameAndContent() async throws {
    let dir = tempDir()
    try "the NEEDLE is here".write(to: dir.appendingPathComponent("doc.md"), atomically: true, encoding: .utf8)
    try "nothing".write(to: dir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)

    let byName = try await SearchFilesTool().execute(parameters: ["directory": dir.path, "name": "doc"])
    #expect(byName.result.contains("doc.md"))
    #expect(byName.result.contains("other.txt") == false)

    let byContent = try await SearchFilesTool().execute(parameters: ["directory": dir.path, "contains": "needle"])
    #expect(byContent.result.contains("doc.md"))
    #expect(byContent.result.contains("other.txt") == false)
}

// MARK: - Shell (macOS)

#if os(macOS)
@Test func shellRunsAndReportsExit() async throws {
    let result = try await ShellTool().execute(parameters: ["command": "echo hi"])
    #expect(result.result.contains("hi"))
    #expect(result.result.contains("exit 0"))
    #expect(ShellTool().requiresConfirmation == true)
}

@Test func shellHonorsWorkingDirectory() async throws {
    let dir = tempDir()
    try "1".write(to: dir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
    let result = try await ShellTool().execute(parameters: ["command": "ls", "working_directory": dir.path])
    #expect(result.result.contains("marker.txt"))
}
#endif

// MARK: - PDF (PDFKit)

#if canImport(PDFKit)
import PDFKit

/// Build a tiny multi-page PDF on disk for the tests.
private func makePDF(pages: Int, at url: URL) {
    let doc = PDFDocument()
    for i in 0..<pages {
        let data = NSAttributedString(string: "Page \(i + 1) body")
        if let page = PDFPage(image: makeImage(text: data.string)) {
            doc.insert(page, at: doc.pageCount)
        }
    }
    doc.write(to: url)
}

#if canImport(AppKit)
import AppKit
private func makeImage(text: String) -> NSImage {
    let size = NSSize(width: 200, height: 200)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(at: NSPoint(x: 10, y: 90), withAttributes: nil)
    image.unlockFocus()
    return image
}
#endif

@Test func pdfInfoReportsPageCount() async throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("doc.pdf")
    makePDF(pages: 3, at: url)

    let result = try await PDFInfoTool().execute(parameters: ["path": url.path])
    #expect(result.isError == false)
    #expect(result.result.contains("Pages: 3"))
}

@Test func pdfMergeAndSplitRoundTrip() async throws {
    let dir = tempDir()
    let a = dir.appendingPathComponent("a.pdf")
    let b = dir.appendingPathComponent("b.pdf")
    makePDF(pages: 2, at: a)
    makePDF(pages: 1, at: b)

    let merged = dir.appendingPathComponent("merged.pdf")
    let mergeResult = try await PDFMergeTool().execute(
        parameters: ["inputs": [a.path, b.path], "output": merged.path])
    #expect(mergeResult.isError == false)
    #expect(PDFDocument(url: merged)?.pageCount == 3)

    let outDir = dir.appendingPathComponent("pages")
    let splitResult = try await PDFSplitTool().execute(
        parameters: ["input": merged.path, "output_directory": outDir.path])
    #expect(splitResult.isError == false)
    let produced = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path))?.filter { $0.hasSuffix(".pdf") } ?? []
    #expect(produced.count == 3)
}

@Test func pdfWriteToolsRequireConfirmation() {
    #expect(PDFMergeTool().requiresConfirmation == true)
    #expect(PDFSplitTool().requiresConfirmation == true)
    #expect(PDFInfoTool().requiresConfirmation == false)
    #expect(PDFExtractTextTool().requiresConfirmation == false)
}
#endif

// MARK: - Live: agent actually invokes the tools (gated)

/// End-to-end proof that a real model picks up and uses the framework tools.
/// Registers `read_file` + a temp file with a sentinel, then asks the agent to
/// read it. Gated on SAK_LIVE_TESTS=1 (local Ollama with `glm-5.2:cloud`).
///   SAK_LIVE_TESTS=1 swift test --filter liveAgentUsesFileTool
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func liveAgentUsesFileTool() async throws {
    let dir = tempDir()
    let file = dir.appendingPathComponent("notes.txt")
    try "The project codename is TOOLS_OK_42.".write(to: file, atomically: true, encoding: .utf8)

    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "glm-5.2:cloud"))
    let agent = Agent(config: AgentConfig(
        provider: provider, model: "glm-5.2:cloud", maxTurns: 4,
        tools: [FileReadTool(), ListDirTool()]
    ))

    let answer = try await agent.run("Read the file at \(file.path) and tell me the project codename it mentions.")
    #expect(answer.contains("TOOLS_OK_42"))
}

/// Reproduces the "wrote the script but didn't run it" failure: does the model
/// CHAIN multiple tool steps (write a script, THEN run it) to completion?
/// Uses autonomous mode (no confirmation gate) + a persistence-oriented prompt.
///   SAK_LIVE_TESTS=1 swift test --filter liveAgentChainsWriteThenRun
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func liveAgentChainsWriteThenRun() async throws {
    let dir = tempDir()
    let script = dir.appendingPathComponent("hello.py").path

    let provider = OllamaProvider(configuration: OllamaProvider.local(model: "glm-5.2:cloud"))
    let agent = Agent(config: AgentConfig(
        provider: provider,
        model: "glm-5.2:cloud",
        systemPrompt: """
        You are a hands-on assistant. When a task needs several tool steps, keep \
        going until it is FULLY done — never stop after one step and never hand \
        back to the user mid-task. After writing a script, RUN it and report the \
        actual output.
        """,
        maxTurns: 8,
        tools: [FileWriteTool(), ShellTool()],
        autonomousMode: true
    ))

    let answer = try await agent.run(
        "Write a Python script to \(script) that prints exactly CHAIN_OK_7, then run it with python3 and tell me its output.")

    // Success = it chained write_file -> run_shell and reported the real output.
    #expect(answer.contains("CHAIN_OK_7"))
    #expect(FileManager.default.fileExists(atPath: script))
}
