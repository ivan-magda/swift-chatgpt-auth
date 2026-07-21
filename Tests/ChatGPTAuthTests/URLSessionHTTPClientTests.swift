import Foundation
import Testing

@testable import ChatGPTAuth

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A scripted stub response for the URL protocol below.
struct StubResponse: Sendable {
  let status: Int
  let headers: [String: String]
  let body: Data
}

/// A `URLProtocol` that answers from a per-run handler, so the bundled transport is exercised end to
/// end without touching the network.
class StubURLProtocol: URLProtocol {
  // Set per test; `nonisolated(unsafe)` is sound because the suite below is `.serialized`, so no two
  // tests touch this concurrently.
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubResponse)?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.handler, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let stub = handler(request)
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: stub.status,
        httpVersion: "HTTP/1.1",
        headerFields: stub.headers
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: stub.body)
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
    StubURLProtocol.handler = { _ in
      StubResponse(status: status, headers: headers, body: body)
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
