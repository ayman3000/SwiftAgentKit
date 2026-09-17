#if canImport(AppKit) && os(macOS)
import Testing
import Foundation
import AppKit
import Compression
@testable import SwiftAgentKitTools

// MARK: - A minimal ZIP writer, so fixtures are built in-process

/// Writes a ZIP with STORED entries. Enough to exercise the reader, and it
/// exercises the stored path too (Office writers use both).
private func makeZip(_ parts: [(String, String)]) -> URL {
    var local = Data(), central = Data()
    func put16(_ d: inout Data, _ v: Int) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
    func put32(_ d: inout Data, _ v: Int) {
        for shift in [0, 8, 16, 24] { d.append(UInt8((v >> shift) & 0xff)) }
    }
    for (name, body) in parts {
        let bytes = Data(body.utf8), nameBytes = Data(name.utf8)
        let offset = local.count
        put32(&local, 0x04034b50); put16(&local, 20); put16(&local, 0); put16(&local, 0)
        put16(&local, 0); put16(&local, 0); put32(&local, 0)
        put32(&local, bytes.count); put32(&local, bytes.count)
        put16(&local, nameBytes.count); put16(&local, 0)
        local.append(nameBytes); local.append(bytes)

        put32(&central, 0x02014b50); put16(&central, 20); put16(&central, 20)
        put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
        put32(&central, 0); put32(&central, bytes.count); put32(&central, bytes.count)
        put16(&central, nameBytes.count); put16(&central, 0); put16(&central, 0)
        put16(&central, 0); put16(&central, 0); put32(&central, 0); put32(&central, offset)
        central.append(nameBytes)
    }
    var out = local
    let centralOffset = out.count
    out.append(central)
    put32(&out, 0x06054b50); put16(&out, 0); put16(&out, 0)
    put16(&out, parts.count); put16(&out, parts.count)
    put32(&out, central.count); put32(&out, centralOffset); put16(&out, 0)

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fixture-\(UUID().uuidString).zip")
    try? out.write(to: url)
    return url
}

private func renamed(_ url: URL, to ext: String) -> URL {
    let dest = url.deletingPathExtension().appendingPathExtension(ext)
    try? FileManager.default.moveItem(at: url, to: dest)
    return dest
}

// MARK: - ZIP

@Suite struct ZipArchiveTests {

    @Test func readsStoredEntries() throws {
        let zip = makeZip([("a/one.xml", "<x>hello</x>"), ("b/two.txt", "second")])
        let entries = try ZipArchive.entries(of: zip)
        #expect(entries.count == 2)
        let one = try #require(try ZipArchive.read("a/one.xml", from: zip, entries: entries))
        #expect(String(decoding: one, as: UTF8.self) == "<x>hello</x>")
        #expect(try ZipArchive.read("missing.xml", from: zip, entries: entries) == nil)
        try? FileManager.default.removeItem(at: zip)
    }

