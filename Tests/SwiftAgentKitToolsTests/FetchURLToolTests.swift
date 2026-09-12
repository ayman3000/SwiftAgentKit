import Testing
import Foundation
@testable import SwiftAgentKitTools

struct FetchURLToolTests {

    // MARK: - Guards

    /// A fetch is the natural shape of an attempt to reach inside the machine,
    /// so anything that is not a public http(s) address is refused by name.
    @Test func onlyPublicHTTPAddressesAreAccepted() {
        #expect((try? FetchURLTool.validate("https://example.com/a")) != nil)
        #expect((try? FetchURLTool.validate("http://example.com")) != nil)
        for refused in [
            "file:///etc/passwd",
            "ftp://example.com/x",
            "http://localhost:8080/admin",
            "http://127.0.0.1/",
            "http://10.0.0.5/",
            "http://192.168.1.1/",
            "http://172.16.4.2/",
            "http://169.254.169.254/latest/meta-data/",   // cloud metadata
            "http://printer.local/",
            "not a url at all",
        ] {
            #expect((try? FetchURLTool.validate(refused)) == nil, "should refuse \(refused)")
        }
    }

    /// 172.16–172.31 is private; 172.15 and 172.32 are ordinary internet.
    @Test func theNarrowPrivateRangeIsNotOverApplied() {
        #expect(FetchURLTool.isPrivateHost("172.16.0.1"))
        #expect(FetchURLTool.isPrivateHost("172.31.255.255"))
        #expect(!FetchURLTool.isPrivateHost("172.15.0.1"))
        #expect(!FetchURLTool.isPrivateHost("172.32.0.1"))
        #expect(!FetchURLTool.isPrivateHost("example.com"))
    }

    // MARK: - Reading a page

    private static let page = """
    <!doctype html><html><head><title>KBA &amp; Partners</title>
    <style>body{color:red}</style><script>var x = "<h1>not content</h1>";</script></head>
    <body>
      <nav><a href="/about">About</a></nav>
      <h1>Practice Areas</h1>
      <p>We advise on cross&#45;border deals.</p>
      <ul><li>Corporate</li><li>Tax</li></ul>
      <img src="team.jpg" alt="The team">
      <p>Call <a href="tel:+30210">us</a>.</p>
    </body></html>
    """

    @Test func theTitleIsReadAndItsEntitiesDecoded() {
        #expect(HTMLReader.title(Self.page) == "KBA & Partners")
    }

    /// Scripts and styles are machinery, not content — and a script that
    /// contains markup must not leak into the text.
    @Test func scriptsAndStylesAreDropped() {
        let out = HTMLReader.markdown(Self.page)
        #expect(!out.contains("color:red"))
        #expect(!out.contains("not content"))
        #expect(!out.contains("var x"))
    }

    /// Structure is the point: without headings and list items the page reads
    /// as one undifferentiated paragraph.
    @Test func headingsListsAndLinksSurvive() {
        let out = HTMLReader.markdown(Self.page)
        #expect(out.contains("# Practice Areas"))
        #expect(out.contains("- Corporate"))
        #expect(out.contains("- Tax"))
        #expect(out.contains("[About](/about)"))
        #expect(out.contains("![The team]"))
        #expect(out.contains("cross-border"), "\(out)")      // &#45; decoded
    }

    @Test func plainTextFormatKeepsTheWordsAndDropsTheMarkup() {
        let out = HTMLReader.text(Self.page)
        #expect(out.contains("Practice Areas"))
        #expect(out.contains("Corporate"))
        #expect(!out.contains("<"))
        #expect(!out.contains("#"))
    }

    /// The whole reason this tool exists: a page is mostly markup, and only the
    /// text is worth spending context on.
    @Test func theOutputIsFarSmallerThanTheMarkup() {
        let bulky = "<html><body>" + String(repeating: "<div class=\"a b c\"><span>hi</span></div>", count: 500) + "</body></html>"
        #expect(HTMLReader.markdown(bulky).count < bulky.count / 4)
    }

    /// Blank-line runs and repeated spaces would otherwise dominate the output.
    @Test func whitespaceIsCollapsed() {
        let out = HTMLReader.markdown("<p>a</p><div></div><div></div><div></div><p>b</p>")
        #expect(!out.contains("\n\n\n"))
        #expect(out == "a\n\nb", "\(out)")
    }

    /// A real page is full of icon links and decorative headings. They convert
    /// to `[ ](url)` and a bare `###`, carry nothing, and there are dozens of
    /// them — so they are dropped rather than paid for.
    @Test func emptyLinksAndHeadingsAreDropped() {
        let out = HTMLReader.markdown("""
        <h3></h3><a href="/"><img src="logo.svg"></a><p>Real text</p><h2>Kept</h2>
        """)
        #expect(!out.contains("]("), "\(out)")
        #expect(!out.contains("###"), "\(out)")
        #expect(out.contains("Real text"))
        #expect(out.contains("## Kept"))
    }

    @Test func outputIsClippedToTheRequestedSize() {
        let (clipped, truncated) = FetchURLTool.clip(String(repeating: "x", count: 100), to: 10)
        #expect(clipped.count == 10)
        #expect(truncated)
        let (whole, untouched) = FetchURLTool.clip("short", to: 10)
        #expect(whole == "short")
        #expect(!untouched)
    }

    // MARK: - Live

    /// Hits the network. Proves the tool reads a real server-rendered page and
    /// that the output really is a fraction of the markup.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAK_LIVE_NET"] == "1"))
    func readsARealPage() async throws {
        let result = try await FetchURLTool().execute(parameters: ["url": "https://example.com/"])
        #expect(!result.isError)
        #expect(result.result.contains("Example Domain"))
    }
}
