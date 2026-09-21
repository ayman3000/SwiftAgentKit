import Testing
import Foundation
@testable import SwiftAgentKit

/// A tool call's real cost is the conversation it re-sends, not the characters
/// it returns. These rules stop the model from paying that cost fifty times to
/// read one file.
struct ReadSliceTests {

    @Test func anOrdinaryFileComesBackWholeInOneCall() {
        let s = ReadSlice(totalChars: 3_000, offset: nil, limit: nil)
        #expect(s.start == 0 && s.end == 3_000)
        #expect(s.truncatedNote == nil)
        #expect(s.widenedNote == nil)
    }

    /// The measured failure: a 200-character read of a file that fits in one
    /// call. The whole file is served instead.
    @Test func aTinyLimitOnASmallFileStillReturnsTheWholeFile() {
        let s = ReadSlice(totalChars: 3_000, offset: nil, limit: 200)
        #expect(s.end == 3_000)
        #expect(s.widenedNote != nil, "the model must be told it was widened, and why")
        #expect(s.widenedNote!.contains("15 calls"), "3000 / 200 = 15 — the figure it was ignoring")
    }

    /// On a file too big to serve whole, a tiny limit is still raised to the
    /// floor — one call instead of twenty.
    @Test func aTinyLimitOnALargeFileIsRaisedToTheFloor() {
        let s = ReadSlice(totalChars: 1_000_000, offset: nil, limit: 200)
        #expect(s.end - s.start == ReadSlice.floor)
        #expect(s.truncatedNote!.contains("offset 4000"))
        #expect(s.widenedNote!.contains("5000 calls"))
    }

    /// A caller that asks for a big slice gets exactly what it asked for, and
    /// is not lectured.
    @Test func aGenerousRequestIsHonouredUntouched() {
        let s = ReadSlice(totalChars: 1_000_000, offset: 0, limit: 200_000)
        #expect(s.end == 200_000)
        #expect(s.widenedNote == nil)
        #expect(s.truncatedNote != nil)
    }

    @Test func pagingResumesExactlyWhereItStopped() {
        let first = ReadSlice(totalChars: 120_000, offset: nil, limit: 50_000)
        #expect(first.end == 50_000)
        let second = ReadSlice(totalChars: 120_000, offset: first.end, limit: 50_000)
        #expect(second.start == 50_000 && second.end == 100_000)
        // The tail fits in one ordinary read, so it comes back whole.
        let third = ReadSlice(totalChars: 120_000, offset: second.end, limit: 50_000)
        #expect(third.start == 100_000 && third.end == 120_000)
        #expect(third.truncatedNote == nil)
    }

    @Test func offsetsPastTheEndAreEmptyRatherThanACrash() {
        let s = ReadSlice(totalChars: 500, offset: 9_000, limit: 100)
        #expect(s.start == 500 && s.end == 500)
        #expect(s.truncatedNote == nil)
    }

    @Test func anEmptyFileIsHandled() {
        let s = ReadSlice(totalChars: 0, offset: nil, limit: nil)
        #expect(s.start == 0 && s.end == 0)
        #expect(s.annotate("") == "")
    }

    /// A zero limit must not divide by zero when the note is built.
    @Test func aZeroLimitDoesNotBreakTheAdvice() {
        let s = ReadSlice(totalChars: 1_000_000, offset: 0, limit: 0)
        #expect(s.end - s.start == ReadSlice.floor)
        #expect(s.widenedNote != nil)
    }

    @Test func notesFollowTheContentInAStableOrder() {
        let s = ReadSlice(totalChars: 1_000_000, offset: 0, limit: 10)
        let out = s.annotate("BODY")
        #expect(out.hasPrefix("BODY\n"))
        #expect(out.range(of: "truncated at")!.lowerBound < out.range(of: "Returned")!.lowerBound)
    }
}
