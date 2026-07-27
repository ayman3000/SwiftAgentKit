//
//  PDFTools.swift
//  SwiftAgentKitTools
//
//  PDF tools backed by Apple's PDFKit. Gated with `#if canImport(PDFKit)` so the
//  package still builds on platforms without it (watchOS/tvOS). Reads are
//  unconfirmed; tools that write new PDFs require approval.
//

#if canImport(PDFKit)
import Foundation
import PDFKit
import SwiftAgentKit

/// Report a PDF's page count and basic metadata. Unconfirmed (read-only).
public struct PDFInfoTool: AgentTool {
    public let name = "pdf_info"
    public let description = "Return a PDF's page count and metadata (title, author, encryption)."
    public let parameters = ToolParameters(
        properties: ["path": ToolParameterProperty(type: "string", description: "Path to the PDF (a leading ~ is expanded).")],
        required: ["path"]
    )

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = parameters["path"] as? String, !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "pdf_info requires a `path`.")
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expandPath(raw))) else {
            return .error(toolCallId: "", toolName: name, message: "Cannot open PDF: \(raw)")
        }
        let attrs = doc.documentAttributes ?? [:]
        let title = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "—"
        let author = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "—"
        let text = """
        Pages: \(doc.pageCount)
        Title: \(title)
        Author: \(author)
        Encrypted: \(doc.isEncrypted), Locked: \(doc.isLocked)
        """
        return .success(toolCallId: "", toolName: name, result: text)
    }
}

/// Extract text from a PDF (optionally a 1-based page range). Unconfirmed.
public struct PDFExtractTextTool: AgentTool {
    public let name = "pdf_extract_text"
    public let description = """
    Extract text from a PDF. Optionally limit to a 1-based page range with \
    `first_page` / `last_page`. Output is bounded; narrow the range for big PDFs.
    """
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "Path to the PDF (a leading ~ is expanded)."),
            "first_page": ToolParameterProperty(type: "integer", description: "First page, 1-based (default 1)."),
            "last_page": ToolParameterProperty(type: "integer", description: "Last page, 1-based (default: last)."),
        ],
        required: ["path"]
    )

    private let maxChars = 40_000

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = parameters["path"] as? String, !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "pdf_extract_text requires a `path`.")
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expandPath(raw))) else {
            return .error(toolCallId: "", toolName: name, message: "Cannot open PDF: \(raw)")
        }
        guard doc.pageCount > 0 else {
            return .success(toolCallId: "", toolName: name, result: "(PDF has no pages)")
        }
        let first = max(1, intValue(parameters["first_page"]) ?? 1)
        let last = min(doc.pageCount, intValue(parameters["last_page"]) ?? doc.pageCount)
        guard first <= last else {
            return .error(toolCallId: "", toolName: name, message: "Invalid page range \(first)–\(last).")
        }

        var out = ""
        for i in (first - 1)..<last {
            if let page = doc.page(at: i), let s = page.string { out += s + "\n" }
            if out.count > maxChars { break }
        }
        if out.count > maxChars {
            out = String(out.prefix(maxChars)) + "\n… [truncated — narrow the page range]"
        }
        return .success(toolCallId: "", toolName: name, result: out.isEmpty ? "(no extractable text)" : out)
    }
}

/// Merge several PDFs into one. Confirmation required — it writes a new file.
public struct PDFMergeTool: AgentTool {
    public let name = "pdf_merge"
    public let description = "Merge several PDFs (in order) into a single new PDF at `output`. Requires approval."
    public let parameters = ToolParameters(
        properties: [
            "inputs": ToolParameterProperty(type: "array", description: "Paths of the PDFs to merge, in order.", itemsType: "string"),
            "output": ToolParameterProperty(type: "string", description: "Path for the merged PDF."),
        ],
        required: ["inputs", "output"]
    )

    public var requiresConfirmation: Bool { true }

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let inputs = stringArray(parameters["inputs"])
        guard !inputs.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "pdf_merge requires `inputs` (a list of PDF paths).")
        }
        guard let outRaw = parameters["output"] as? String, !outRaw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "pdf_merge requires an `output` path.")
        }

        let merged = PDFDocument()
        for raw in inputs {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: expandPath(raw))) else {
                return .error(toolCallId: "", toolName: name, message: "Cannot open PDF: \(raw)")
            }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        let outURL = URL(fileURLWithPath: expandPath(outRaw))
        guard merged.write(to: outURL) else {
            return .error(toolCallId: "", toolName: name, message: "Failed to write merged PDF: \(outRaw)")
        }
        return .success(toolCallId: "", toolName: name, result: "Merged \(inputs.count) PDFs (\(merged.pageCount) pages) → \(outRaw).")
    }
}

/// Split a PDF into one file per page in a directory. Confirmation required.
public struct PDFSplitTool: AgentTool {
    public let name = "pdf_split"
    public let description = "Split a PDF into one file per page, written into `output_directory`. Requires approval."
    public let parameters = ToolParameters(
        properties: [
            "input": ToolParameterProperty(type: "string", description: "Path to the PDF to split."),
            "output_directory": ToolParameterProperty(type: "string", description: "Directory for the per-page PDFs."),
        ],
        required: ["input", "output_directory"]
    )

    public var requiresConfirmation: Bool { true }

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let inRaw = parameters["input"] as? String, !inRaw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "pdf_split requires an `input` path.")
        }
        guard let dirRaw = parameters["output_directory"] as? String, !dirRaw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "pdf_split requires an `output_directory`.")
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expandPath(inRaw))) else {
            return .error(toolCallId: "", toolName: name, message: "Cannot open PDF: \(inRaw)")
        }
        let dir = URL(fileURLWithPath: expandPath(dirRaw))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = URL(fileURLWithPath: expandPath(inRaw)).deletingPathExtension().lastPathComponent
        var written = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let name = String(format: "%@-%03d.pdf", base, i + 1)
            if single.write(to: dir.appendingPathComponent(name)) { written += 1 }
        }
        guard written > 0 else {
            return .error(toolCallId: "", toolName: name, message: "Failed to write any pages from \(inRaw).")
        }
        return .success(toolCallId: "", toolName: name, result: "Split \(inRaw) into \(written) page files in \(dirRaw).")
    }
}
#endif
