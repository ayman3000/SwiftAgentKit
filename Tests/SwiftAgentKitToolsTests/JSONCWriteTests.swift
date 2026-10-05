import Foundation
@testable import SwiftAgentKitTools
import Testing

/// Config files that allow comments (tsconfig, VS Code settings, .jsonc) must
/// not be refused as "not valid JSON" — a React run lost four steps to it
/// (Naseem vs Hermes, 2026-10-05). Truly broken files are still refused.
struct JSONCWriteTests {
    let tsconfig = """
    {
      "compilerOptions": {
        /* Bundler mode */
        "target": "ES2022", // modern
        "types": ["vite/client", "vitest/globals"],
        "paths": { "@/*": ["./src/*"] },
      },
      "include": ["src"],
    }
    """

    @Test func aTsconfigWithCommentsAndTrailingCommasIsAccepted() async {
        #expect(await WriteVerifier.rejection(path: "/p/tsconfig.app.json", content: tsconfig) == nil)
        #expect(await WriteVerifier.rejection(path: "/p/jsconfig.json", content: tsconfig) == nil)
        #expect(await WriteVerifier.rejection(path: "/p/.vscode/settings.json", content: tsconfig) == nil)
        #expect(await WriteVerifier.rejection(path: "/p/config.jsonc", content: tsconfig) == nil)
    }

    @Test func aBrokenTsconfigIsStillRefused() async {
        let broken = "{ \"compilerOptions\": { \"target\": \"ES2022\" // no closing braces"
        #expect(await WriteVerifier.rejection(path: "/p/tsconfig.json", content: broken) != nil)
    }

    @Test func packageJsonStaysStrict() async {
        let withComment = "{ // npm cannot read this\n \"name\": \"x\" }"
        #expect(await WriteVerifier.rejection(path: "/p/package.json", content: withComment) != nil)
    }

    @Test func slashesInsideStringsAreNotComments() {
        let text = #"{ "url": "https://example.com/a//b", "glob": "src/**/*.ts" /* c */ }"#
        let stripped = WriteVerifier.strippingJSONComments(text)
        #expect(stripped.contains("https://example.com/a//b"))
        #expect(stripped.contains("src/**/*.ts"))
        #expect(!stripped.contains("/* c */"))
    }

    @Test func commasInsideStringsAreKept() {
        let text = #"{ "note": "a, ]", "list": [1, 2,], }"#
        let stripped = WriteVerifier.strippingJSONComments(text)
        #expect(stripped.contains(#""a, ]""#))
        #expect((try? JSONSerialization.jsonObject(with: Data(stripped.utf8))) != nil)
    }
}
