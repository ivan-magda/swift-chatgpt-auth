import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Attaching

extension ChatGPTAuthorization {
  /// Stamps every credential-dependent header onto the request in place, so the common call site
  /// never writes the header loop by hand.
  ///
  /// Every package-owned header is cleared first, not merely overwritten: a request reused across a
  /// rotation may carry an account header the new token no longer names, and a stale account must
  /// not ride along with a bearer it never belonged to.
  public func apply(to request: inout URLRequest) {
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue(nil, forHTTPHeaderField: ChatGPTProviderMetadata.accountHeaderName)
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
  }
}

extension ChatGPTCredentialSource {
  /// Refresh-if-needed, then attach: one call from a bare `URLRequest` to a request carrying a
  /// live bearer. The returned snapshot is the one the request now wears: its `generation` is what
  /// ``reject(generation:disposition:)`` matches a later 401 against, and its `redactionValues`
  /// are what a diagnostic that echoes the request must scrub. A caller using
  /// ``withAuthorization(_:)`` never touches either.
  @discardableResult
  nonisolated public func authorizeRequest(
    _ request: inout URLRequest
  ) async throws -> ChatGPTAuthorization {
    let authorization = try await authorization()
    authorization.apply(to: &request)
    return authorization
  }
}

// MARK: - The 401 Loop

extension ChatGPTCredentialSource {
  /// Owns the whole authorize-send-retry loop so the caller never meets the rejection protocol:
  /// authorize, send, and on a 401 hand the credential back, refresh, and retry once.
  ///
  /// `send` reports the transport's status code alongside its value so this source, not the call
  /// site, decides what a 401 means. The first is answered with a refresh; a second, spent against
  /// the freshly rotated token, is the server saying the credential itself is finished — the source
  /// latches ``ChatGPTCredentialError/authenticationRequired`` and throws it, and only a new login
  /// repairs it. Any other status is the caller's to interpret: the value is returned as sent.
  ///
  /// A verdict only counts when it lands on the generation still held. A 401 whose token was
  /// rotated away beneath the request — a concurrent caller refreshed while it flew — says nothing
  /// about the pair the source holds now, so it neither latches nor surfaces as terminal; the loop
  /// goes around with the newer credential instead. Each such round requires another caller to have
  /// really rotated, so the loop cannot spin on its own.
  nonisolated public func withAuthorization<Value: Sendable>(
    _ send: @Sendable (ChatGPTAuthorization) async throws -> (value: Value, status: Int)
  ) async throws -> Value {
    var disposition = ChatGPTCredentialRejection.refresh
    while true {
      let authorization = try await authorization()
      let outcome = try await send(authorization)
      guard outcome.status == 401 else {
        return outcome.value
      }

      let applied = await reject(generation: authorization.generation, disposition: disposition)
      guard applied else {
        // Stale: the credential moved beneath this request. The escalation is kept, not reset — a
        // caller that already spent an applied clean 401 has earned its next applied verdict being
        // the terminal one, whichever generation it lands on.
        continue
      }
      guard disposition == .refresh else {
        throw ChatGPTCredentialError.authenticationRequired
      }
      disposition = .authenticationRequired
    }
  }
}
