import Foundation
import Testing

@testable import ChatGPTAuth

@Suite
struct ChatGPTOAuthConfigurationTests {
  @Test
  func theCodexDefaultCarriesThePinnedIssuerAndClient() {
    // given / when
    let configuration = ChatGPTOAuthConfiguration.codex

    // then
    #expect(configuration.issuer == "https://auth.openai.com")
    #expect(configuration.clientID == "app_EMoamEEZ73f0CkXaXp7hrann")
  }

  @Test
  func endpointsAreDerivedFromTheIssuer() {
    // given
    let configuration = ChatGPTOAuthConfiguration.codex

    // when / then
    #expect(configuration.userCodeURL == "https://auth.openai.com/api/accounts/deviceauth/usercode")
    #expect(configuration.devicePollURL == "https://auth.openai.com/api/accounts/deviceauth/token")
    #expect(configuration.tokenURL == "https://auth.openai.com/oauth/token")
    #expect(configuration.verificationURL == "https://auth.openai.com/codex/device")
    #expect(configuration.redirectURI == "https://auth.openai.com/deviceauth/callback")
  }

  @Test
  func acustomIssuerMovesEveryEndpointWithoutTouchingTheClient() {
    // given
    let configuration = ChatGPTOAuthConfiguration(
      issuer: "https://staging.example.com",
      clientID: "app_custom"
    )

    // when / then
    #expect(configuration.tokenURL == "https://staging.example.com/oauth/token")
    #expect(configuration.userCodeURL == "https://staging.example.com/api/accounts/deviceauth/usercode")
    #expect(configuration.clientID == "app_custom")
  }
}