    @Test func inflatesDeflatedData() throws {
        // Round-trip through raw DEFLATE, which is what a ZIP entry holds.
        let original = Data(String(repeating: "compress me ", count: 500).utf8)
        var compressed = Data(count: original.count)
        let written = compressed.withUnsafeMutableBytes { dst in
            original.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, original.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, original.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        #expect(written > 0)
        let inflated = try #require(ZipArchive.inflate(compressed.prefix(written), expected: original.count))
        #expect(inflated == original)
    }

    @Test func refusesSomethingThatIsNotAZip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-\(UUID().uuidString).bin")
        try? Data("not a zip at all".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ZipArchive.entries(of: url) }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Office

@Suite struct OfficeToolsTests {

    private func pptx(slides: [String]) -> URL {
        var parts: [(String, String)] = []
        for (i, body) in slides.enumerated() {
            parts.append(("ppt/slides/slide\(i + 1).xml",
                          "<p:sld><p:cSld>" + body + "</p:cSld></p:sld>"))
        }
        return renamed(makeZip(parts), to: "pptx")
    }

    @Test func readsSlidesInOrderWithMarkers() async throws {
        let file = pptx(slides: [
            "<a:t>First slide</a:t><a:t>subtitle</a:t>",
            "<a:t>Second slide</a:t>",
        ])
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": file.path])
        #expect(out.isError == false)
        #expect(out.result.contains("[slide 1]"))
        #expect(out.result.contains("First slide"))
        #expect(out.result.contains("[slide 2]"))
        let firstAt = try #require(out.result.range(of: "First slide"))
        let secondAt = try #require(out.result.range(of: "Second slide"))
        #expect(firstAt.lowerBound < secondAt.lowerBound)
        try? FileManager.default.removeItem(at: file)
    }

    /// slide10 must not sort before slide2 — the classic lexical-ordering trap.
    @Test func slidesAreOrderedNumericallyNotLexically() async throws {
        var parts: [(String, String)] = []
        for n in 1...11 {
            parts.append(("ppt/slides/slide\(n).xml", "<a:t>MARK\(n)</a:t>"))
        }
        let file = renamed(makeZip(parts), to: "pptx")
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": file.path])
        let two = try #require(out.result.range(of: "[slide 2]"))
        let ten = try #require(out.result.range(of: "[slide 10]"))
        #expect(two.lowerBound < ten.lowerBound)
        try? FileManager.default.removeItem(at: file)
    }

    @Test func slideRangeIsHonoured() async throws {
        let file = pptx(slides: ["<a:t>one</a:t>", "<a:t>two</a:t>", "<a:t>three</a:t>"])
        let out = try await OfficeExtractTextTool().execute(
            parameters: ["path": file.path, "first": 2, "last": 3])
        #expect(!out.result.contains("[slide 1]"))
        #expect(out.result.contains("[slide 2]"))
        #expect(out.result.contains("[slide 3]"))
        try? FileManager.default.removeItem(at: file)
    }

    @Test func arabicSurvivesIntact() async throws {
        let file = pptx(slides: ["<a:t>أساسيات النحو العربي</a:t>"])
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": file.path])
        #expect(out.result.contains("أساسيات النحو العربي"))
        try? FileManager.default.removeItem(at: file)
    }

    @Test func entityEscapesAreDecoded() async throws {
        let file = pptx(slides: ["<a:t>Profit &amp; Loss &lt;2026&gt;</a:t>"])
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": file.path])
        #expect(out.result.contains("Profit & Loss <2026>"))
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Excel

    private func xlsx(_ sheet: String, shared: [String], name: String = "Sheet1") -> URL {
        let ss = "<sst>" + shared.map { "<si><t>\($0)</t></si>" }.joined() + "</sst>"
        let wb = "<workbook><sheets><sheet name=\"\(name)\" sheetId=\"1\"/></sheets></workbook>"
        return renamed(makeZip([
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData>\(sheet)</sheetData></worksheet>"),
            ("xl/sharedStrings.xml", ss),
            ("xl/workbook.xml", wb),
        ]), to: "xlsx")
    }

    @Test func buildsAMarkdownTableWithTheSheetName() async throws {
        let file = xlsx("""
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>120</v></c></row>
        """, shared: ["Region", "Q1", "North"], name: "Sales Q1")
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": file.path])
        #expect(out.result.contains("[sheet 1: \"Sales Q1\"]"))
        #expect(out.result.contains("| Region | Q1 |"))
        #expect(out.result.contains("| North | 120 |"))
        try? FileManager.default.removeItem(at: file)
    }

    /// The regression this was written for: an empty cell is written
    /// self-closing, and matching only `>…</c>` made it swallow the next cell —
    /// shifting the value into the wrong column and losing its t="s", so a
    /// shared string came back as its raw index.
    @Test func aSelfClosingEmptyCellDoesNotSwallowTheNextOne() async throws {
        let file = xlsx("""
        <row r="1"><c r="A1" s="1"/><c r="B1" t="s"><v>0</v></c></row>
        """, shared: ["Dodge"])
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": file.path])
        #expect(out.result.contains("Dodge"))     // resolved, not "0"
        #expect(!out.result.contains("| 0 |"))
        try? FileManager.default.removeItem(at: file)
    }

    /// A row omits empty cells entirely, so position must come from the cell's
    /// own reference — otherwise every later column shifts left.
    @Test func gapsKeepLaterColumnsInPlace() async throws {
        let file = xlsx("""
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>
        """, shared: ["first", "third"])
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": file.path])
        #expect(out.result.contains("| first |  | third |"))
        try? FileManager.default.removeItem(at: file)
    }

    @Test func pipesInCellsDoNotBreakTheTable() async throws {
        let file = xlsx("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row>",
                        shared: ["East|West"])
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": file.path])
        #expect(out.result.contains("East\\|West"))
        try? FileManager.default.removeItem(at: file)
    }

    @Test func columnLettersMapPastZ() {
        #expect(OfficeExtractTextTool.columnIndex("A") == 0)
        #expect(OfficeExtractTextTool.columnIndex("Z") == 25)
        #expect(OfficeExtractTextTool.columnIndex("AA") == 26)
        #expect(OfficeExtractTextTool.columnIndex("AB") == 27)
    }

    // MARK: Word and errors

    @Test func wordIsReadThroughAppKit() async throws {
        // Build a real .docx by round-tripping through AppKit's own writer.
        let text = NSAttributedString(string: "Quarterly review\nSecond paragraph")
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-\(UUID().uuidString).docx")
        try data.write(to: url)

        let out = try await OfficeExtractTextTool().execute(parameters: ["path": url.path])
        #expect(out.isError == false)
        #expect(out.result.contains("Quarterly review"))
        #expect(out.result.contains("Second paragraph"))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func aPDFIsSentToTheRightTool() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("x-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: url)
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": url.path])
        #expect(out.isError)
        #expect(out.result.contains("pdf_extract_text"))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func aMissingFileSaysSo() async throws {
        let out = try await OfficeExtractTextTool().execute(parameters: ["path": "/nope/x.docx"])
        #expect(out.isError)
    }

    @Test func officeReadsAreFreeAndUnconfirmed() {
        #expect(OfficeExtractTextTool().isReadOnly)
        #expect(OfficeExtractTextTool().requiresConfirmation == false)
    }
}
#endif
