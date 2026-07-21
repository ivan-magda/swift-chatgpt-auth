import Foundation

/// The endpoints and client identity the device flow talks to. The Codex values ship as
/// ``ChatGPTOAuthConfiguration/codex``, and most callers use that default unchanged.
///
/// Configuration exists for the caller who registered their own OpenAI OAuth client or points at a
/// staging issuer; it is not per-request state. Pinning the endpoints to one value up front is
/// deliberate: a subscription access token is only ever sent to a URL derived from `issuer`, so no
/// later input can redirect a bearer at another host.
public struct ChatGPTOAuthConfiguration: Sendable, Equatable {
  /// The authorization server, e.g. `https://auth.openai.com`. Every endpoint below is derived from
  /// it, so a staging host is a one-field change.
  public let issuer: String

  /// The OAuth client the flow authenticates as. The Codex default is OpenAI's own public client
  /// identifier for the device flow, not a secret.
  public let clientID: String

  public init(issuer: String, clientID: String) {
    self.issuer = issuer
    self.clientID = clientID
  }

  /// Where a device authorization is started.
  public var userCodeURL: String {
    "\(issuer)/api/accounts/deviceauth/usercode"
  }

  /// Where the device is polled for approval.
  public var devicePollURL: String {
    "\(issuer)/api/accounts/deviceauth/token"
  }

  /// Where an approved grant and a refresh token are redeemed.
  public var tokenURL: String {
    "\(issuer)/oauth/token"
  }

  /// The page a person opens to approve the device. Show it alongside the user code.
  public var verificationURL: String {
    "\(issuer)/codex/device"
  }

  /// The callback the token exchange must echo. It is never listened on: this flow polls, and the
  /// value exists only because the token endpoint requires the code's original redirect.
  public var redirectURI: String {
    "\(issuer)/deviceauth/callback"
  }

  /// The ChatGPT/Codex device-authorization configuration. The default for every entry point.
  public static let codex = ChatGPTOAuthConfiguration(
    issuer: "https://auth.openai.com",
    clientID: "app_EMoamEEZ73f0CkXaXp7hrann"
  )
}
