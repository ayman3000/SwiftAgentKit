//
//  FetchURLTool.swift
//  SwiftAgentKitTools
//
//  Read a public web page. The shell can already run curl, but it does it
//  expensively: a typical marketing page is ~100 KB of HTML carrying ~6 KB of
//  text, and all 100 KB would land in the model's context. This strips the page
//  to readable markdown, caps what it returns, and — because it is read-only and
//  unconfirmed — several pages can be fetched in one turn without an approval
//  each.
//
//  It refuses anything that is not a public http(s) address: no file://, no
//  localhost, no private or link-local ranges. "Fetch this URL" is exactly the
//  instruction a hostile page would like to plant, and the loopback interface is
//  where the interesting things listen.
//

import Foundation
import SwiftAgentKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetch a public web page and return it as readable text. Unconfirmed (read-only).
public struct FetchURLTool: AgentTool {
    public let name = "fetch_url"
    public var isReadOnly: Bool { true }
    public let description = """
    Fetch a public http(s) page and return its readable text as markdown \
    (headings, links and lists kept; scripts, styles and navigation chrome \
    dropped). Use `format: "html"` only when you need the raw markup, e.g. to \
    copy a layout. Output is capped — narrow with `max_chars` rather than \
    fetching the same page twice. Pages built entirely by JavaScript return \
    almost nothing here; that is the page, not a failure.
    """
    public let parameters = ToolParameters(
        properties: [
            "url": ToolParameterProperty(type: "string", description: "Absolute http(s) URL."),
            "format": ToolParameterProperty(type: "string", description: #"markdown (default), "text", or "html" for raw markup."#),
            "max_chars": ToolParameterProperty(type: "integer", description: "Cap on returned characters (default 40000)."),
        ],
        required: ["url"]
    )
    public var inputExamples: [String] { [
        #"{"url": "https://example.com/about"}"#,
        #"{"url": "https://example.com/", "format": "html", "max_chars": 120000}"#,
    ] }

    /// Bytes read off the wire before giving up — a cap on the download, not on
    /// the output, so a huge page fails fast instead of filling memory.
    static let maxDownloadBytes = 8 * 1024 * 1024
    static let defaultMaxChars = 40_000

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = (parameters["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "fetch_url requires a `url`.")
        }
        let url: URL
        do { url = try Self.validate(raw) }
        catch { return .error(toolCallId: "", toolName: name, message: (error as? FetchRefusal)?.message ?? "\(error)") }

        let format = (parameters["format"] as? String)?.lowercased() ?? "markdown"
        let maxChars = max(500, (parameters["max_chars"] as? Int) ?? Self.defaultMaxChars)

        var request = URLRequest(url: url, timeoutInterval: 25)
        // Some sites serve a stub or a block page to an unrecognised client.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { return .error(toolCallId: "", toolName: name, message: "Could not reach \(url.absoluteString): \(error.localizedDescription)") }

        let http = response as? HTTPURLResponse
        if let code = http?.statusCode, !(200..<300).contains(code) {
            return .error(toolCallId: "", toolName: name, message: "\(url.absoluteString) returned HTTP \(code).")
        }
        guard data.count <= Self.maxDownloadBytes else {
            return .error(toolCallId: "", toolName: name,
                          message: "\(url.absoluteString) is \(data.count / 1_048_576) MB — too large to read.")
        }
        // The final URL after redirects is what the model should cite.
        let finalURL = response.url ?? url
        guard let body = Self.decode(data, response: http) else {
            return .error(toolCallId: "", toolName: name, message: "\(finalURL.absoluteString) is not text (\(http?.mimeType ?? "unknown type")).")
        }

        let title = HTMLReader.title(body)
        let rendered: String
        switch format {
        case "html": rendered = body
        case "text": rendered = HTMLReader.text(body)
        default: rendered = HTMLReader.markdown(body)
        }
        let (content, truncated) = Self.clip(rendered, to: maxChars)

        var head = "URL: \(finalURL.absoluteString)"
        if let title, !title.isEmpty { head += "\nTitle: \(title)" }
        if finalURL != url { head += "\n(redirected from \(url.absoluteString))" }
        if truncated { head += "\n(truncated at \(maxChars) characters — raise max_chars or fetch a narrower page)" }
        if format != "html", content.trimmingCharacters(in: .whitespacesAndNewlines).count < 200 {
            head += "\n(almost no text: this page is likely built by JavaScript, which this tool does not run)"
        }
        return .success(toolCallId: "", toolName: name, result: head + "\n\n" + content)
    }

    // MARK: - Guards

    struct FetchRefusal: Error { let message: String }

    /// Public http(s) only. Everything else is refused with the reason, because
    /// a fetch is the natural shape of an attempt to reach inside the machine.
    static func validate(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            throw FetchRefusal(message: "Not a valid URL: \(raw)")
        }
        guard scheme == "http" || scheme == "https" else {
            throw FetchRefusal(message: "fetch_url only reads http(s) pages — \(scheme):// is refused. Read local files with the file tools.")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw FetchRefusal(message: "That URL has no host: \(raw)")
        }
        guard !isPrivateHost(host) else {
            throw FetchRefusal(message: "\(host) is on this machine or a private network — fetch_url reads public pages only.")
        }
        return url
    }

