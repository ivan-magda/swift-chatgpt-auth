import Foundation

/// The non-negotiable operational constants of the device flow, the one place authorization headers
/// are built, and the shared request path. Everything here is fixed behaviour rather than
/// configuration: the vendor publishes no discovery document, so timing, bounds, and header shape
/// are implementation constants a caller does not get to tune. Endpoints and client identity, which
/// a caller may legitimately change, live in ``ChatGPTOAuthConfiguration``.
enum ChatGPTProviderMetadata {
  // MARK: - Identity

  /// The header the unverified account claim is carried in, when a token names one.
  static let accountHeaderName = "ChatGPT-Account-ID"

  // MARK: - Timing

  /// How long a person has to finish approving the device before login gives up.
  static let maximumLoginWait = Duration.seconds(15 * 60)

  /// Used until the vendor names an interval, and the floor every named interval is clamped to — a
  /// server asking to be polled faster than this does not get to.
  static let defaultPollInterval = Duration.seconds(5)
  static let minimumPollInterval = Duration.seconds(1)

  /// How far ahead of a token's stated expiry it stops counting as fresh, absorbing clock drift and
  /// the flight time of the request that will carry it.
  static let credentialFreshnessSkew = Duration.seconds(120)

  /// The ceiling on any single auth request. A login is a conversation of several short calls, and
  /// no one of them has business spending a noticeable slice of the window; what actually protects
  /// that window is the caller's remaining deadline, which cuts this down further.
  static let requestTimeout = Duration.seconds(30)

  /// The delay this flow will actually wait, whatever was asked for. The floor is what stops a poll
  /// loop from becoming a spin, including on a value no current parser can produce.
  static func honoredPollDelay(_ requested: Duration) -> Duration {
    max(requested, minimumPollInterval)
  }

  /// A relative timeout as the whole seconds a transport counts in. Rounded up and floored at one
  /// second: a zero would read as "no timeout at all" to a transport, which is the exact opposite of
  /// what a closing window is asking for. The sub-second overshoot cannot compound, because a caller
  /// with a deadline recomputes what is left before every call.
  static func transportSeconds(_ timeout: Duration) -> Int {
    let parts = timeout.components
    let whole = Int(clamping: parts.seconds)

    guard parts.attoseconds > 0, whole < Int.max else {
      return max(1, whole)
    }

    return max(1, whole + 1)
  }

  // MARK: - Bounds

  /// What a response may cost to read. The two caps part company because they answer different
  /// questions: a success body is the payload the flow cannot proceed without, while a non-success
  /// body is a diagnostic whose first few kilobytes are the only useful ones.
  static let maximumAuthResponseBytes = 256 * 1024
  static let maximumDiagnosticBytes = 8 * 1024

  /// What the vendor's own values may weigh. Each is measured in UTF-8 bytes, generously above any
  /// value the flow is observed to carry, and present so that a hostile or broken response cannot
  /// spend memory or widen what it prints.
  static let maximumUserCodeBytes = 128
  static let maximumDeviceAuthIDBytes = 4 * 1024
  /// The authorization code and the code verifier alike.
  static let maximumGrantValueBytes = 16 * 1024
  static let maximumTokenBytes = 64 * 1024

  // MARK: - Authorization

  /// The sole builder of ChatGPT's credential-dependent headers, and the sole source of the exact
  /// values a diagnostic must scrub. Returning both together is what stops a caller from putting a
  /// token on the wire while forgetting to teach the redactor about it.
  ///
  /// The account claim is unverified metadata, so it is added only when it can safely be a header
  /// value and is otherwise omitted — a token whose account cannot be read is still a token the
  /// server may accept, and composition must not pre-empt that verdict.
  static func authorization(
    accessToken: String,
    generation: ChatGPTCredentialGeneration
  ) -> ChatGPTAuthorization {
    var headers = ["Authorization": "Bearer \(accessToken)"]
    var redactionValues = [accessToken]

    if let accountID = ChatGPTTokenMetadata.extract(accessToken: accessToken).accountID {
      headers[accountHeaderName] = accountID
      redactionValues.append(accountID)
    }

    return ChatGPTAuthorization(
      headers: headers,
      redactionValues: redactionValues,
      generation: generation
    )
  }

  // MARK: - Diagnostics

  /// Sanitizes and redacts vendor-supplied text for display, bounded by the diagnostic cap. The one
  /// wrapper the wire client and any diagnostic path share, so the byte bound they scrub to and the
  /// sanitizer they route through cannot drift between them.
  static func safeDiagnostic(_ raw: String, redacting secrets: [String]) -> String {
    ChatGPTWireValues.safeRemoteDiagnostic(
      raw,
      redacting: secrets,
      maxBytes: maximumDiagnosticBytes
    )
  }

  // MARK: - Transport

  /// Runs one request and turns a transport failure into the caller's own failure type through the
  /// shared diagnostic — one home, so the load-bearing catch order cannot drift between callers.
  ///
  /// Cancellation is rethrown untouched ahead of every catch-all: it is the caller walking away, not
  /// the vendor failing, and reclassifying it would make an abandoned call look retryable.
  static func execute<Failure: Error>(
    _ request: HTTPRequest,
    on http: any HTTPExecuting,
    redacting secrets: [String],
    onTransportFailure asFailure: (String) -> Failure
  ) async throws -> HTTPResult {
    do {
      return try await http.execute(request)
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch let failure as HTTPTransportFailure {
      throw asFailure(safeDiagnostic(failure.safeMessage, redacting: secrets))
    } catch {
      throw asFailure(safeDiagnostic("\(error)", redacting: secrets))
    }
  }
}
