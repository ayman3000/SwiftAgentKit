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
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(Vision)
import Vision
#endif
import SwiftAgentKit

/// Report a PDF's page count and basic metadata. Unconfirmed (read-only).
public struct PDFInfoTool: AgentTool {
    public let name = "pdf_info"
    public var isReadOnly: Bool { true }
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
///
/// Two things beyond a raw `page.string`:
///
/// 1. **Page markers.** Output is labelled `[page N]` so the model can cite a
///    page and narrow a follow-up range instead of re-reading the whole file.
/// 2. **OCR fallback.** A scanned PDF has no text layer and `page.string`
///    returns nothing. Those pages are rendered and run through Vision, which
///    recognises 30 languages including Arabic. Pages that DO have a text layer
///    are not OCR'd by default — the embedded text is 17x faster and gives the
///    exact characters.
///
///    It is NOT always more accurate, which is worth knowing before trusting
///    it. The text layer is stored in the PDF's own content-stream order, and
///    that order is sometimes wrong: measured on a real guide, the text layer
///    returned `println!("{:?}", instant, readable debugging.\nvalue) for`
///    where OCR of the same page returned the sentence intact. OCR reads the
///    page as rendered, so reading order comes from the visual layout.
///
///    The trade runs both ways: OCR inserts spaces that are not there
///    (`println! (`, `#[derive (Debug) ]`), which is harmless in prose and
///    wrong in code. So `ocr: "force"` is offered as a REPAIR for a document
///    whose text layer comes back scrambled — not as a better default.
///
/// Deliberately NOT done: un-wrapping lines. PDF text runs break mid-sentence
/// ("…a dual-pane mac\nOS file manager…"), and every rule that rejoins them
/// also destroys lists, tables and code. Models read the wrapped form fine, so
/// the text is passed through faithfully; only end-of-line hyphenation, which
/// is unambiguous, is repaired.
public struct PDFExtractTextTool: AgentTool {
    public let name = "pdf_extract_text"
    public var isReadOnly: Bool { true }
    public var description: String {
        let ocrLine = ocrUnavailableNote == nil
            ? "Scanned pages with no text layer are read with OCR. If a page's "
              + "text comes back garbled or out of order, read it again with "
              + "`ocr: force` — that re-reads the page as rendered, which fixes "
              + "reading order (at the cost of stray spaces in code)."
            : "Scanned pages cannot be read: \(ocrUnavailableNote!)"
        return """
        Extract text from a PDF, labelled by page. Optionally limit to a 1-based \
        page range with `first_page` / `last_page`. \(ocrLine) Output is \
        bounded; narrow the range for big PDFs.
        """
    }
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "Path to the PDF (a leading ~ is expanded)."),
            "first_page": ToolParameterProperty(type: "integer", description: "First page, 1-based (default 1)."),
            "last_page": ToolParameterProperty(type: "integer", description: "Last page, 1-based (default: last)."),
            "ocr": ToolParameterProperty(type: "string", description: "OCR policy for pages with no text layer: `auto` (default), `off`, or `force` to OCR every page."),
        ],
        required: ["path"]
    )

    private let maxChars = 40_000
    /// OCR is seconds-per-page. Bound it so a 400-page scan can't stall a turn —
    /// the model can always ask for the next range. Cached pages are free and
    /// do NOT count against this, so a document recognised once can be re-read
    /// whole.
    private let maxOCRPages = 20

    private let cache: PDFOCRCache
    /// When set, OCR never runs and the reason is reported once in the output.
    /// Lets a host turn recognition off — for a plan tier, a policy, or a
    /// machine without Vision — without the tool pretending it read the page.
    private let ocrUnavailableNote: String?

    public init(cache: PDFOCRCache = PDFOCRCache(), ocrUnavailableNote: String? = nil) {
        self.cache = cache
        self.ocrUnavailableNote = ocrUnavailableNote
    }

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
        let policy = OCRPolicy(parameters["ocr"] as? String)

        var out = ""
        /// The page whose text was cut off, so the caller can resume there.
        var truncatedAtPage: Int? = nil
        var ocrUsed = 0
        var ocrBudgetHit = false
        // Computed at most once, and only if a page actually needs OCR —
        // hashing the file is wasted work on a document with a text layer.
        var fileDigest: String? = nil
        var digestComputed = false
        /// Pages with no text layer that could not be OCR'd.
        var unreadablePages: [Int] = []
        /// `force` was asked for on pages that do have text, and OCR is off.
        var ocrRefusedDespiteText = false

        for i in (first - 1)..<last {
            guard let page = doc.page(at: i) else { continue }
            let embedded = Self.normalizePresentationForms(Self.repairHyphenation(page.string ?? ""))
            var text = embedded
            var viaOCR = false

            let hasText = !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let needsOCR = policy.shouldOCR(hasText: hasText)
            if needsOCR, ocrUnavailableNote != nil {
                // `force` asks to OCR pages that already have text. When OCR is
                // unavailable those pages are NOT unreadable — their text layer
                // is returned as usual, and only the re-read was refused.
                if hasText { ocrRefusedDespiteText = true } else { unreadablePages.append(i + 1) }
            } else if needsOCR {
                if !digestComputed {
                    fileDigest = PDFOCRCache.digest(ofFileAt: expandPath(raw))
                    digestComputed = true
                }
                if let fileDigest, let cached = cache.text(digest: fileDigest, page: i + 1) {
                    // A hit costs nothing, so it neither waits nor spends budget.
                    text = cached
                    viaOCR = true
                } else if ocrUsed >= maxOCRPages {
                    ocrBudgetHit = true
                } else if let recognized = Self.ocr(page: page), !recognized.isEmpty {
                    ocrUsed += 1
                    text = recognized
                    viaOCR = true
                    if let fileDigest { cache.store(recognized, digest: fileDigest, page: i + 1) }
                }
            }

            out += viaOCR ? "[page \(i + 1) — OCR]\n" : "[page \(i + 1)]\n"
            out += text.isEmpty ? "(no extractable text)\n" : text + "\n"
            out += "\n"
            if out.count > maxChars { truncatedAtPage = i + 1; break }
        }

        if let page = truncatedAtPage {
            // Name the resume point. "Narrow the range" left the model guessing
            // and it tended to re-read pages it already had.
            out = String(out.prefix(maxChars))
                + "\n… [truncated mid-page \(page) — call again with first_page: \(page) for the rest]"
        }
        if let note = ocrUnavailableNote, !unreadablePages.isEmpty {
            let list = unreadablePages.map(String.init).joined(separator: ", ")
            out += "\n[no text layer on \(unreadablePages.count == 1 ? "page" : "pages") \(list) — "
                + "\(note). Say so rather than guessing at what those pages contain.]"
        }
        if let note = ocrUnavailableNote, ocrRefusedDespiteText {
            out += "\n[re-reading with OCR is unavailable — \(note). "
                + "The text above is the document's own text layer.]"
        }
        if ocrBudgetHit {
            out += "\n[OCR stopped after \(maxOCRPages) new pages — call again for the rest; "
                + "pages already recognised are cached and return immediately]"
        }
        return .success(toolCallId: "", toolName: name, result: out.isEmpty ? "(no extractable text)" : out)
    }

    /// When to OCR a page. `auto` fills in only where the text layer is empty.
    private enum OCRPolicy {
        case auto, off, force
        init(_ raw: String?) {
            switch raw?.lowercased() {
            case "off", "false", "none": self = .off
            case "force", "always", "all": self = .force
            default: self = .auto
            }
        }
        func shouldOCR(hasText: Bool) -> Bool {
            switch self {
            case .off: return false
            case .force: return true
            case .auto: return !hasText
            }
        }
    }

    /// Rejoin a word split by end-of-line hyphenation ("proces-\nsing"). The one
    /// unambiguous wrap repair; everything else is left as the PDF laid it out.
    static func repairHyphenation(_ text: String) -> String {
        text.replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "-\r\n", with: "")
    }

    /// Replace typographic ligatures and Arabic presentation forms with their
    /// ordinary letters: "eﬀect" → "effect", "ﻻ" → "لا".
    ///
    /// PDFs embed these because they are what the font actually draws, but they
    /// are a poor thing to hand a model — they tokenise badly, break search, and
    /// in Arabic the presentation-form blocks are used heavily, so a whole
    /// document can arrive in characters that never appear in typed Arabic.
    ///
    /// Applied per character to the ligature and presentation-form blocks ONLY,
    /// rather than running NFKC over everything: blanket NFKC also rewrites
    /// "x²" to "x2" and "½" to "1⁄2", which loses meaning the document had.
    static func normalizePresentationForms(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { isPresentationForm($0) }) else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if isPresentationForm(scalar) {
                out += String(scalar).precomposedStringWithCompatibilityMapping
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func isPresentationForm(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0xFB00...0xFB06:   // Latin ligatures: ﬀ ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ
            return true
        case 0xFB50...0xFDFF,   // Arabic Presentation Forms-A
             0xFE70...0xFEFF:   // Arabic Presentation Forms-B
            return true
        default:
            return false
        }
    }

    /// Render a page and recognise its text with Vision. Returns nil when Vision
    /// is unavailable, the render fails, or nothing was recognised.
    static func ocr(page: PDFPage) -> String? {
        #if canImport(Vision)
        guard let image = renderForOCR(page: page) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Let Vision pick the script rather than pinning en-US, which is the
        // default and would mangle Arabic, CJK and Cyrillic pages.
        if #available(macOS 13.0, iOS 16.0, *) { request.automaticallyDetectsLanguage = true }
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
        #else
        return nil
        #endif
    }

    /// Rasterise a page for OCR. 3× the PDF's own scale: Vision loses small type
    /// at 1×, and the extra pixels cost far less than a missed line.
    static func renderForOCR(page: PDFPage, scale: CGFloat = 3.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0, width * height < 80_000_000 else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // Scanned pages are often transparent-backed; paint white first or the
        // text is recognised against black and accuracy collapses.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}

/// Render a PDF page to a PNG so a vision model can LOOK at it.
///
/// OCR answers "what words are on this page". This answers "what is this page
/// showing" — a chart's shape, a diagram's arrows, a photo, a stamp. Text
/// extraction is blind to all of it.
///
/// Requires confirmation, unlike every other read here, because it is the one
/// PDF operation that spends the user's money: the image goes to a vision
/// model. Everything else in this file runs locally and free.
public struct PDFPageImageTool: AgentTool {
    public let name = "pdf_page_image"
    public var requiresConfirmation: Bool { true }
    /// And autonomy does not waive it: this is the one PDF operation billed
    /// outside the machine, and there is no undoing a vision-model call.
    public var requiresConfirmationEvenWhenAutonomous: Bool { true }
    public let description = """
    Render one page of a PDF to a PNG image file and return its path, so the \
    page can be LOOKED at rather than read as text — for a chart, diagram, \
    photo, or layout that text extraction cannot convey. Follow it with \
    `view_image` on the returned path to actually see it. Costs the user a \
    vision-model call and asks their permission, so use it only when \
    pdf_extract_text genuinely cannot answer the question — not to double-check \
    text you already have.
    """
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "Path to the PDF (a leading ~ is expanded)."),
            "page": ToolParameterProperty(type: "integer", description: "Page to render, 1-based."),
        ],
        required: ["path", "page"]
    )

    /// 2x the PDF's own scale. The OCR path renders at 3x because Vision loses
    /// small type, but a vision model downscales anyway, so the extra pixels
    /// are billed and then thrown away.
    private let scale: CGFloat = 2.0

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = parameters["path"] as? String, !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "pdf_page_image requires a `path`.")
        }
        guard let requested = intValue(parameters["page"]) else {
            return .error(toolCallId: "", toolName: name, message: "pdf_page_image requires a `page`.")
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expandPath(raw))) else {
            return .error(toolCallId: "", toolName: name, message: "Cannot open PDF: \(raw)")
        }
        guard requested >= 1, requested <= doc.pageCount else {
            return .error(toolCallId: "", toolName: name,
                          message: "Page \(requested) is outside this PDF (1–\(doc.pageCount)).")
        }
        guard let page = doc.page(at: requested - 1),
              let image = PDFExtractTextTool.renderForOCR(page: page, scale: scale)
        else {
            return .error(toolCallId: "", toolName: name, message: "Could not render page \(requested).")
        }
        guard let data = Self.pngData(from: image) else {
            return .error(toolCallId: "", toolName: name, message: "Could not encode page \(requested).")
        }

        let base = URL(fileURLWithPath: expandPath(raw)).deletingPathExtension().lastPathComponent
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)-p\(requested)-\(UUID().uuidString.prefix(8)).png")
        do {
            try data.write(to: out, options: .atomic)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Could not write the page image: \(error.localizedDescription)")
        }
        return .success(toolCallId: "", toolName: name, result: """
        Rendered page \(requested) of \(doc.pageCount) to \(out.path) \
        (\(image.width)x\(image.height)). Call view_image with that path to see it.
        """)
    }

    /// PNG, not JPEG. Counter-intuitive but measured: a page of text is sharp
    /// edges on flat white, which JPEG spends bits fighting — PNG came out
    /// both smaller AND lossless on real pages.
    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
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
