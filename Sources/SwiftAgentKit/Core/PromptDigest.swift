//
//  PromptDigest.swift
//  SwiftAgentKit
//
//  A short, stable fingerprint of prompt text. Swift's `hashValue` is seeded
//  per process, so it cannot compare a prompt across a relaunch; FNV-1a 64 is
//  unseeded and cheap.
//

import Foundation

public enum PromptDigest {
    /// FNV-1a, 64-bit, over the UTF-8 bytes.
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// The digest as 16 lowercase hex characters.
    public static func hex(_ text: String) -> String {
        String(format: "%016llx", fnv1a64(text))
    }
}