    /// Loopback, link-local, and the RFC1918 ranges, plus the names that resolve
    /// to them. Not a complete defence against a hostile DNS answer, but it
    /// stops the ordinary ways a page talks an agent into scanning localhost.
    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return true }
        if host == "[::1]" || host == "::1" || host == "0.0.0.0" { return true }
        // Cloud instance metadata — the classic target.
        if host == "169.254.169.254" || host == "metadata.google.internal" { return true }
        let parts = host.split(separator: ".")
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return false }
        switch a {
        case 10, 127: return true
        case 172: return (16...31).contains(b)
        case 192: return b == 168
        case 169: return b == 254
        default: return false
        }
    }

    /// Honour the charset the server declared; fall back to UTF-8 then Latin-1
    /// so a mislabelled page still reads rather than failing outright.
    static func decode(_ data: Data, response: HTTPURLResponse?) -> String? {
        if let name = response?.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func clip(_ s: String, to maxChars: Int) -> (String, Bool) {
        guard s.count > maxChars else { return (s, false) }
        return (String(s.prefix(maxChars)), true)
    }
}

/// Turns HTML into something worth spending context on. Deliberately a small
/// hand-written reader rather than a dependency: the goal is readable prose and
/// structure, not a conforming parse.
enum HTMLReader {

    static func title(_ html: String) -> String? {
        guard let r = html.range(of: "<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = html[r].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Visible text, all markup gone.
    static func text(_ html: String) -> String {
        squeeze(decodeEntities(stripTags(dropNonContent(html))))
    }

    /// Visible text with the structure that carries meaning: headings, list
    /// items, links, and paragraph breaks.
    static func markdown(_ html: String) -> String {
        var s = dropNonContent(html)

        // Block boundaries become newlines before tags are stripped, so the
        // paragraph structure survives.
        s = replace(s, #"(?i)<br\s*/?>"#, with: "\n")
        s = replace(s, #"(?i)</(p|div|section|article|header|footer|tr|ul|ol|dl|blockquote|pre|table|figure|main|aside|nav)\s*>"#, with: "\n\n")
        s = replace(s, #"(?i)<li[^>]*>"#, with: "\n- ")
        s = replace(s, #"(?i)<t[dh][^>]*>"#, with: " | ")

        for level in 1...6 {
            s = replace(s, "(?i)<h\(level)[^>]*>", with: "\n\n" + String(repeating: "#", count: level) + " ")
            s = replace(s, "(?i)</h\(level)\\s*>", with: "\n\n")
        }

        // Links: keep the text and the destination, drop everything else.
        s = replace(s, #"(?is)<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, with: "[$2]($1)")
        // Images carry meaning only through their alt text.
        s = replace(s, #"(?is)<img\b[^>]*?alt\s*=\s*["']([^"']+)["'][^>]*>"#, with: "![$1]")

        return dropEmptyMarkup(squeeze(decodeEntities(stripTags(s))))
    }

    /// Icon links and decorative headings survive the conversion as `[ ](url)`
    /// and a bare `###`. They carry nothing, and on a real page there are dozens
    /// of them — pure context cost.
    private static func dropEmptyMarkup(_ s: String) -> String {
        var out = replace(s, #"\[\s*\]\([^)]*\)"#, with: "")
        out = replace(out, #"(?m)^#{1,6}\s*$"#, with: "")
        return squeeze(out)
    }

    /// Everything that is markup, machinery, or chrome rather than content.
    private static func dropNonContent(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "canvas", "head"] {
            s = replace(s, "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: " ")
        }
        s = replace(s, "(?s)<!--.*?-->", with: " ")
        return s
    }

    private static func stripTags(_ s: String) -> String {
        replace(s, "(?s)<[^>]+>", with: " ")
    }

    /// Collapse runs of spaces and blank lines; trim each line. Without this a
    /// stripped page is mostly whitespace, which costs context and reads badly.
    private static func squeeze(_ s: String) -> String {
        let lines = replace(s, #"[ \t\u{00A0}]+"#, with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }   // never two blanks in a row
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–",
                     "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”"]
        for (entity, char) in named { out = out.replacingOccurrences(of: entity, with: char) }
        // Numeric entities, decimal and hex.
        out = replaceMatches(out, #"&#(\d+);"#) { Int($0).flatMap(scalar) }
        out = replaceMatches(out, #"&#[xX]([0-9a-fA-F]+);"#) { Int($0, radix: 16).flatMap(scalar) }
        return out
    }

    private static func scalar(_ value: Int) -> String? {
        Unicode.Scalar(value).map { String(Character($0)) }
    }

    private static func replace(_ s: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Regex replace where the replacement is computed from capture group 1.
    private static func replaceMatches(_ s: String, _ pattern: String, _ transform: (String) -> String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: out), let g = Range(m.range(at: 1), in: out),
                  let replacement = transform(String(out[g])) else { continue }
            out.replaceSubrange(whole, with: replacement)
        }
        return out
    }
}
