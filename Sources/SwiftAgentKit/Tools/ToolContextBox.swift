import Foundation

/// A Sendable wrapper for [String: Any] context values.
/// Swift 6 requires Sendable conformance for values crossing actor boundaries,
/// but [String: Any] cannot be Sendable. This wrapper uses @unchecked Sendable
/// because the values are only accessed from the actor's serialized context.
public struct ToolContextBox: @unchecked Sendable {
    public let values: [String: Any]
    public init(values: [String: Any]) {
        self.values = values
    }
}