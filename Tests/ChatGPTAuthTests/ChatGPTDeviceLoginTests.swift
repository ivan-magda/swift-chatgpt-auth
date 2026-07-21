import Foundation
import Testing

@testable import ChatGPTAuth

@Suite
struct ChatGPTDeviceLoginTests {
  private let wallDate = Date(timeIntervalSince1970: 1_700_000_000)
  private let fixedProfile = UUID(uuidString: "00000000-0000-0000-0000-000000000001")

  private func makeLogin(
    _ replies: [ScriptedHTTPClient.Reply]
  ) -> ChatGPTDeviceLogin<ManualClock> {
    let clock = wallDate
    let profile = fixedProfile ?? UUID()
    let client = ChatGPTOAuthClient(http: ScriptedHTTPClient(replies)) { clock }
    return ChatGPTDeviceLogin(client: client, clock: ManualClock()) { profile }
  }

  @Test
  func aFullLoginProducesAStoredCredential() async throws {
    // given
    let token = makeJWT(payloadJSON: #"{"sub": "user"}"#)
    let login = makeLogin([
      .ok(httpResult(status: 200, json: #"{"device_auth_id": "d", "user_code": "u", "interval": 3}"#)),
      .ok(httpResult(status: 200, json: #"{"authorization_code": "ac", "code_verifier": "cv"}"#)),
      .ok(
        httpResult(
          status: 200,
          json: #"{"access_token": "\#(token)", "refresh_token": "refresh-x", "expires_in": 3600}"#
        )
      )
    ])

    // when
    let credential = try await login.run { _ in }

    // then
    #expect(credential.accessToken == token)
    #expect(credential.refreshToken == "refresh-x")
    #expect(credential.expiresAt == wallDate.addingTimeInterval(3600))
    #expect(credential.profileID == fixedProfile)
  }

  @Test
  func aLoginThatReturnsNoRefreshTokenIsRejected() async throws {
    // given: the exchange omits refresh_token, which a first login cannot store
    let token = makeJWT(payloadJSON: #"{"sub": "user"}"#)
    let login = makeLogin([
      .ok(httpResult(status: 200, json: #"{"device_auth_id": "d", "user_code": "u", "interval": 3}"#)),
      .ok(httpResult(status: 200, json: #"{"authorization_code": "ac", "code_verifier": "cv"}"#)),
      .ok(httpResult(status: 200, json: #"{"access_token": "\#(token)", "expires_in": 3600}"#))
    ])

    // when
    let failure = await captureError(ChatGPTOAuthFailure.self) {
      try await login.run { _ in }
    }

    // then
    guard case .malformedResponse? = failure else {
      Issue.record("expected malformedResponse, got \(String(describing: failure))")
      return
    }
  }
}
