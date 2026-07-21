import Foundation

// MARK: - Requests

/// The HTTP verbs the device flow uses. Deliberately small: authentication is a handful of POSTs and
/// nothing else.
public enum HTTPMethod: String, Sendable, Equatable {
  case get = "GET"
  case post = "POST"
}

/// One outbound request. Every call the flow makes is built from this value, so a custom transport
/// sees exactly what the bundled one does.
public struct HTTPRequest: Sendable {
  public let method: HTTPMethod
  public let url: String
  public let headers: [String: String]
  public let body: Data?
  public let timeout: Duration
  public let responseBodyPolicy: HTTPResponseBodyPolicy

  public init(
    method: HTTPMethod,
    url: String,
    headers: [String: String],
    body: Data?,
    timeout: Duration,
    responseBodyPolicy: HTTPResponseBodyPolicy
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
    self.responseBodyPolicy = responseBodyPolicy
  }
}

// MARK: - Responses

/// A completed response, body already collected.
public struct HTTPResult: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String], body: Data) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  /// Header lookup that ignores case, the way HTTP itself treats field names.
  public func getHeader(for name: String) -> String? {
    headers.caseInsensitiveValue(for: name)
  }
}

/// How much of a response body an executor may hold. The success and error caps part company because
/// they answer different questions: a success body is the payload the flow cannot proceed without,
/// while a non-success body is a diagnostic whose first few kilobytes are the only useful ones.
public enum HTTPResponseBodyPolicy: Sendable, Equatable {
  /// Collect the whole body, capped at `successBytes` for a 2xx and `errorBytes` otherwise. An
  /// over-cap success body fails the request, since a payload handed back short is
  /// indistinguishable from a complete one; an over-cap error body is delivered truncated to the
  /// cap, since the first bytes of a diagnostic are the useful ones.
  case buffered(successBytes: Int, errorBytes: Int)
}

extension HTTPResponseBodyPolicy {
  /// Whether a status code selects the success side of the two-cap contract. The single definition
  /// every executor consults, so a change to the success band cannot leave one executor asserting a
  /// stale one.
  public static func isSuccess(_ statusCode: Int) -> Bool {
    (200..<300).contains(statusCode)
  }
}

// MARK: - Failures

/// Whether a failed attempt could have reached the server. A caller that must not double-spend a
/// request reads this before retrying.
public enum HTTPTransmissionDisposition: Sendable, Equatable {
  /// No byte of the request could have been written.
  case definitelyNotSent
  /// The request may have been written and acted upon.
  case mayHaveBeenSent
}

/// A transport-level failure carrying a message already safe to surface. It never contains the
/// request body, so a token in a form field cannot leak through a connection error.
public struct HTTPTransportFailure: Error, Sendable, Equatable {
  public let disposition: HTTPTransmissionDisposition
  public let safeMessage: String

  public init(disposition: HTTPTransmissionDisposition, safeMessage: String) {
    self.disposition = disposition
    self.safeMessage = safeMessage
  }
}

extension HTTPTransportFailure {
  public static func oversizedBody(cap: Int) -> HTTPTransportFailure {
    HTTPTransportFailure(
      disposition: .mayHaveBeenSent,
      safeMessage: "response body exceeds the \(cap)-byte limit"
    )
  }
}

// MARK: - Executor seam

/// The transport the flow runs on. `URLSessionHTTPClient` is the bundled implementation; a caller
/// with its own networking stack, or a test with scripted responses, conforms its own type instead.
public protocol HTTPExecuting: Sendable {
  /// Sends `request` and collects its whole body under the request's buffered policy.
  ///
  /// - Throws: `HTTPTransportFailure` when the transport fails or a success body outgrows its cap,
  ///   or `CancellationError` when the caller walked away.
  func execute(_ request: HTTPRequest) async throws -> HTTPResult
}

// MARK: - Header Lookup

extension Dictionary where Key == String, Value == String {
  func caseInsensitiveValue(for key: String) -> String? {
    let target = key.lowercased()
    return first { pair in
      pair.key.lowercased() == target
    }?.value
  }
}
