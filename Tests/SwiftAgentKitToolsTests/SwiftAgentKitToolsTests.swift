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

@Test func applyPatchEditsFileInPlace() async throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("code.txt").path
    _ = try await FileWriteTool().execute(parameters: ["path": path, "content": "alpha\nbeta\ngamma\n"])

    let patch = "@@ -1,3 +1,3 @@\n alpha\n-beta\n+BETA\n gamma\n"
    let result = try await PatchFileTool().execute(parameters: ["path": path, "patch": patch])
    #expect(result.isError == false)

    let read = try await FileReadTool().execute(parameters: ["path": path])
    #expect(read.result == "alpha\nBETA\ngamma\n")
}

@Test func applyPatchMissingFileErrors() async throws {
    let path = tempDir().appendingPathComponent("nope.txt").path
    let result = try await PatchFileTool().execute(parameters: ["path": path, "patch": "@@ -1 +1 @@\n-x\n+y\n"])
    #expect(result.isError == true)
}

@Test func applyPatchNonMatchingHunkLeavesFileUnchanged() async throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("code.txt").path
    _ = try await FileWriteTool().execute(parameters: ["path": path, "content": "a\nb\nc\n"])

    let result = try await PatchFileTool().execute(parameters: ["path": path, "patch": "@@ -1,2 +1,2 @@\n x\n-y\n+Y\n"])
    #expect(result.isError == true)

    let read = try await FileReadTool().execute(parameters: ["path": path])
    #expect(read.result == "a\nb\nc\n")   // untouched
}

@Test func applyPatchRequiresConfirmation() {
    #expect(PatchFileTool().requiresConfirmation == true)
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

/// The hang bug: `sleep 30 &` orphans a child that keeps the stdout pipe's
/// write-end open after zsh exits. Terminating only the direct child leaves
/// the orphan holding stdout, so an EOF-based read blocks for the full 30s
/// despite the 2s timeout. The fix kills the whole process group, so the read
/// unblocks and we return promptly.
@Test func shellTimesOutEvenWhenOrphanHoldsStdout() async throws {
    let start = Date()
    let result = try await ShellTool(timeoutSeconds: 2).execute(
        parameters: ["command": "echo started; sleep 30 &"]
    )
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 8)                            // must not wait out the 30s orphan
    #expect(result.result.contains("started"))      // captured output before the kill
    #expect(result.result.contains("timeout"))      // reported as a timeout, not a clean exit
}

/// The Stop button: cancelling the surrounding task must SIGKILL the process
/// group and return promptly (not wait out the command or the timeout).
@Test func shellCancellationStopsPromptly() async throws {
    let start = Date()
    let task = Task {
        try await ShellTool(timeoutSeconds: 60).execute(parameters: ["command": "sleep 30"])
    }
    try await Task.sleep(nanoseconds: 400_000_000)   // let it spawn
    task.cancel()
    let result = try await task.value
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 8)
    #expect(result.result.contains("stopped by user"))
}

/// Long-lived servers (`npm start`, `ng serve`) should not block the agent.
/// With `background: true` the tool returns promptly, leaving the process
/// running, and reports its pid.
@Test func shellBackgroundReturnsPromptlyWithPid() async throws {
    let start = Date()
    let result = try await ShellTool().execute(
        parameters: ["command": "sleep 5", "background": true]
    )
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 4)
    #expect(result.isError == false)
    #expect(result.result.lowercased().contains("pid"))
}
#endif

// MARK: - ImportSkillTool

@Test func importSkillRejectsNonHTTPScheme() async throws {
    let tool = ImportSkillTool(fetch: { _ in (Data(), URLResponse()) })
    let r = try await tool.execute(parameters: ["url": "file:///etc/passwd"])
    #expect(r.isError == true)
}

@Test func importSkillReturnsParsedCandidateForSkillFile() async throws {
    let md = "# demo\nTriggers: demo\n\nstep 1\n"
    let tool = ImportSkillTool(fetch: { _ in (Data(md.utf8), URLResponse()) })
    let r = try await tool.execute(parameters: ["url": "https://example.com/skill.md"])
    #expect(r.isError == false)
    #expect(r.result.contains("UNTRUSTED"))
    #expect(r.result.contains("name: demo"))
    #expect(r.result.contains("triggers: demo"))
}

@Test func importSkillReturnsRawForNonSkillContent() async throws {
    let tool = ImportSkillTool(fetch: { _ in (Data("just an article".utf8), URLResponse()) })
    let r = try await tool.execute(parameters: ["url": "https://example.com/x"])
    #expect(r.result.contains("distill"))
    #expect(r.result.contains("just an article"))
}

@Test func importSkillTruncatesOversizeBody() async throws {
    let big = String(repeating: "a", count: 5_000)
    let tool = ImportSkillTool(maxBytes: 1_000, fetch: { _ in (Data(big.utf8), URLResponse()) })
    let r = try await tool.execute(parameters: ["url": "https://example.com/big"])
    #expect(r.result.contains("truncated"))
}

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

// MARK: - Live: hard multi-stage loop with a real goal verifier (gated)

