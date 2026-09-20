//
//  DocumentDigestTool.swift
//  SwiftAgentKitTools
//
//  Read a document once, with a model chosen for reading, and write notes
//  everyone else works from. The chat model is expensive and so is every
//  sub-agent's context; a long proposal read three times is paid for three
//  times. This turns the document into a notes file — what it is, the facts
//  that matter, open questions, each with the page or slide it came from —
//  keyed by the document's content, so the reading happens once.
//
//  The kit knows nothing about providers. The host hands in `read`, a
//  closure that sends a prompt to whatever it calls the reading model.
//

import CryptoKit
import Foundation
import PDFKit
import SwiftAgentKit

public struct DocumentDigestTool: AgentTool {
    public let name = "document_digest"
    public var isReadOnly: Bool { false }   // it writes a notes file
    public let description = """
    Read a document ONCE with the reading model and write notes to a file: what \
    it is, the facts that matter (with page/slide/sheet references), open \
    questions, and what to open the original for. Use this BEFORE delegating \
    anything that involves the document, and instead of pasting a long \
    document into your own context. The notes are cached by the file's content, \
    so calling it again for an unchanged file is free. Returns the notes path \
    and the notes. PDF, Word, PowerPoint, Excel, Markdown and plain text.
    """
    public let parameters = ToolParameters(properties: [
        "path": ToolParameterProperty(type: "string", description: "The document to read."),
        "focus": ToolParameterProperty(type: "string", description: "Optional: what the notes should pay attention to (a question, a mission)."),
        "notes_dir": ToolParameterProperty(type: "string", description: "Where to write the notes (default: <document's folder>/naseem/reading)."),
    ], required: ["path"])
    public var inputExamples: [String] { [
        #"{"path": "/Users/me/proj/proposal.docx"}"#,
        #"{"path": "/Users/me/proj/spec.pdf", "focus": "what must ship in phase 1, and what is undecided"}"#,
    ] }

    /// Prompt → the reading model's answer. Supplied by the host.
    public typealias Reader = @Sendable (String) async throws -> String

    let read: Reader
    let cache: DocumentTextCache
    /// The most text handed to the reading model in one go.
    let maxChars: Int
    /// When set, Word/PowerPoint/Excel are refused with this sentence — the
    /// host gates Office reading the same way for office_extract_text.
    let officeUnavailableNote: String?

