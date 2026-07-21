import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The bundled `HTTPExecuting`: one `URLSession` request per call, the whole body collected, and the
/// buffered two-cap policy enforced. It carries no credential state and keeps no connection of its
/// own beyond the session it is handed, so a caller may share one instance across every flow.
///
/// A request body never appears in a thrown error: a connection failure surfaces the transport's own
/// message, and the higher layers redact known secrets from it before anything is shown.
public struct URLSessionHTTPClient: HTTPExecuting {
  private let session: URLSession

  /// - Parameter session: the session every request runs on. The default shared session is enough
  ///   for most callers; supply your own to pin TLS, a proxy, or a timeout policy.
  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    guard case .buffered(let successBytes, let errorBytes) = request.responseBodyPolicy else {
      throw HTTPTransportFailure(
        disposition: .definitelyNotSent,
        safeMessage: "URLSessionHTTPClient requires a buffered response body policy"
      )
    }

    let urlRequest = try Self.urlRequest(from: request)
    let (data, response) = try await fetch(urlRequest)

    guard let http = response as? HTTPURLResponse else {
      throw HTTPTransportFailure(
        disposition: .mayHaveBeenSent,
        safeMessage: "the response was not an HTTP response"
      )
    }

    return try Self.result(
      statusCode: http.statusCode,
      headers: Self.headers(from: http),
      body: data,
      successBytes: successBytes,
      errorBytes: errorBytes
    )
  }
}

// MARK: - Fetch

extension URLSessionHTTPClient {
  /// Runs the request, mapping a cancellation back to `CancellationError` so the layers above read a
  /// caller walking away as exactly that rather than as a transport fault worth retrying.
  fileprivate func fetch(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
    do {
      return try await session.data(for: urlRequest)
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch let urlError as URLError {
      if urlError.code == .cancelled {
        throw CancellationError()
      }
      throw Self.transportFailure(from: urlError)
    }
  }
}

// MARK: - Request Building

extension URLSessionHTTPClient {
  fileprivate static func urlRequest(from request: HTTPRequest) throws -> URLRequest {
    guard let url = URL(string: request.url) else {
      throw HTTPTransportFailure(
        disposition: .definitelyNotSent,
        safeMessage: "the request URL was not valid"
      )
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = timeoutInterval(request.timeout)
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    return urlRequest
  }

  /// A `Duration` as the seconds `URLRequest` counts in, floored at one: a zero would read as "use
  /// the session default" to the transport, which is the opposite of what a bounded call asks for.
  fileprivate static func timeoutInterval(_ timeout: Duration) -> TimeInterval {
    let parts = timeout.components
    let seconds = TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    return max(1, seconds)
  }
}

// MARK: - Response Handling

extension URLSessionHTTPClient {
  fileprivate static func result(
    statusCode: Int,
    headers: [String: String],
    body: Data,
    successBytes: Int,
    errorBytes: Int
  ) throws -> HTTPResult {
    guard HTTPResponseBodyPolicy.isSuccess(statusCode) else {
      let bounded = body.count > errorBytes ? Data(body.prefix(errorBytes)) : body
      return HTTPResult(statusCode: statusCode, headers: headers, body: bounded)
    }

    guard body.count <= successBytes else {
      throw HTTPTransportFailure.oversizedBody(cap: successBytes)
    }

    return HTTPResult(statusCode: statusCode, headers: headers, body: body)
  }

  fileprivate static func headers(from response: HTTPURLResponse) -> [String: String] {
    var headers: [String: String] = [:]

    for (name, value) in response.allHeaderFields {
      guard let name = name as? String, let value = value as? String else {
        continue
      }
      headers[name] = value
    }

    return headers
  }

  /// A URL loading error as a safe, bounded transport failure. The disposition is read from the code
  /// so a caller that must not double-spend a request can tell a refused connection from one that may
  /// have been written.
  fileprivate static func transportFailure(from error: URLError) -> HTTPTransportFailure {
    let notSent: Set<URLError.Code> = [
      .notConnectedToInternet,
      .cannotFindHost,
      .cannotConnectToHost,
      .dnsLookupFailed
    ]

    let disposition: HTTPTransmissionDisposition =
      notSent.contains(error.code) ? .definitelyNotSent : .mayHaveBeenSent

    return HTTPTransportFailure(disposition: disposition, safeMessage: error.localizedDescription)
  }
}
