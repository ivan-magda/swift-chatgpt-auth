import Foundation
import Testing

@testable import ChatGPTAuth

/// End-to-end checks against the real vendor endpoint. Off by default; opt in with
/// `CHATGPTAUTH_LIVE_TESTS=1 swift test`. Starting a device authorization needs no credentials and
/// nobody has to approve it, so this verifies the live request and response shape without completing
/// a login.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CHATGPTAUTH_LIVE_TESTS"] == "1"))
struct LiveTests {
  @Test
  func startsARealDeviceAuthorization() async throws {
    // given
    let client = ChatGPTOAuthClient(http: URLSessionHTTPClient())

    // when
    let device = try await client.requestDeviceCode(timeout: .seconds(30))

    // then
    #expect(device.deviceAuthID.isEmpty == false)
    #expect(device.userCode.isEmpty == false)
    #expect(device.pollInterval >= ChatGPTProviderMetadata.minimumPollInterval)
  }
}
