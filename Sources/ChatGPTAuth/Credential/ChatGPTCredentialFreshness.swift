import Foundation

/// How much life a stored access token has left, judged against a supplied wall date.
///
/// This is the only place the skew window is applied, so a caller reading status and the source that
/// will actually spend the token cannot disagree about whether it is fresh.
public enum ChatGPTCredentialFreshness: Sendable, Equatable {
  /// Usable as it stands.
  case fresh
  /// Still valid, but close enough to lapsing that a request should refresh before spending it.
  case expiring
  /// Past its expiry. A refresh token may still redeem it, so this is not "logged out".
  case expired

  /// Judges against `now` rather than the process clock: each caller supplies its own wall date,
  /// which is what lets one rule serve a live client and a status read alike.
  public static func classify(expiresAt: Date, now: Date) -> ChatGPTCredentialFreshness {
    guard expiresAt > now else {
      return .expired
    }

    let skew = TimeInterval(ChatGPTProviderMetadata.credentialFreshnessSkew.components.seconds)
    return expiresAt > now.addingTimeInterval(skew) ? .fresh : .expiring
  }
}
