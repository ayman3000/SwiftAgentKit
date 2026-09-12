import Testing
import Foundation
import MCP
@testable import SwiftAgentKitMCP

struct MCPValueConversionTests {

    /// Once a model's arguments have been through JSONSerialization, `true`,
    /// `1` and `0` are all NSNumber, and every one of them satisfies BOTH
    /// `as? Bool` and `as? Int`. Casting in either order is wrong for half the
    /// cases: this is how `pageId: 1` reached a server as `pageId: true` and
    /// was rejected with "Expected number, received boolean" (2026-09-12).
    @Test func theIntegersZeroAndOneAreNotBooleans() throws {
        let json = #"{"pageId": 1, "offset": 0, "headless": true, "verbose": false, "ratio": 0.5, "name": "a"}"#
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]

        #expect(MCPToolBridge.convertAnyToValue(parsed["pageId"]!) == .int(1))
        #expect(MCPToolBridge.convertAnyToValue(parsed["offset"]!) == .int(0))
        #expect(MCPToolBridge.convertAnyToValue(parsed["headless"]!) == .bool(true))
        #expect(MCPToolBridge.convertAnyToValue(parsed["verbose"]!) == .bool(false))
        #expect(MCPToolBridge.convertAnyToValue(parsed["ratio"]!) == .double(0.5))
        #expect(MCPToolBridge.convertAnyToValue(parsed["name"]!) == .string("a"))
    }

    /// Swift-native values (a tool called directly, not via JSON) must convert
    /// the same way.
    @Test func nativeSwiftValuesConvertUnchanged() {
        #expect(MCPToolBridge.convertAnyToValue(1) == .int(1))
        #expect(MCPToolBridge.convertAnyToValue(0) == .int(0))
        #expect(MCPToolBridge.convertAnyToValue(true) == .bool(true))
        #expect(MCPToolBridge.convertAnyToValue(false) == .bool(false))
        #expect(MCPToolBridge.convertAnyToValue(2.5) == .double(2.5))
    }

    /// Nested arguments go through the same path, so the confusion must not
    /// survive one level down either.
    @Test func nestedValuesAreConvertedToo() throws {
        let json = #"{"steps": [1, 0, true], "opts": {"page": 1, "debug": false}}"#
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(MCPToolBridge.convertAnyToValue(parsed["steps"]!) == .array([.int(1), .int(0), .bool(true)]))
        #expect(MCPToolBridge.convertAnyToValue(parsed["opts"]!) == .object(["page": .int(1), "debug": .bool(false)]))
    }
}
