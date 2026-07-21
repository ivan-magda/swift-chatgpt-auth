import Foundation

// MARK: - Outcomes

/// What a caller is told when the source cannot hand it authorization. Every case is safe to show a
/// person: remote text has already been sanitized and redacted before it reaches a `detail`, and the
/// two waiting cases carry the bound on the wait rather than an open-ended "try later".
public enum ChatGPTCredentialError: Error, Sendable, Equatable {
  /// The stored credential is finished — revoked, spent, or never usable. Only a new login repairs
  /// it, and no amount of waiting will.
  case authenticationRequired
  /// The vendor asked to be left alone. The credential is intact; this is quota, not identity.
  case throttled(retryAfter: Duration)
  /// The refresh did not complete for a reason that may not recur.
  case temporarilyUnavailable(retryAfter: Duration, detail: String)
  /// A rotated pair exists but could not be written, so it is deliberately not being used.
  case persistenceFailed(ChatGPTTokenStoreError)
  case shuttingDown
}

// MARK: - Policy

/// What this source does about a refresh that fails, as opposed to what the vendor's protocol says.
/// None of it is negotiated, and none of it is a value the vendor publishes.
enum ChatGPTRefreshPolicy {
  /// Total attempts one flight may spend on failures that might not recur. Low on purpose: a token
  /// endpoint that is down does not get better for being asked harder, and a flight is holding
  /// every waiter for the whole budget.
  static let attemptBudget = 3

  /// The longest a caller is ever told to wait on this source's own initiative, and the wait it
  /// picks when a throttle names none. It exists so a wave of new requests arriving at an unhealthy
  /// token endpoint cannot become a wave of requests.
  static let maximumCooldown = Duration.seconds(30)

  /// Doubling, and clamped to the same ceiling as a cooldown so no single retry can outlast the
  /// wait a caller would have been given for giving up entirely.
  static func backoff(afterAttempt attempt: Int) -> Duration {
    // The shift is clamped rather than trusted to `attemptBudget`: a shift wide enough to overflow
    // is undefined, and a budget raised in another decade must not turn a wait into a crash. The
    // ceiling below already flattens everything past this point, so the clamp costs no behaviour.
    let doublings = min(attempt - 1, 5)
    return min(.seconds(1 << doublings), maximumCooldown)
  }
}

// MARK: - Validated credential

/// A stored pair that has passed the header-safety gate, and the only shape the source will hold.
///
/// The gate matters most on the load path: bytes read back from the store never met the wire
/// client's checks, and the header builder does not examine what it is handed — an empty access
/// token composes into `Bearer ` and a token carrying a newline folds in a header of the caller's
/// choosing. Making this the only way in means no arrangement of the actor's states can reach the
/// builder with a value nobody looked at.
struct ChatGPTValidatedCredential: Sendable, Equatable {
  let stored: ChatGPTCredential

  var profileID: UUID { stored.profileID }
  var accessToken: String { stored.accessToken }
  var refreshToken: String { stored.refreshToken }
  var expiresAt: Date { stored.expiresAt }

  init?(_ stored: ChatGPTCredential) {
    guard
      Self.isSpendable(stored.accessToken),
      Self.isSpendable(stored.refreshToken)
    else {
      return nil
    }
    self.stored = stored
  }

  /// Rotation in one place, so the three things that must happen together cannot come apart: the
  /// local profile identity survives, an omitted refresh token means the old one still stands rather
  /// than that it was taken away, and the result faces the same gate as anything off the disk.
  init?(rotating previous: ChatGPTValidatedCredential, with pair: ChatGPTTokenPair) {
    self.init(
      ChatGPTCredential(
        profileID: previous.profileID,
        accessToken: pair.accessToken,
        refreshToken: pair.refreshToken ?? previous.refreshToken,
        expiresAt: pair.expiresAt
      )
    )
  }

  private static func isSpendable(_ token: String) -> Bool {
    ChatGPTWireValues.headerSafeToken(
      token,
      maxBytes: ChatGPTProviderMetadata.maximumTokenBytes
    ) != nil
  }
}

// MARK: - Actor State

extension ChatGPTCredentialSource {
  static var initialGeneration: ChatGPTCredentialGeneration {
    ChatGPTCredentialGeneration(value: 1)
  }

  struct TokenPair: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
  }

  struct Flight {
    let id: UInt64
    let baseGeneration: ChatGPTCredentialGeneration
    /// The snapshot the flight spends. Immutable and carried by value, so nothing the actor does
    /// while the flight runs can change what it is redeeming.
    let credential: ChatGPTValidatedCredential
    let task: Task<Void, Never>
  }

  struct Pending {
    let credential: ChatGPTValidatedCredential
    /// The generation this pair replaces once it is durable. Held rather than applied, because the
    /// generation is what tells a caller its headers are real.
    let baseGeneration: ChatGPTCredentialGeneration
  }

  struct Cooling {
    let credential: ChatGPTValidatedCredential
    let generation: ChatGPTCredentialGeneration
    let reason: Reason
    let until: ClockType.Instant

    enum Reason: Sendable, Equatable {
      case throttled
      case unavailable(detail: String)
    }

    func failure(retryAfter: Duration) -> ChatGPTCredentialError {
      switch reason {
      case .throttled:
        .throttled(retryAfter: retryAfter)
      case .unavailable(let detail):
        .temporarilyUnavailable(retryAfter: retryAfter, detail: detail)
      }
    }
  }

  /// What a stopping source is still holding. Admission is already closed; these are the obligations
  /// that outlive it.
  struct Stopping {
    var flight: Flight?
    var pending: Pending?
  }

  enum State {
    case missing
    case ready(
      credential: ChatGPTValidatedCredential,
      generation: ChatGPTCredentialGeneration,
      forceRefresh: Bool
    )
    case refreshing(Flight)
    case pendingPersistence(Pending)
    case cooldown(Cooling)
    case authenticationRequired
    case stopping(Stopping)
  }
}