/// Run a shell command and capture stdout+stderr (used by the verifier).
private func shellCapture(_ command: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

actor RetryCounter { private(set) var n = 0; func bump() { n += 1 } }

/// Stresses the full loop: write code -> run it -> a goal verifier RUNS the
/// script and requires exact output -> if wrong, the agent self-repairs and
/// retries until correct. The verifier is deterministic (it actually executes
/// the script), so a wrong first attempt forces iteration.
///   SAK_LIVE_TESTS=1 swift test --filter liveAgentSelfRepairsToExactOutput
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func liveAgentSelfRepairsToExactOutput() async throws {
    let dir = tempDir()
    let script = dir.appendingPathComponent("fib.py").path
    let retries = RetryCounter()

    let agent = Agent(config: AgentConfig(
        provider: OllamaProvider(configuration: OllamaProvider.local(model: "glm-5.2:cloud")),
        model: "glm-5.2:cloud",
        systemPrompt: """
        You are a hands-on coding assistant. When a task needs several steps, keep \
        going until it is FULLY done — never stop after one step or hand back \
        mid-task. After writing a script, RUN it, check the actual output, and if \
        it is wrong, fix the script and run it again until it is correct.
        """,
        maxTurns: 12,
        tools: [FileWriteTool(), ShellTool(), FileReadTool()],
        autonomousMode: true,
        maxVerificationRetries: 4
    ))

    // Goal verifier: actually execute the script and require the exact line.
    var callbacks = AgentCallbacks()
    callbacks.verifyCompletion = { _, _, _ in
        await retries.bump()
        guard FileManager.default.fileExists(atPath: script) else {
            return .unsatisfied(reason: "The script \(script) does not exist yet — create it.")
        }
        let out = shellCapture("python3 \(script)")
        if out.contains("FIB10=55") { return .satisfied }
        return .unsatisfied(reason:
            "Running the script did not print the required line FIB10=55. Actual output was:\n\(out)\n"
            + "Fix \(script) so it prints exactly FIB10=55, then run it again.")
    }
    agent.callbacks = callbacks

    _ = try await agent.run(
        "Write a Python script at \(script) that computes the 10th Fibonacci number "
        + "(with fib(0)=0, fib(1)=1, so the 10th is 55) and prints exactly the line "
        + "FIB10=55. Then run it and make sure the output is correct.")

    // The goal is verifiably met: running the script prints the exact line.
    let finalOut = shellCapture("python3 \(script)")
    #expect(finalOut.contains("FIB10=55"))
    // The verifier ran at least once (proving the goal-gate engaged).
    #expect(await retries.n >= 1)
}

/// End-to-end proof of the isolated-Python-venv workflow: the agent creates a
/// venv, installs a package INTO it, and runs a script that uses it — nothing
/// touches system Python. Uses a tiny package (cowsay) so the install is fast.
///   SAK_LIVE_TESTS=1 swift test --filter liveAgentUsesIsolatedVenv
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func liveAgentUsesIsolatedVenv() async throws {
    let dir = tempDir()
    let venv = dir.appendingPathComponent("venv").path
    let venvPy = "\(venv)/bin/python3"
    let out = dir.appendingPathComponent("out.txt").path

    let agent = Agent(config: AgentConfig(
        provider: OllamaProvider(configuration: OllamaProvider.local(model: "glm-5.2:cloud")),
        model: "glm-5.2:cloud",
        systemPrompt: """
        You are a hands-on assistant. Keep going until the task is FULLY done — \
        run what you write and fix failures until it works. For Python, use ONLY \
        the virtual environment at \(venv): create it with `python3 -m venv \(venv)` \
        if missing, run scripts with `\(venvPy)`, and install packages with \
        `\(venvPy) -m pip install <pkg>`. Never use the system Python.
        """,
        maxTurns: 12,
        tools: [FileWriteTool(), ShellTool(), FileReadTool()],
        autonomousMode: true,
        maxVerificationRetries: 3
    ))
    var callbacks = AgentCallbacks()
    callbacks.verifyCompletion = { _, _, _ in
        FileManager.default.fileExists(atPath: out)
            ? .satisfied
            : .unsatisfied(reason: "The output file \(out) does not exist yet — finish creating it.")
    }
    agent.callbacks = callbacks

    _ = try await agent.run(
        "Using the venv, install the `cowsay` package and write a Python script that "
        + "imports cowsay and writes the text VENV_OK to \(out). Then run it.")

    // The output file exists…
    #expect(FileManager.default.fileExists(atPath: out))
    // …and cowsay was installed INTO the venv (proving the venv was used).
    let venvHasCowsay = shellCapture("\(venvPy) -c 'import cowsay; print(\"has_cowsay\")'")
    #expect(venvHasCowsay.contains("has_cowsay"))
}

// MARK: - PythonTool

#if os(macOS)
@Test func pythonToolRequiresConfirmation() {
    #expect(PythonTool(venvPath: tempDir().appendingPathComponent("venv")).requiresConfirmation == true)
}

/// Live: run_python creates a venv, installs a package into it, and runs code —
/// isolated from system Python. Gated (creates a temp venv, installs cowsay).
///   SAK_LIVE_TESTS=1 swift test --filter pythonToolRunsInIsolatedVenv
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1"))
func pythonToolRunsInIsolatedVenv() async throws {
    let dir = tempDir()
    let venv = dir.appendingPathComponent("venv")
    let tool = PythonTool(venvPath: venv)

    // Plain code (no packages): venv is created, code runs.
    let r1 = try await tool.execute(parameters: ["code": "print('PY_OK', 6*7)"])
    #expect(r1.isError == false)
    #expect(r1.result.contains("PY_OK 42"))
    #expect(r1.result.contains("exit 0"))
    #expect(FileManager.default.isExecutableFile(atPath: venv.appendingPathComponent("bin/python3").path))

    // With a package: it's installed into THIS venv and importable.
    let r2 = try await tool.execute(parameters: [
        "code": "import cowsay; print('COWSAY_OK')",
        "packages": ["cowsay"],
    ])
    #expect(r2.result.contains("COWSAY_OK"))
    // Proof of isolation: the package landed in the temp venv, not system Python.
    let venvHas = shellCapture("\(venv.appendingPathComponent("bin/python3").path) -c 'import cowsay; print(\"in_venv\")'")
    #expect(venvHas.contains("in_venv"))
}
#endif
