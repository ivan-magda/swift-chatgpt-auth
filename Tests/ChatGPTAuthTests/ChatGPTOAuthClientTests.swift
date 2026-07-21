import Foundation
import Testing

@testable import ChatGPTAuth

@Suite
struct ChatGPTOAuthClientTests {
  private let wallDate = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeClient(_ replies: [ScriptedHTTPClient.Reply]) -> ChatGPTOAuthClient {
    let clock = wallDate
    return ChatGPTOAuthClient(http: ScriptedHTTPClient(replies)) { clock }
  }

  /// Bodies a token endpoint can return with a 200 that still cannot become a usable pair: a
  /// non-object, a missing access token, a rotated refresh token unfit for a header or not a string,
  /// and a token whose only expiry is already past.
  private static let malformedRefreshResponses: [String] = {
    let token = makeJWT(payloadJSON: #"{"sub": "user"}"#)
    let expiredToken = makeJWT(payloadJSON: #"{"exp": 1000000000}"#)
    return [
      "[1, 2, 3]",
      #"{"refresh_token": "r", "expires_in": 3600}"#,
      #"{"access_token": "\#(token)", "refresh_token": "bad token", "expires_in": 3600}"#,
      #"{"access_token": "\#(token)", "refresh_token": 12345, "expires_in": 3600}"#,
      #"{"access_token": "\#(expiredToken)"}"#
    ]
  }()

  // MARK: - Device Code

  @Test
  func requestDeviceCodeParsesTheIdentifierCodeAndInterval() async throws {
    // given
    let client = makeClient([
      .ok(
        httpResult(
          status: 200,
          json: #"{"device_auth_id": "dev-123", "user_code": "ABCD-1234", "interval": 7}"#
        )
      )
    ])

    // when
    let device = try await client.requestDeviceCode(timeout: .seconds(30))

    // then
    #expect(device.deviceAuthID == "dev-123")
    #expect(device.userCode == "ABCD-1234")
    #expect(device.pollInterval == .seconds(7))
  }

  @Test
  func requestDeviceCodeAcceptsTheUserCodeAliasAndFallsBackToADefaultInterval() async throws {
    // given: the vendor's alternate spelling, and no interval to act on
    let client = makeClient([
      .ok(httpResult(status: 200, json: #"{"device_auth_id": "dev-9", "usercode": "WXYZ-0000"}"#))
    ])

    // when
    let device = try await client.requestDeviceCode(timeout: .seconds(30))

    // then
    #expect(device.userCode == "WXYZ-0000")
    #expect(device.pollInterval == ChatGPTProviderMetadata.defaultPollInterval)
  }

  // MARK: - Poll

  @Test
  func aWaitingDeviceReadsAsPendingForBoth403And404() async throws {
    // given
    let device = ChatGPTDeviceCode(deviceAuthID: "d", userCode: "u", pollInterval: .seconds(5))
    let forbidden = makeClient([.ok(httpResult(status: 403, json: "{}"))])
    let notFound = makeClient([.ok(httpResult(status: 404, json: "{}"))])

    // when / then
    #expect(try await forbidden.pollOnce(device: device, timeout: .seconds(30)) == .pending)
    #expect(try await notFound.pollOnce(device: device, timeout: .seconds(30)) == .pending)
  }

  @Test
  func aThrottledPollReportsTheServerNamedDelay() async throws {
    // given
    let device = ChatGPTDeviceCode(deviceAuthID: "d", userCode: "u", pollInterval: .seconds(5))
    let client = makeClient([
      .ok(httpResult(status: 429, json: "{}", headers: ["Retry-After": "12"]))
    ])

    // when
    let result = try await client.pollOnce(device: device, timeout: .seconds(30))

    // then
    #expect(result == .throttled(retryAfter: .seconds(12)))
  }

  @Test
  func anApprovedPollReturnsTheGrant() async throws {
    // given
    let device = ChatGPTDeviceCode(deviceAuthID: "d", userCode: "u", pollInterval: .seconds(5))
    let client = makeClient([
      .ok(
        httpResult(
          status: 200,
          json: #"{"authorization_code": "code-abc", "code_verifier": "verifier-xyz"}"#
        )
      )
    ])

    // when
    let result = try await client.pollOnce(device: device, timeout: .seconds(30))

    // then
    let grant = ChatGPTAuthorizationGrant(authorizationCode: "code-abc", codeVerifier: "verifier-xyz")
    #expect(result == .granted(grant))
  }

  @Test
  func aRejectedPollRedactsTheSubmittedSecretsFromItsDiagnostic() async throws {
    // given: a 400 body that echoes the device-auth id back
    let device = ChatGPTDeviceCode(deviceAuthID: "dev-secret", userCode: "u", pollInterval: .seconds(5))
    let client = makeClient([
      .ok(httpResult(status: 400, json: #"{"error": "bad dev-secret"}"#))
    ])

    // when
    let failure = await captureError(ChatGPTOAuthFailure.self) {
      try await client.pollOnce(device: device, timeout: .seconds(30))
    }

    // then
    guard case .grantRejected(let detail)? = failure else {
      Issue.record("expected grantRejected, got \(String(describing: failure))")
      return
    }
    #expect(detail.contains("dev-secret") == false)
    #expect(detail.contains("[redacted]"))
  }

  // MARK: - Exchange

  @Test
  func exchangeReturnsAPairWhoseExpiryComesFromTheStatedLifetime() async throws {
    // given
    let token = makeJWT(payloadJSON: #"{"sub": "user"}"#)
    let client = makeClient([
      .ok(
        httpResult(
          status: 200,
          json: #"{"access_token": "\#(token)", "refresh_token": "refresh-new", "expires_in": 3600}"#
        )
      )
    ])
    let grant = ChatGPTAuthorizationGrant(authorizationCode: "c", codeVerifier: "v")

    // when
    let pair = try await client.exchange(grant: grant, timeout: .seconds(30))

    // then
    #expect(pair.accessToken == token)
    #expect(pair.refreshToken == "refresh-new")
    #expect(pair.expiresAt == wallDate.addingTimeInterval(3600))
  }

  // MARK: - Refresh

  @Test
  func refreshWithoutARotatedTokenLeavesTheHeldRefreshTokenStanding() async throws {
    // given: a token response that omits refresh_token
    let token = makeJWT(payloadJSON: #"{"sub": "user"}"#)
    let client = makeClient([
      .ok(httpResult(status: 200, json: #"{"access_token": "\#(token)", "expires_in": 1800}"#))
    ])

    // when
    let pair = try await client.refresh(refreshToken: "held", timeout: .seconds(30))

    // then
    #expect(pair.accessToken == token)
    #expect(pair.refreshToken == nil)
  }

  @Test
  func refreshFallsBackToTheTokensOwnExpiryClaimWhenNoLifetimeIsStated() async throws {
    // given: no expires_in, but the JWT carries a future exp
    let token = makeJWT(payloadJSON: #"{"exp": 2000000000}"#)
    let client = makeClient([
      .ok(httpResult(status: 200, json: #"{"access_token": "\#(token)"}"#))
    ])

    // when
    let pair = try await client.refresh(refreshToken: "held", timeout: .seconds(30))

    // then
    #expect(pair.expiresAt == Date(timeIntervalSince1970: 2000000000))
  }

  @Test
  func aServerErrorOnRefreshIsClassifiedAsRetryableTransport() async throws {
    // given
    let client = makeClient([.ok(httpResult(status: 503, json: "service down"))])

    // when
    let failure = await captureError(ChatGPTOAuthFailure.self) {
      try await client.refresh(refreshToken: "held", timeout: .seconds(30))
    }

    // then
    guard case .transport? = failure else {
      Issue.record("expected transport, got \(String(describing: failure))")
      return
    }
  }

  @Test
  func aRefreshTokenThatCannotBeAHeaderIsRejectedBeforeAnyRequest() async throws {
    // given
    let client = makeClient([])

    // when
    let failure = await captureError(ChatGPTOAuthFailure.self) {
      try await client.refresh(refreshToken: "has space", timeout: .seconds(30))
    }

    // then
    guard case .malformedResponse? = failure else {
      Issue.record("expected malformedResponse, got \(String(describing: failure))")
      return
    }
  }

  @Test(arguments: ChatGPTOAuthClientTests.malformedRefreshResponses)
  func aRefreshResponseThatCannotYieldAUsablePairIsMalformed(body: String) async throws {
    // given: a 200 whose body cannot become a spendable, unexpired, header-safe pair
    let client = makeClient([.ok(httpResult(status: 200, json: body))])

    // when
    let failure = await captureError(ChatGPTOAuthFailure.self) {
      try await client.refresh(refreshToken: "held", timeout: .seconds(30))
    }

    // then
    guard case .malformedResponse? = failure else {
      Issue.record("expected malformedResponse for \(body), got \(String(describing: failure))")
      return
    }
  }

  @Test
  func aThrottleOnTheTokenEndpointBecomesAThrottledFailure() async throws {
    // given
    let client = makeClient([
      .ok(httpResult(status: 429, json: "{}", headers: ["Retry-After": "20"]))
    ])

    // when
    let failure = await captureError(ChatGPTOAuthFailure.self) {
      try await client.refresh(refreshToken: "held", timeout: .seconds(30))
    }

    // then
    #expect(failure == .throttled(retryAfter: .seconds(20)))
  }

}
