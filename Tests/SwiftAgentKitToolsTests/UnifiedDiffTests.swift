import Testing
import Foundation
@testable import SwiftAgentKitTools

struct UnifiedDiffTests {

    private func applied(_ patch: String, to source: String) -> String? {
        guard let hunks = UnifiedDiff.parse(patch) else { return nil }
        if case .success(let out) = UnifiedDiff.apply(hunks, to: source) { return out }
        return nil
    }

    // MARK: - Parse

    @Test func ignoresFileHeadersAndParsesHunk() {
        let patch = """
        diff --git a/f.txt b/f.txt
        index 111..222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        """
        let hunks = UnifiedDiff.parse(patch)
        #expect(hunks?.count == 1)
        #expect(hunks?[0].oldStart == 1)
        #expect(hunks?[0].before == ["a", "b", "c"])
        #expect(hunks?[0].after == ["a", "B", "c"])
    }

    @Test func malformedReturnsNil() {
        #expect(UnifiedDiff.parse("not a diff at all") == nil)
        #expect(UnifiedDiff.parse("") == nil)
    }

    // MARK: - Apply

    @Test func singleHunkReplace() {
        let source = "a\nb\nc\n"
        let patch = "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
        #expect(applied(patch, to: source) == "a\nB\nc\n")
    }

    /// The core reliability guarantee: wrong @@ line numbers still apply because
    /// we match on context, not the header numbers.
    @Test func wrongLineNumbersStillApplyViaContext() {
        let source = "one\ntwo\nthree\nfour\nfive\n"
        // Claims the change is at line 99, but context locates it at "three".
        let patch = "@@ -99,3 +99,3 @@\n two\n-three\n+THREE\n four\n"
        #expect(applied(patch, to: source) == "one\ntwo\nTHREE\nfour\nfive\n")
    }

    @Test func multipleHunksWithOffsetDrift() {
        let source = "1\n2\n3\n4\n5\n6\n"
        // First hunk inserts a line, shifting later line numbers; second still applies.
        let patch = """
        @@ -1,2 +1,3 @@
         1
        +1.5
         2
        @@ -5,2 +5,2 @@
         5
        -6
        +six
        """
        #expect(applied(patch, to: source) == "1\n1.5\n2\n3\n4\n5\nsix\n")
    }

    @Test func contextNotFoundIsHunkNotFoundAndChangesNothing() {
        let source = "a\nb\nc\n"
        let patch = "@@ -1,2 +1,2 @@\n x\n-y\n+Y\n"
        let hunks = UnifiedDiff.parse(patch)!
        let result = UnifiedDiff.apply(hunks, to: source)
        guard case .failure(let err) = result else { Issue.record("expected failure"); return }
        if case .hunkNotFound(let index, _, _) = err { #expect(index == 0) }
        else { Issue.record("expected hunkNotFound, got \(err)") }
    }

    @Test func pureInsertionAtContext() {
        let source = "start\nend\n"
        let patch = "@@ -1,1 +1,2 @@\n start\n+middle\n"
        #expect(applied(patch, to: source) == "start\nmiddle\nend\n")
    }

    @Test func removeOnlyHunk() {
        let source = "keep\ndrop\nkeep2\n"
        let patch = "@@ -1,3 +1,2 @@\n keep\n-drop\n keep2\n"
        #expect(applied(patch, to: source) == "keep\nkeep2\n")
    }

    @Test func preservesNoTrailingNewline() {
        let source = "a\nb"            // no trailing newline
        let patch = "@@ -1,2 +1,2 @@\n a\n-b\n+B\n"
        #expect(applied(patch, to: source) == "a\nB")
    }

    @Test func preservesTrailingNewline() {
        let source = "a\nb\n"
        let patch = "@@ -1,2 +1,2 @@\n a\n-b\n+B\n"
        #expect(applied(patch, to: source) == "a\nB\n")
    }

    @Test func picksOccurrenceNearestHint() {
        // "x" appears twice; hint (line 4) should pick the second one.
        let source = "x\ny\nz\nx\nw\n"
        let patch = "@@ -4,1 +4,1 @@\n-x\n+X\n"
        #expect(applied(patch, to: source) == "x\ny\nz\nX\nw\n")
    }

    // MARK: - Resilience (whitespace drift, fuzz, self-healing errors)

    @Test func trailingWhitespaceDriftStillMatches() {
        // Source lines carry trailing spaces the model's diff doesn't reproduce.
        let source = "func a() {  \n    body\n}\n"
        let patch = "@@ -1,3 +1,3 @@\n func a() {\n-    body\n+    newBody\n }\n"
        #expect(applied(patch, to: source) == "func a() {  \n    newBody\n}\n")
    }

    @Test func fuzzDropsDriftedEdgeContext() {
        // The hunk's first context line drifted (source has "// v2" not "// v1"),
        // but the core (remove + trailing context) matches — GNU-patch-style fuzz
        // should drop the unmatched edge context and still apply.
        let source = "// v2\nlet x = 1\nlet y = 2\n"
        let patch = "@@ -1,3 +1,3 @@\n // v1\n-let x = 1\n+let x = 10\n let y = 2\n"
        #expect(applied(patch, to: source) == "// v2\nlet x = 10\nlet y = 2\n")
    }

    @Test func fuzzNeverDropsRemoveLines() {
        // A hunk whose REMOVED line doesn't match must still fail — fuzz only
        // elides edge context, never the change itself.
        let source = "a\nb\nc\n"
        let patch = "@@ -1,3 +1,3 @@\n a\n-NOPE\n+B\n c\n"
        #expect(applied(patch, to: source) == nil)
    }

    @Test func hunkNotFoundCarriesCurrentFileRegion() {
        // The error should hand back the file's ACTUAL lines near the hint so
        // the model can regenerate an anchored diff instead of guessing again.
        let source = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        let patch = "@@ -10,2 +10,2 @@\n stale-context\n-gone\n+replacement\n"
        let hunks = UnifiedDiff.parse(patch)!
        let result = UnifiedDiff.apply(hunks, to: source)
        guard case .failure(.hunkNotFound(_, _, let nearby)) = result else {
            Issue.record("expected hunkNotFound"); return
        }
        #expect(nearby.contains("line10"))
        #expect(nearby.contains("10 |"))   // numbered, so the model can re-anchor
    }
}
