import Testing
import Foundation
@testable import SwiftAgentKitReplay

@Test func canonicalJSONSortsKeysStably() throws {
    let a = try canonicalJSONString(from: Data(#"{"b":1,"a":2}"#.utf8))
    let b = try canonicalJSONString(from: Data(#"{"a":2,"b":1}"#.utf8))
    #expect(a == b)
    #expect(a.contains("\"a\""))
}

@Test func canonicalJSONThrowsOnNonJSON() {
    #expect(throws: (any Error).self) {
        _ = try canonicalJSONString(from: Data("not json".utf8))
    }
}
