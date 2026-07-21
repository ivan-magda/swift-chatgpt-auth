import Foundation

/// A one-call login: run the device authorization, spend the grant, and hand back a stored
/// credential ready to persist and refresh.
///
/// This is the ergonomic entry point over ``ChatGPTDeviceAuthorization`` and
/// ``ChatGPTOAuthClient/exchange(grant:timeout:)``. A caller that wants to drive the two halves
/// itself can; most only want the credential at the end.
public struct ChatGPTDeviceLogin<ClockType: Clock>: Sendable where ClockType.Duration == Duration {
  private let client: ChatGPTOAuthClient
  private let clock: ClockType
  private let newProfileID: @Sendable () -> UUID

  /// - Parameters:
  ///   - client: the wire client the flow runs on.
  ///   - clock: measures the login window and the poll waits.
  ///   - newProfileID: mints the local identity a fresh credential carries. Defaults to a random
  ///     UUID; injected only so a test can pin it.
  public init(
    client: ChatGPTOAuthClient,
    clock: ClockType,
    newProfileID: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.client = client
    self.clock = clock
    self.newProfileID = newProfileID
  }

  /// Runs the whole login and returns the credential it produced.
  ///
  /// `onDeviceCode` is called once, before polling begins, with the code the person must approve —
  /// show it alongside ``ChatGPTOAuthConfiguration/verificationURL``.
  ///
  /// - Throws: `ChatGPTOAuthFailure` for anything the vendor or transport did, including
  ///   `.deadlineExceeded` when the window closes, or `CancellationError` if the caller walks away.
  public func run(
    onDeviceCode: @escaping @Sendable (ChatGPTDeviceCode) async -> Void
  ) async throws -> ChatGPTCredential {
    let authorization = ChatGPTDeviceAuthorization(client: client, clock: clock)
    let grant = try await authorization.authorize(onDeviceCode: onDeviceCode)
    let pair = try await client.exchange(
      grant: grant,
      timeout: ChatGPTProviderMetadata.requestTimeout
    )

    // A login that returns no refresh token cannot be stored: the credential source would hold a
    // pair it can never renew. A rotation omitting the token means "the one you hold stands", but a
    // first login holds nothing yet, so an absent token here is a malformed response, not a no-op.
    guard let refreshToken = pair.refreshToken else {
      throw ChatGPTOAuthFailure.malformedResponse(
        detail: "the login returned no refresh token to store"
      )
    }

    return ChatGPTCredential(
      profileID: newProfileID(),
      accessToken: pair.accessToken,
      refreshToken: refreshToken,
      expiresAt: pair.expiresAt
    )
  }
}

extension ChatGPTDeviceLogin where ClockType == ContinuousClock {
  /// The everyday login: a continuous clock measures the window, a random UUID names the profile.
  public init(client: ChatGPTOAuthClient) {
    self.init(client: client, clock: ContinuousClock())
  }
}
