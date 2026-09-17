#if canImport(PDFKit) && os(macOS)
import Testing
import Foundation
import PDFKit
import AppKit
import CoreText
@testable import SwiftAgentKitTools

/// Draw `lines` into a real PDF with a text layer, one page.
private func makeTextPDF(_ lines: [String], font: String = "Helvetica") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pdf-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    let ctFont = CTFontCreateWithName(font as CFString, 28, nil)
    for (i, line) in lines.enumerated() {
        let attributed = NSAttributedString(string: line, attributes: [.font: ctFont])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 48, y: 700 - CGFloat(i) * 44)
        CTLineDraw(ctLine, ctx)
    }
    ctx.endPDFPage()
    ctx.closePDF()
    return url
}

/// Rasterise a PDF so it has NO text layer — what a scanner produces.
private func makeScannedPDF(from source: URL) throws -> URL {
    let doc = try #require(PDFDocument(url: source))
    let page = try #require(doc.page(at: 0))
    let cg = try #require(PDFExtractTextTool.renderForOCR(page: page))
    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    let scanned = PDFDocument()
    scanned.insert(try #require(PDFPage(image: image)), at: 0)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scan-\(UUID().uuidString).pdf")
    #expect(scanned.write(to: url))
    return url
}

@Test func pdfExtractLabelsPages() async throws {
    let url = makeTextPDF(["Quarterly revenue report"])
    let out = try await PDFExtractTextTool().execute(parameters: ["path": url.path])
    #expect(out.isError == false)
    #expect(out.result.contains("[page 1]"))
    #expect(out.result.contains("Quarterly revenue report"))
}

@Test func pdfExtractHonoursPageRange() async throws {
    let url = makeTextPDF(["only page"])
    let out = try await PDFExtractTextTool().execute(
        parameters: ["path": url.path, "first_page": 2, "last_page": 9])
    // Range is clamped to the document, so 2…9 on a 1-page PDF is invalid.
    #expect(out.isError == true)
}

/// A PDF big enough to blow the 40k output cap, so truncation is exercised.
private func makeBigPDF(pages: Int) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("big-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    for p in 1...pages {
        ctx.beginPDFPage(nil)
        for row in 0..<55 {
            let text = "Page \(p) line \(row) " + String(repeating: "lorem ipsum dolor ", count: 4)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font]))
            ctx.textPosition = CGPoint(x: 36, y: 750 - CGFloat(row) * 13)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return url
}

@Test func truncationNamesThePageToResumeFrom() async throws {
    let url = makeBigPDF(pages: 40)
    let out = try await PDFExtractTextTool().execute(parameters: ["path": url.path])
    let text = out.result

    // It really did truncate, and it says where to pick up.
    #expect(text.contains("truncated mid-page"))
    let marker = try #require(text.range(of: #"first_page: (\d+)"#, options: .regularExpression))
    let resume = try #require(Int(text[marker].replacingOccurrences(of: "first_page: ", with: "")))
    #expect(resume > 1)

    // The resume call continues the document rather than repeating it.
    let rest = try await PDFExtractTextTool().execute(
        parameters: ["path": url.path, "first_page": resume])
    #expect(rest.result.contains("[page \(resume)]"))

    // No gap: every page from 1 to `resume` appears across the two calls.
    for p in 1..<resume {
        #expect(text.contains("[page \(p)]"), "page \(p) missing from the first call")
    }
    try? FileManager.default.removeItem(at: url)
}

@Test func normalisesLigaturesAndArabicPresentationForms() {
    let f = PDFExtractTextTool.normalizePresentationForms

    // Typographic ligatures a PDF embeds because that is what the font draws.
    #expect(f("e\u{FB00}ect") == "effect")
    #expect(f("\u{FB01}le") == "file")

    // Arabic presentation forms — whole documents arrive in these, and they
    // never appear in typed Arabic, so search and tokenisation both suffer.
    #expect(f("\u{FEFB}") == "لا")           // lam-alef ligature
    #expect(f("\u{FEF3}\u{FE8E}") == "يا")  // medial/final forms

    // Ordinary Arabic is already in its normal form and must not be touched.
    #expect(f("فاتورة العميل") == "فاتورة العميل")

    // Blanket NFKC would rewrite these and lose what the document meant.
    #expect(f("x² area") == "x² area")
    #expect(f("½ cup") == "½ cup")
    #expect(f("plain ascii") == "plain ascii")
}

/// A cache in its own temp directory, so tests never touch the real one.
private func tempCache() -> PDFOCRCache {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ocr-cache-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return PDFOCRCache(directory: dir)
}

