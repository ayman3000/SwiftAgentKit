import Testing
import Foundation
@testable import SwiftAgentKit

/// The trace exists to answer one question cheaply: is the model crawling a
/// file in small slices? It has to answer that without putting anyone's file
/// names into a log every app on the Mac can read.
struct ToolTraceTests {

    @Test func aTagIsStableForTheSamePath() {
        let a = ToolTrace.tag("/Users/someone/Documents/taxes-2025.pdf")
        #expect(a == ToolTrace.tag("/Users/someone/Documents/taxes-2025.pdf"))
        #expect(a != ToolTrace.tag("/Users/someone/Documents/taxes-2024.pdf"))
        #expect(a.hasPrefix("f#"))
        #expect(a.count == 10)
    }

    /// The whole reason for a digest rather than the path itself.
    @Test func aTagRevealsNothingAboutThePath() {
        let secret = "/Users/someone/Documents/taxes-2025.pdf"
        let tag = ToolTrace.tag(secret)
        #expect(!tag.contains("taxes"))
        #expect(!tag.contains("someone"))
        #expect(!tag.contains("/"))
    }

    /// A crawl is recognisable at a glance: the same tag, small served counts,
    /// marching offsets.
    @Test func aCrawlIsVisibleInTheLines() {
        let tag = ToolTrace.tag("/x/big.log")
        let first = ToolTrace.readLine(tool: "read_file", tag: tag, offset: 0,
                                       requested: 200, served: 4_000, total: 1_000_000, more: true)
        #expect(first.contains("requested=200"))
        #expect(first.contains("served=4000"))
        #expect(first.contains("WIDENED"))
        #expect(first.contains("more"))
    }

    @Test func anHonestReadIsNotMarkedWidened() {
        let line = ToolTrace.readLine(tool: "read_file", tag: "f#00000000", offset: 0,
                                      requested: 40_000, served: 3_000, total: 3_000, more: false)
        #expect(!line.contains("WIDENED"))
        #expect(!line.contains("more"))
        #expect(line.contains("total=3000"))
    }

    @Test func noLimitIsReportedAsTheDefault() {
        let line = ToolTrace.readLine(tool: "read_file", tag: "f#00000000", offset: 0,
                                      requested: nil, served: 900, total: 900, more: false)
        #expect(line.contains("requested=default"))
        #expect(!line.contains("WIDENED"))
    }

    /// An artifact store hands back a slice and a flag, not a size. The trace
    /// says so rather than inventing a total.
    @Test func anUnknownTotalIsNotInvented() {
        let line = ToolTrace.readLine(tool: "artifact_read", tag: "f#00000000", offset: 100,
                                      requested: nil, served: 500, total: nil, more: true)
        #expect(line.contains("total=?"))
        #expect(line.contains("more"))
    }
}
