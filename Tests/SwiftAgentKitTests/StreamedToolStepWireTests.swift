import Foundation
import LLMProviderKit
import LLMProviderKitOllama
import LLMProviderKitOpenAI
@testable import SwiftAgentKit
import Testing

// A streamed tool step must cost ONE model request. For two months every tool
// step on Ollama, OpenAI and OpenRouter cost two: the providers' stream parsers
// didn't deliver whole tool calls, so the agent re-asked the model without
// streaming. Answers stayed correct, so nothing failed — only time and quota
// doubled. The old regression test mocked the stream itself; these drive the
// REAL parsers with real wire bytes, through the real agent loop.

/// Serves canned HTTP bodies in order and counts requests.
private final class WireURLProtocol: URLProtocol {
    nonisolated(unsafe) static var bodies: [String] = []
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let n = Self.requests
        Self.requests += 1
        let body = n < Self.bodies.count ? Self.bodies[n] : ""
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A real provider's request building and parsing on a stubbed session; counts
/// non-streaming complete() calls (the re-ask).
private struct Wire<Inner: LLMProvider>: LLMProvider {
    static var name: String { "wire-" + Inner.name }
    let inner: Inner
    let reasks: CompleteCallCounter
    let urlSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [WireURLProtocol.self]
        return URLSession(configuration: c)
    }()
    var configuration: LLMProviderConfiguration { inner.configuration }
    func prepareRequest(_ r: LLMRequest, stream: Bool) throws -> URLRequest { try inner.prepareRequest(r, stream: stream) }
    func parseStreamLine(_ l: String, request: LLMRequest) throws -> [LLMStreamChunk] { try inner.parseStreamLine(l, request: request) }
    func parseResponse(_ d: Data, request: LLMRequest) throws -> LLMResponse { try inner.parseResponse(d, request: request) }
    func complete(_ r: LLMRequest) async throws -> LLMResponse {
        await reasks.bump()
        return LLMResponse(text: "re-asked", finishReason: .stop, request: r, providerName: Self.name)
    }
}

@Suite(.serialized)
struct StreamedToolStepWireTests {
    private func run<P: LLMProvider>(_ provider: Wire<P>, bodies: [String]) async throws -> (answer: String, requests: Int) {
        WireURLProtocol.bodies = bodies
        WireURLProtocol.requests = 0
        let agent = Agent(config: AgentConfig(provider: provider, model: "m", maxTurns: 4))
        await agent.register(EchoTool())
        var answer = ""
        for try await chunk in agent.runStreaming("echo hi") { answer += chunk }
        return (answer, WireURLProtocol.requests)
    }

    /// Ollama native /api/chat: the call arrives whole in one mid-stream line.
    @Test func ollamaToolStepIsOneRequest() async throws {
        let reasks = CompleteCallCounter()
        let provider = Wire(inner: OllamaProvider(configuration: OllamaProvider.local(model: "m")), reasks: reasks)
        let (answer, requests) = try await run(provider, bodies: [
            #"{"model":"m","message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","function":{"index":0,"name":"echo","arguments":{"message":"hi"}}}]},"done":false}"# + "\n"
            + #"{"model":"m","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":10,"eval_count":5}"# + "\n",
            #"{"model":"m","message":{"role":"assistant","content":"done"},"done":false}"# + "\n"
            + #"{"model":"m","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":12,"eval_count":1}"# + "\n",
        ])
        #expect(answer == "done")
        #expect(requests == 2, "a tool step plus the answer is two requests, not three")
        #expect(await reasks.count == 0, "the tool step must not be re-asked without streaming")
    }

    /// OpenAI / OpenRouter SSE: the call arrives in fragments tagged by index.
    @Test func openAIFragmentedToolStepIsOneRequest() async throws {
        let reasks = CompleteCallCounter()
        let provider = Wire(inner: OpenAIProvider(configuration: OpenAIProvider.openAI(apiKey: "k", model: "m")), reasks: reasks)
        let (answer, requests) = try await run(provider, bodies: [
            [
                #"data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"echo","arguments":""}}]}}]}"#,
                #"data: {"id":"c","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"mess"}}]}}]}"#,
                #"data: {"id":"c","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"age\":\"hi\"}"}}]}}]}"#,
                #"data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
                "data: [DONE]", "",
            ].joined(separator: "\n"),
            [
                #"data: {"id":"d","choices":[{"index":0,"delta":{"content":"done"}}]}"#,
                #"data: {"id":"d","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
                "data: [DONE]", "",
            ].joined(separator: "\n"),
        ])
        #expect(answer == "done")
        #expect(requests == 2, "a tool step plus the answer is two requests, not three")
        #expect(await reasks.count == 0, "the tool step must not be re-asked without streaming")
    }
}
