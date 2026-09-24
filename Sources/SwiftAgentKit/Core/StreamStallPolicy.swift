import Foundation
import LLMProviderKit

/// How long a streamed model call may go without progress before it counts as
/// stalled (see `LLMRequest.stallTimeout`). The host sets the base per model —
/// a cloud model that streams its thinking, a model that thinks silently, a
/// model running on this machine — and the limit grows with the prompt,
/// because reading a large prompt delays the first token.
public struct StreamStallPolicy: Sendable, Equatable {
    public var baseSeconds: TimeInterval

    public init(baseSeconds: TimeInterval) { self.baseSeconds = baseSeconds }

    /// +60 s past ~50K prompt tokens, +120 s past ~100K (Hermes Agent's scaling).
    public func limit(for request: LLMRequest) -> TimeInterval {
        let chars = request.messages.reduce(0) { $0 + $1.content.count }
            + request.tools.reduce(0) { $0 + $1.description.count }
        let tokens = chars / 4
        return baseSeconds + (tokens > 100_000 ? 120 : tokens > 50_000 ? 60 : 0)
    }
}
