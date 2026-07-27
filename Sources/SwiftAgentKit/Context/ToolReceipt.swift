//
//  ToolReceipt.swift
//  SwiftAgentKit
//
//  A compact stand-in for a completed tool exchange. The receipt tells the model
//  what ran and how to retrieve the full output; the raw result no longer sits
//  in active context.
//

import Foundation

public struct ToolReceipt: Sendable, Equatable {
    public let callID: String
    public let toolName: String
    public let isError: Bool
    public let summary: String
    public let artifactIDs: [String]

    public init(callID: String, toolName: String, isError: Bool, summary: String, artifactIDs: [String]) {
        self.callID = callID
        self.toolName = toolName
        self.isError = isError
        self.summary = summary
        self.artifactIDs = artifactIDs
    }

    /// One ledger line, e.g.
    /// `call_1 filesystem_read_file → OK: 812 lines [artifact-abc123]`
    public func ledgerLine() -> String {
        let status = isError ? "ERROR" : "OK"
        let artifacts = artifactIDs.isEmpty ? "" : " [\(artifactIDs.joined(separator: ", "))]"
        return "\(callID) \(toolName) → \(status): \(summary)\(artifacts)"
    }
}
