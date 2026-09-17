//
//  OfficeTools.swift
//  SwiftAgentKitTools
//
//  Word, PowerPoint and Excel, read without a Python toolchain.
//

#if canImport(AppKit)
import Foundation
import AppKit
import SwiftAgentKit

/// Extract text from a .docx, .pptx or .xlsx.
///
/// Office files are ZIP archives of XML, so all three are readable on the
/// machine with no converter to install: Word through AppKit, which already
/// understands Office Open XML, and the other two by reading the parts that
/// hold the text.
///
/// Labelled the way `pdf_extract_text` labels pages — `[slide N]`,
/// `[sheet "Budget"]` — so the model can cite a location and ask for a
/// narrower range instead of re-reading the file.
public struct OfficeExtractTextTool: AgentTool {
    public let name = "office_extract_text"
    public var isReadOnly: Bool { true }
    public let description = """
    Extract text from a Word (.docx), PowerPoint (.pptx) or Excel (.xlsx) file. \
    Slides and sheets are labelled so you can cite where something came from. \
    Spreadsheets come back as Markdown tables. Output is bounded; for a large \
    file, read it and then narrow with `first` / `last` if you need more.
    """
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "Path to the .docx/.pptx/.xlsx (a leading ~ is expanded)."),
            "first": ToolParameterProperty(type: "integer", description: "First slide/sheet, 1-based (default 1). Ignored for .docx."),
            "last": ToolParameterProperty(type: "integer", description: "Last slide/sheet, 1-based (default: last). Ignored for .docx."),
        ],
        required: ["path"]
    )

    private let maxChars = 40_000

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = parameters["path"] as? String, !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "office_extract_text requires a `path`.")
        }
        let url = URL(fileURLWithPath: expandPath(raw))
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error(toolCallId: "", toolName: name, message: "No such file: \(raw)")
        }
        let first = max(1, intValue(parameters["first"]) ?? 1)
        let last = intValue(parameters["last"])

        do {
            let text: String
            switch url.pathExtension.lowercased() {
            case "docx": text = try Self.wordText(at: url)
            case "pptx": text = try Self.slideText(at: url, first: first, last: last)
            case "xlsx": text = try Self.sheetText(at: url, first: first, last: last)
            default:
                return .error(toolCallId: "", toolName: name,
                              message: "office_extract_text reads .docx, .pptx and .xlsx. For a PDF use pdf_extract_text.")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .success(toolCallId: "", toolName: name, result: "(no extractable text)")
            }
            if text.count > maxChars {
                return .success(toolCallId: "", toolName: name,
                                result: String(text.prefix(maxChars)) + "\n… [truncated — narrow with first/last]")
            }
            return .success(toolCallId: "", toolName: name, result: text)
        } catch {
            return .error(toolCallId: "", toolName: name,
                          message: "Could not read \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: - Word

    /// AppKit already reads Office Open XML, so Word costs no parsing at all.
    static func wordText(at url: URL) throws -> String {
        let attributed = try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil)
        return collapseBlankLines(attributed.string)
    }

    // MARK: - PowerPoint

    /// Slide text lives in `<a:t>` elements, in reading order, one XML part per
    /// slide. Slides are numbered in their filenames, and `slide10` must not
    /// sort before `slide2`, so ordering is numeric rather than lexical.
    static func slideText(at url: URL, first: Int, last: Int?) throws -> String {
        let entries = try ZipArchive.entries(of: url)
        let slides = entries.keys
            .compactMap { name -> (Int, String)? in
                guard let match = try? /^ppt\/slides\/slide(\d+)\.xml$/.wholeMatch(in: name),
                      let number = Int(match.1) else { return nil }
                return (number, name)
            }
            .sorted { $0.0 < $1.0 }
        guard !slides.isEmpty else { return "" }

        let upper = min(last ?? slides.count, slides.count)
        var out = ""
        for (number, part) in slides where number >= first && number <= upper {
            guard let data = try ZipArchive.read(part, from: url, entries: entries) else { continue }
            let body = texts(in: String(decoding: data, as: UTF8.self), tag: "a:t")
                .joined(separator: "\n")
            out += "[slide \(number)]\n" + (body.isEmpty ? "(no text)" : body) + "\n\n"
        }
        return out
    }

    // MARK: - Excel

    /// Cells hold either an inline value or an index into a shared string
    /// table, and a row omits empty cells entirely — so the grid is rebuilt
    /// from each cell's own A1-style reference rather than from its position.
    static func sheetText(at url: URL, first: Int, last: Int?) throws -> String {
        let entries = try ZipArchive.entries(of: url)

        var shared: [String] = []
        if let data = try ZipArchive.read("xl/sharedStrings.xml", from: url, entries: entries) {
            shared = sharedStrings(in: String(decoding: data, as: UTF8.self))
        }
        let names = sheetNames(in: entries, url: url)

        let sheets = entries.keys
            .compactMap { name -> (Int, String)? in
                guard let match = try? /^xl\/worksheets\/sheet(\d+)\.xml$/.wholeMatch(in: name),
                      let number = Int(match.1) else { return nil }
                return (number, name)
            }
            .sorted { $0.0 < $1.0 }
        guard !sheets.isEmpty else { return "" }

        let upper = min(last ?? sheets.count, sheets.count)
        var out = ""
        for (number, part) in sheets where number >= first && number <= upper {
            guard let data = try ZipArchive.read(part, from: url, entries: entries) else { continue }
            let title = names.indices.contains(number - 1) ? names[number - 1] : "Sheet\(number)"
            let rows = grid(in: String(decoding: data, as: UTF8.self), shared: shared)
            out += "[sheet \(number): \"\(title)\"]\n"
            out += rows.isEmpty ? "(empty)\n" : markdownTable(rows)
            out += "\n"
        }
        return out
    }

    /// Sheet titles, in workbook order.
    static func sheetNames(in entries: [String: ZipArchive.Entry], url: URL) -> [String] {
        guard let data = (try? ZipArchive.read("xl/workbook.xml", from: url, entries: entries)) ?? nil
        else { return [] }
        let xml = String(decoding: data, as: UTF8.self)
        // Only <sheet name="…"> carries a title; other name= attributes exist.
        return xml.matches(of: /<sheet name="([^"]*)"/).map { String($0.1) }
    }

    static func sharedStrings(in xml: String) -> [String] {
        // One <si> is one string, but it may be split across several <t> runs.
        return xml.matches(of: /<si[ >](.*?)<\/si>/.dotMatchesNewlines())
            .map { texts(in: String($0.1), tag: "t").joined() }
    }

    /// Cells as [row][column], with gaps filled in.
    static func grid(in xml: String, shared: [String]) -> [[String]] {
        var cells: [Int: [Int: String]] = [:]
        // An empty cell is written self-closing (`<c r="A10" s="1"/>`). Matching
        // only the `>…</c>` form made such a cell swallow the NEXT one, which
        // put its value in the wrong column AND lost its t="s" flag — so shared
        // strings came back as their raw indices.
        let matches = xml.matches(
            of: /<c r="([A-Z]+)(\d+)"([^>]*?)(?:\/>|>(.*?)<\/c>)/.dotMatchesNewlines())
        for m in matches {
            let column = columnIndex(String(m.1))
            guard let row = Int(m.2) else { continue }
            let attributes = String(m.3)
            let body = m.4.map(String.init) ?? ""   // self-closing → no body
            var value = texts(in: body, tag: "v").first ?? texts(in: body, tag: "t").first ?? ""
            if attributes.contains("t=\"s\""), let index = Int(value), shared.indices.contains(index) {
                value = shared[index]
            }
            if !value.isEmpty { cells[row, default: [:]][column] = value }
        }
        guard let lastRow = cells.keys.max(),
              let width = cells.values.compactMap({ $0.keys.max() }).max() else { return [] }
        return (1...lastRow).map { row in
            (0...width).map { cells[row]?[$0] ?? "" }
        }
    }

    /// "A" → 0, "Z" → 25, "AA" → 26.
    static func columnIndex(_ letters: String) -> Int {
        letters.unicodeScalars.reduce(0) { total, scalar in
            total * 26 + Int(scalar.value - 64)
        } - 1
    }

    static func markdownTable(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        var out = "| " + header.map(escapePipes).joined(separator: " | ") + " |\n"
        out += "|" + String(repeating: "---|", count: header.count) + "\n"
        for row in rows.dropFirst() {
            out += "| " + row.map(escapePipes).joined(separator: " | ") + " |\n"
        }
        return out
    }

    private static func escapePipes(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: - XML

    /// The text of every `<tag>…</tag>`, in document order, unescaped.
    ///
    /// A real parser is overkill here: these are machine-written parts with a
    /// known shape, and the tags carry no nested markup of their own.
    static func texts(in xml: String, tag: String) -> [String] {
        var out: [String] = []
        var rest = Substring(xml)
        let close = "</\(tag)>"
        while let open = rest.range(of: "<\(tag)")  {
            guard let headEnd = rest[open.upperBound...].firstIndex(of: ">") else { break }
            // `<a:t/>` — an empty element, no closing tag to look for.
            if rest[rest.index(before: headEnd)] == "/" {
                rest = rest[rest.index(after: headEnd)...]
                continue
            }
            let bodyStart = rest.index(after: headEnd)
            guard let closeRange = rest[bodyStart...].range(of: close) else { break }
            out.append(unescape(String(rest[bodyStart..<closeRange.lowerBound])))
            rest = rest[closeRange.upperBound...]
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Word documents carry long runs of empty paragraphs from page layout;
    /// they are noise in a prompt.
    static func collapseBlankLines(_ s: String) -> String {
        s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