@Test func ocrIsCachedAcrossCallsAndIsMuchFasterTheSecondTime() async throws {
    let scanned = try makeScannedPDF(from: makeTextPDF(["Cached invoice 8100"]))
    let tool = PDFExtractTextTool(cache: tempCache())

    let coldStart = Date()
    let cold = try await tool.execute(parameters: ["path": scanned.path])
    let coldMs = Date().timeIntervalSince(coldStart) * 1000
    #expect(cold.result.contains("8100"))

    let warmStart = Date()
    let warm = try await tool.execute(parameters: ["path": scanned.path])
    let warmMs = Date().timeIntervalSince(warmStart) * 1000

    // Same text back...
    #expect(warm.result.contains("8100"))
    #expect(warm.result.contains("[page 1 — OCR]"))
    // ...without paying for recognition again. Recognition is ~700 ms a page,
    // so a real hit is an order of magnitude faster, not a few percent.
    #expect(warmMs < coldMs / 2, "warm \(warmMs) ms was not clearly faster than cold \(coldMs) ms")
}

@Test func cacheIsKeyedByContentNotByPath() async throws {
    let cache = tempCache()
    let original = try makeScannedPDF(from: makeTextPDF(["Portable total 5150"]))
    _ = try await PDFExtractTextTool(cache: cache).execute(parameters: ["path": original.path])

    // The same bytes at a different path — what a second conversation's copy is.
    let copy = FileManager.default.temporaryDirectory
        .appendingPathComponent("copy-\(UUID().uuidString).pdf")
    try FileManager.default.copyItem(at: original, to: copy)

    let start = Date()
    let out = try await PDFExtractTextTool(cache: cache).execute(parameters: ["path": copy.path])
    let ms = Date().timeIntervalSince(start) * 1000
    #expect(out.result.contains("5150"))
    #expect(ms < 400, "a copy of an already-recognised file re-ran OCR (\(ms) ms)")
}

@Test func differentContentIsADifferentCacheEntry() async throws {
    let cache = tempCache()
    let a = try makeScannedPDF(from: makeTextPDF(["First doc 1111"]))
    let b = try makeScannedPDF(from: makeTextPDF(["Second doc 2222"]))
    let tool = PDFExtractTextTool(cache: cache)

    let outA = try await tool.execute(parameters: ["path": a.path])
    let outB = try await tool.execute(parameters: ["path": b.path])
    #expect(outA.result.contains("1111"))
    #expect(outB.result.contains("2222"))
    #expect(!outB.result.contains("1111"))   // no cross-contamination
}

@Test func cacheCanBeDisabled() async throws {
    let scanned = try makeScannedPDF(from: makeTextPDF(["No cache 7000"]))
    let tool = PDFExtractTextTool(cache: PDFOCRCache(directory: nil))
    let out = try await tool.execute(parameters: ["path": scanned.path])
    #expect(out.result.contains("7000"))     // still works, just never stored
}

@Test func digestIsStableAndContentAddressed() throws {
    let a = makeTextPDF(["same bytes"])
    let copy = FileManager.default.temporaryDirectory
        .appendingPathComponent("d-\(UUID().uuidString).pdf")
    try FileManager.default.copyItem(at: a, to: copy)

    let d1 = try #require(PDFOCRCache.digest(ofFileAt: a.path))
    let d2 = try #require(PDFOCRCache.digest(ofFileAt: copy.path))
    #expect(d1 == d2)
    #expect(d1.count == 64)
    #expect(PDFOCRCache.digest(ofFileAt: "/nope/missing.pdf") == nil)
}

@Test func repairsEndOfLineHyphenation() {
    #expect(PDFExtractTextTool.repairHyphenation("proces-\nsing") == "processing")
    // A hyphen NOT at a line end is part of the word and must survive.
    #expect(PDFExtractTextTool.repairHyphenation("dual-pane") == "dual-pane")
}

@Test func ocrReadsAScannedPageWithNoTextLayer() async throws {
    let scanned = try makeScannedPDF(from: makeTextPDF(["Invoice total 4200"]))

    // Precondition: the rasterised PDF really has no text layer.
    let doc = try #require(PDFDocument(url: scanned))
    let embedded = doc.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    #expect(embedded.isEmpty)

    let out = try await PDFExtractTextTool().execute(parameters: ["path": scanned.path])
    #expect(out.result.contains("[page 1 — OCR]"))
    #expect(out.result.contains("Invoice"))
    #expect(out.result.contains("4200"))
}

@Test func ocrOffLeavesAScannedPageEmpty() async throws {
    let scanned = try makeScannedPDF(from: makeTextPDF(["Invoice total 4200"]))
    let out = try await PDFExtractTextTool().execute(
        parameters: ["path": scanned.path, "ocr": "off"])
    #expect(out.result.contains("(no extractable text)"))
    #expect(!out.result.contains("OCR"))
}

@Test func ocrReadsArabic() async throws {
    // Vision advertises ar-SA; this proves the whole path (render → detect
    // script → recognise) works for a right-to-left scan, not just Latin.
    let scanned = try makeScannedPDF(from: makeTextPDF(["فاتورة"], font: "Geeza Pro"))
    let out = try await PDFExtractTextTool().execute(parameters: ["path": scanned.path])
    #expect(out.result.contains("[page 1 — OCR]"))
    #expect(out.result.contains("فاتورة"))
}
#endif
