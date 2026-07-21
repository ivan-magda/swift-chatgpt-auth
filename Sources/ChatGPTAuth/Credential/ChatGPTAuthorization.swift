import Foundation

/// Identifies the credential snapshot one request authorized with. Rejection is matched against it,
/// so a late failure from an older request cannot invalidate a newer token. It is process-local:
/// nothing about it has to survive a restart.
public struct ChatGPTCredentialGeneration: Sendable, Hashable, Equatable {
  public let value: UInt64

  public init(value: UInt64) {
    self.value = value
  }

  /// The generation of a source that never rotates. A refreshable source starts above this, so a
  /// constant generation can never be mistaken for a snapshot that could go stale.
  public static let zero = ChatGPTCredentialGeneration(value: 0)
}

/// What a source contributes to one request: the credential-dependent headers, the exact secret
/// values a redactor must scrub before anything is logged or shown, and the snapshot they came from.
public struct ChatGPTAuthorization: Sendable, Equatable {
  public let headers: [String: String]
  public let redactionValues: [String]
  public let generation: ChatGPTCredentialGeneration

  public init(
    headers: [String: String],
    redactionValues: [String],
    generation: ChatGPTCredentialGeneration
  ) {
    self.headers = headers
    self.redactionValues = redactionValues
    self.generation = generation
  }
}

/// Why a caller is handing a credential back. `refresh` follows the first clean 401;
/// `authenticationRequired` follows the retry's second and latches a refreshable source terminally,
/// so a later request cannot start another refresh loop.
public enum ChatGPTCredentialRejection: Sendable, Equatable {
  case refresh
  case authenticationRequired
}