    public init(read: @escaping Reader, cache: DocumentTextCache = DocumentTextCache(),
                maxChars: Int = 160_000, officeUnavailableNote: String? = nil) {
        self.read = read
        self.cache = cache
        self.maxChars = maxChars
        self.officeUnavailableNote = officeUnavailableNote
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = parameters["path"] as? String, !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "document_digest requires a `path`.")
        }
        let url = URL(fileURLWithPath: expandPath(raw))
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error(toolCallId: "", toolName: name, message: "No such file: \(raw)")
        }
        let focus = (parameters["focus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notesDir = (parameters["notes_dir"] as? String).map { URL(fileURLWithPath: expandPath($0)) }
            ?? url.deletingLastPathComponent().appendingPathComponent("naseem/reading", isDirectory: true)
        let notesURL = notesDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".md")

        guard let digest = DocumentTextCache.digest(ofFileAt: url.path) else {
            return .error(toolCallId: "", toolName: name, message: "Could not read \(url.lastPathComponent).")
        }
        let key = Self.cacheKey(focus: focus)

        // Same bytes, same focus: the notes already exist. Make sure the file
        // is on disk (a project may have been cleaned) and hand them back.
        if let notes = cache.text(digest: digest, key: key) {
            Self.write(notes, to: notesURL, source: url, digest: digest)
            return .success(toolCallId: "", toolName: name, result: Self.reply(notesURL: notesURL, notes: notes, cached: true))
        }

        if let officeUnavailableNote, ["docx", "pptx", "xlsx"].contains(url.pathExtension.lowercased()) {
            return .error(toolCallId: "", toolName: name, message: officeUnavailableNote)
        }
        let extracted: DocumentText
        do { extracted = try Self.extract(url, cache: cache) }
        catch { return .error(toolCallId: "", toolName: name, message: "Could not read \(url.lastPathComponent): \(error.localizedDescription)") }
        guard !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success(toolCallId: "", toolName: name,
                            result: "\(url.lastPathComponent) has no extractable text (a scan or an image). Use pdf_extract_text with ocr for a scanned PDF, or look at it with the vision tools.")
        }
        var body = extracted.text
        var truncated = false
        if body.count > maxChars { body = String(body.prefix(maxChars)); truncated = true }

        let prompt = Self.prompt(document: url.lastPathComponent, kind: extracted.kind, units: extracted.units,
                                 focus: focus, truncated: truncated, text: body)
        let notes: String
        do { notes = try await read(prompt) }
        catch { return .error(toolCallId: "", toolName: name, message: "The reading model failed: \(error.localizedDescription)") }
        guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Calling again will fail the same way, and each attempt is a
            // billed request: say what to do instead (observed 2026-09-20,
            // four identical calls before the model worked it out itself).
            return .error(toolCallId: "", toolName: name, message: Self.emptyAnswerGuidance(file: url.lastPathComponent))
        }
        cache.store(notes, digest: digest, key: key)
        Self.write(notes, to: notesURL, source: url, digest: digest)
        return .success(toolCallId: "", toolName: name, result: Self.reply(notesURL: notesURL, notes: notes, cached: false))
    }

    // MARK: Pieces (pure where they can be — tested)

    static func cacheKey(focus: String) -> String {
        focus.isEmpty ? "digest" : "digest-" + DocumentTextCache.shortHash(focus)
    }

    /// What the reading model is asked. Faithfulness over flair: every fact
    /// carries where it came from, and nothing is invented.
    static func prompt(document: String, kind: String, units: String, focus: String, truncated: Bool, text: String) -> String {
        var p = """
        You are reading a document on behalf of someone who will not read it themselves. \
        Write notes in Markdown that let them act without opening it. Be faithful: never \
        invent, never soften; if something is unclear or unreadable, say so.

        Document: \(document) (\(kind)). Locations are given as [\(units) N].

        Write these sections:
        1. **What this is** — two or three lines: type of document, who it is for, what it decides or proposes.
        2. **Facts that matter** — the decisions, numbers, names, dates, scope and constraints, one per line, \
        each ending with its location in brackets.
        3. **Open questions** — what the document leaves undecided, contradictory, or dependent on someone else.
        4. **Open the original for** — the parts notes cannot replace (tables, diagrams, exact wording), with locations.
        """
        if !focus.isEmpty { p += "\n\nPay particular attention to: \(focus)" }
        if truncated { p += "\n\nNote: the document was cut at \(text.count) characters; say so in section 1 and note what may be missing." }
        p += "\n\n---\n\n\(text)"
        return p
    }

    /// A reading model that answers nothing answers nothing twice. Tell the
    /// caller to stop and read the file directly. Pure — unit-tested.
    static func emptyAnswerGuidance(file: String) -> String {
        """
        The reading model produced no answer for \(file) — most often a reasoning model \
        that spent its whole budget thinking. Do NOT call document_digest again for this \
        file: read it directly instead (pdf_extract_text for a PDF, office_extract_text for \
        Word/PowerPoint/Excel, read_file for text) and carry on. Tell the user their reading \
        model returned nothing, and that Settings ▸ Models ▸ Reading model wants a \
        long-context, non-reasoning model.
        """
    }

    static func reply(notesURL: URL, notes: String, cached: Bool) -> String {
        "Notes \(cached ? "already existed for this file (unchanged since last read)" : "written") at \(notesURL.path)\n\n\(notes)"
    }

    static func write(_ notes: String, to url: URL, source: URL, digest: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "<!-- Notes by the reading model. Source: \(source.path) · content \(digest.prefix(12)) · \(ISO8601DateFormatter().string(from: Date())) -->\n\n"
        try? (header + notes).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Extraction

    struct DocumentText {
        let text: String
        /// "PDF", "Word", "PowerPoint", "Excel", "text"
        let kind: String
        /// The location unit: "page", "slide", "sheet", "line"
        let units: String
    }

    static func extract(_ url: URL, cache: DocumentTextCache) throws -> DocumentText {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw DigestError.unreadable }
            var out = ""
            for i in 0..<doc.pageCount {
                let page = doc.page(at: i)?.string ?? ""
                out += "[page \(i + 1)]\n\(page)\n\n"
            }
            return DocumentText(text: out, kind: "PDF", units: "page")
        case "docx":
            return DocumentText(text: try OfficeExtractTextTool.text(at: url, first: 1, last: nil, cache: cache), kind: "Word", units: "paragraph")
        case "pptx":
            return DocumentText(text: try OfficeExtractTextTool.text(at: url, first: 1, last: nil, cache: cache), kind: "PowerPoint", units: "slide")
        case "xlsx":
            return DocumentText(text: try OfficeExtractTextTool.text(at: url, first: 1, last: nil, cache: cache), kind: "Excel", units: "sheet")
        case "md", "markdown", "txt", "text", "rtf", "csv":
            return DocumentText(text: try String(contentsOf: url, encoding: .utf8), kind: "text", units: "line")
        default:
            throw DigestError.unsupported(url.pathExtension)
        }
    }

    enum DigestError: LocalizedError {
        case unreadable, unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: "the file could not be opened"
            case .unsupported(let ext): "'.\(ext)' is not a document type document_digest reads (PDF, Word, PowerPoint, Excel, Markdown, text)"
            }
        }
    }
}

extension DocumentTextCache {
    /// A short stable hash for cache keys derived from text (a focus string).
    static func shortHash(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }
}
