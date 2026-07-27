//
//  Helpers.swift
//  SwiftAgentKitTools
//
//  Shared parameter-coercion and path helpers for the built-in tools.
//

import Foundation

/// Tool arguments arrive as Int/Double/String depending on JSON decoding.
func intValue(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let d = value as? Double { return Int(d) }
    if let s = value as? String, let i = Int(s) { return i }
    return nil
}

func boolValue(_ value: Any?) -> Bool? {
    if let b = value as? Bool { return b }
    if let i = value as? Int { return i != 0 }
    if let s = value as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
    return nil
}

/// Coerce a JSON array argument into `[String]` (elements may decode as Any).
func stringArray(_ value: Any?) -> [String] {
    if let arr = value as? [String] { return arr }
    if let arr = value as? [Any] { return arr.compactMap { $0 as? String } }
    return []
}

/// Expand a leading `~` and standardize the path.
func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}
