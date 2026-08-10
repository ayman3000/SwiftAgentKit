import Foundation
import Testing
import LLMProviderKit

public var shouldUpdateSnapshots: Bool {
    ProcessInfo.processInfo.environment["SAK_UPDATE_SNAPSHOTS"] == "1"
}

public enum WireSnapshotError: Error, CustomStringConvertible {
    case noBody
    case mismatch(golden: String, actual: String)

    public var description: String {
        switch self {
        case .noBody: return "prepareRequest produced no httpBody to snapshot."
        case .mismatch(let golden, let actual):
            return "Wire snapshot mismatch.\n--- golden ---\n\(golden)\n--- actual ---\n\(actual)\n(Set SAK_UPDATE_SNAPSHOTS=1 to accept the new output.)"
        }
    }
}

/// Re-serialize a JSON body with sorted keys + pretty printing so goldens diff
/// stably regardless of the provider's key ordering.
public func canonicalJSONString(from body: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
}

/// Run a real provider's `prepareRequest` on `request`, canonicalize the request
/// BODY (never URL/headers, so no API key leaks), and compare to the golden file.
/// Only the httpBody is snapshotted.
public func assertWireSnapshot(
    _ request: LLMRequest,
    provider: any LLMProvider,
    goldenPath: URL,
    update: Bool = shouldUpdateSnapshots,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let urlRequest = try provider.prepareRequest(request, stream: false)
    guard let body = urlRequest.httpBody else { throw WireSnapshotError.noBody }
    let actual = try canonicalJSONString(from: body)

    let exists = FileManager.default.fileExists(atPath: goldenPath.path)
    if update || !exists {
        try FileManager.default.createDirectory(
            at: goldenPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(actual.utf8).write(to: goldenPath)
        Issue.record(
            "Wrote wire golden \(goldenPath.lastPathComponent). Re-run without SAK_UPDATE_SNAPSHOTS to verify.",
            sourceLocation: sourceLocation)
        return
    }

    let golden = String(decoding: try Data(contentsOf: goldenPath), as: UTF8.self)
    if golden != actual {
        throw WireSnapshotError.mismatch(golden: golden, actual: actual)
    }
}
