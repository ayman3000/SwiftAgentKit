import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// A provider's own explanation has to survive the trip from the wire to the
/// app. Flattening it into one string — which is what localizedDescription
/// does — leaves an app unable to tell the vendor's sentence from the JSON
/// around it, and a customer reads `{"error":{"code":404,…}}`.
struct ProviderFailureTests {
    private let googles404 = """
    {"error":{"code":404,"message":"This model models/gemini-2.5-pro is no longer \
    available to new users.","status":"NOT_FOUND"}}
    """

    @Test func theVendorsSentenceAndItsBodyStaySeparate() throws {
        let failure = Agent.providerFailure(LLMError.httpError(404, Data(googles404.utf8)))
        guard case .providerRefused(let summary, let details) = failure else {
            Issue.record("expected providerRefused, got \(failure)"); return
        }
        #expect(summary.hasPrefix("This model models/gemini-2.5-pro is no longer available"))
        #expect(!summary.contains("{"), "the envelope leaked into the summary")
        #expect(try #require(details).contains("NOT_FOUND"))
    }

    /// An app that only prints the description must still get the readable
    /// half, not the raw body.
    @Test func theDescriptionIsTheReadableHalf() {
        let failure = Agent.providerFailure(LLMError.httpError(404, Data(googles404.utf8)))
        #expect(!failure.localizedDescription.contains("{"))
        #expect(failure.localizedDescription.contains("no longer available"))
    }

    /// Cancellation is not a provider refusal and must not be reported as one.
    @Test func cancellationStaysCancellation() {
        #expect(Agent.providerFailure(CancellationError()) == .cancelled)
    }

    /// A failure with no body still says something a person can act on.
    @Test func aBodylessFailureStillExplainsItself() {
        let failure = Agent.providerFailure(LLMError.httpError(401, nil))
        guard case .providerRefused(let summary, let details) = failure else {
            Issue.record("expected providerRefused"); return
        }
        #expect(summary.contains("API key"))
        #expect(details == nil)
    }
}
