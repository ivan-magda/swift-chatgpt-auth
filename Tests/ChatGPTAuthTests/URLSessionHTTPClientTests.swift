import Foundation
import Testing

@testable import ChatGPTAuth

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A `URLProtocol` that answers from a per-run handler, so the bundled transport is exercised end to
/// end without touching the network.
class StubURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let (response, data) = handler(request)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@Suite(.serialized)
struct URLSessionHTTPClientTests {
  private func makeClient() -> URLSessionHTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSessionHTTPClient(session: URLSession(configuration: configuration))
  }

  private func request(successBytes: Int = 1024, errorBytes: Int = 1024) -> HTTPRequest {
    HTTPRequest(
      method: .get,
      url: "https://example.com/thing",
      headers: [:],
      body: nil,
      timeout: .seconds(5),
      responseBodyPolicy: .buffered(successBytes: successBytes, errorBytes: errorBytes)
    )
  }

  private func respond(status: Int, body: Data, headers: [String: String] = [:]) {
    StubURLProtocol.handler = { request in
      let response = HTTPURLResponse(
        url: request.url ?? URL(fileURLWithPath: "/"),
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )
      return (response ?? HTTPURLResponse(), body)
    }
  }

  @Test
  func collectsASuccessBodyAndReadsHeadersCaseInsensitively() async throws {
    // given
    respond(status: 200, body: Data("hello".utf8), headers: ["X-Test": "value"])
    let client = makeClient()

    // when
    let result = try await client.execute(request())

    // then
    #expect(result.statusCode == 200)
    #expect(result.body == Data("hello".utf8))
    #expect(result.getHeader(for: "x-test") == "value")
  }

  @Test
  func failsWhenASuccessBodyOutgrowsItsCap() async throws {
    // given: a 100-byte 2xx body under a 10-byte cap
    respond(status: 200, body: Data(repeating: 0x61, count: 100))
    let client = makeClient()

    // when / then
    await #expect(throws: HTTPTransportFailure.self) {
      try await client.execute(request(successBytes: 10))
    }
  }

  @Test
  func truncatesAnOversizedErrorBodyToItsCap() async throws {
    // given: a 100-byte non-success body under a 5-byte error cap
    respond(status: 500, body: Data(repeating: 0x61, count: 100))
    let client = makeClient()

    // when
    let result = try await client.execute(request(errorBytes: 5))

    // then
    #expect(result.statusCode == 500)
    #expect(result.body.count == 5)
  }
}
