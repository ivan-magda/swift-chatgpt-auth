import Foundation
import Testing

@testable import ChatGPTAuth

private actor DeviceCodeRecorder {
  private var reported: ChatGPTDeviceCode?

  func record(_ device: ChatGPTDeviceCode) {
    reported = device
  }

  func value() -> ChatGPTDeviceCode? {
    reported
  }
}

@Suite
struct ChatGPTDeviceAuthorizationTests {
  private let wallDate = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeAuthorization(
    _ replies: [ScriptedHTTPClient.Reply]
  ) -> ChatGPTDeviceAuthorization<ManualClock> {
    let clock = wallDate
    let client = ChatGPTOAuthClient(http: ScriptedHTTPClient(replies)) { clock }
    return ChatGPTDeviceAuthorization(client: client, clock: ManualClock())
  }

  @Test
  func drivesThePollLoopThroughPendingToAGrant() async throws {
    // given
    let authorization = makeAuthorization([
      .ok(httpResult(status: 200, json: #"{"device_auth_id": "d", "user_code": "u", "interval": 3}"#)),
      .ok(httpResult(status: 403, json: "{}")),
      .ok(httpResult(status: 200, json: #"{"authorization_code": "ac", "code_verifier": "cv"}"#))
    ])
    let recorder = DeviceCodeRecorder()

    // when
    let grant = try await authorization.authorize { device in
      await recorder.record(device)
    }

    // then
    #expect(grant.authorizationCode == "ac")
    #expect(grant.codeVerifier == "cv")
    #expect(await recorder.value()?.userCode == "u")
  }

  @Test
  func endsWithDeadlineExceededOnceTheWindowCloses() async throws {
    // given: a throttle whose delay consumes the entire login window
    let authorization = makeAuthorization([
      .ok(httpResult(status: 200, json: #"{"device_auth_id": "d", "user_code": "u", "interval": 3}"#)),
      .ok(httpResult(status: 429, json: "{}", headers: ["Retry-After": "900"]))
    ])

    // when
    let failure = await #expect(throws: ChatGPTOAuthFailure.self) {
      try await authorization.authorize { _ in }
    }

    // then
    #expect(failure == .deadlineExceeded)
  }
}
