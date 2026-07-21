import Foundation

/// A stored OAuth pair. `profileID` is a random local UUID minted after a successful login, never
/// vendor-derived: refresh preserves it and re-login mints a new one, which gives a stored pair a
/// stable local provenance across restarts without exposing an account.
public struct ChatGPTCredential: Sendable, Equatable, Codable {
  public let profileID: UUID
  public let accessToken: String
  public let refreshToken: String
  public let expiresAt: Date

  public init(profileID: UUID, accessToken: String, refreshToken: String, expiresAt: Date) {
    self.profileID = profileID
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
}

/// A closed, redaction-safe taxonomy for the token store. It is closed on purpose: a raw crypto,
/// POSIX, or Foundation error carries paths and key material in its description, so none may cross
/// this seam — the store maps whatever it hit to one of these before returning.
public enum ChatGPTTokenStoreError: Error, Sendable, Equatable {
  /// The store could not be reached or opened.
  case unavailable
  /// What was read back is not a credential this can decode.
  case malformedStorage
  /// A write provably did not land. A caller may retry it as though nothing was written.
  case publicationFailed
  /// A write that neither provably landed nor provably did not. Distinct from `publicationFailed`
  /// because a caller must not retry it as though nothing was written.
  case commitUncertain
}

/// Durable storage for the credential. Typed throws keep the closed taxonomy above at the seam
/// rather than trusting every implementation to remember to map its errors. A single credential per
/// store: scope one store to one account.
public protocol ChatGPTTokenStore: Sendable {
  func load() throws(ChatGPTTokenStoreError) -> ChatGPTCredential?
  func save(_ credential: ChatGPTCredential) throws(ChatGPTTokenStoreError)
  func delete() throws(ChatGPTTokenStoreError)
}
