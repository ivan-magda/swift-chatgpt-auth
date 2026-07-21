import Foundation

@testable import ChatGPTAuth

// MARK: - HTTP Doubles

/// Builds a buffered HTTP result from a JSON string body.
func httpResult(status: Int, json: String, headers: [String: String] = [:]) -> HTTPResult {
  HTTPResult(statusCode: status, headers: headers, body: Data(json.utf8))
}

/// A transport that replies from a fixed script, in call order, and records every request it saw.
/// An actor so the credential source's concurrent callers can share one safely.
actor ScriptedHTTPClient: HTTPExecuting {
  enum Reply: Sendable {
    case ok(HTTPResult)
    case transportFailure(HTTPTransportFailure)
    case cancelled
  }

  private var replies: [Reply]
  private var index = 0
  private var seen: [HTTPRequest] = []

  init(_ replies: [Reply]) {
    self.replies = replies
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    seen.append(request)
    guard index < replies.count else {
      throw HTTPTransportFailure(disposition: .mayHaveBeenSent, safeMessage: "no scripted reply")
    }
    let reply = replies[index]
    index += 1
    switch reply {
    case .ok(let result):
      return result
    case .transportFailure(let failure):
      throw failure
    case .cancelled:
      throw CancellationError()
    }
  }

  func requests() -> [HTTPRequest] {
    seen
  }

  func requestCount() -> Int {
    seen.count
  }
}

// MARK: - Manual Clock

/// A point on the manual clock, measured as a duration from an arbitrary origin.
struct ManualInstant: InstantProtocol {
  var offset: Duration

  func advanced(by duration: Duration) -> ManualInstant {
    ManualInstant(offset: offset + duration)
  }

  func duration(to other: ManualInstant) -> Duration {
    other.offset - offset
  }

  static func < (lhs: ManualInstant, rhs: ManualInstant) -> Bool {
    lhs.offset < rhs.offset
  }
}

/// A clock the test drives. `sleep` advances the clock to the deadline rather than waiting, so a
/// poll loop over a fifteen-minute window runs in an instant while still honoring every deadline.
final class ManualClock: Clock, @unchecked Sendable {
  typealias Instant = ManualInstant

  private let lock = NSLock()
  private var current = ManualInstant(offset: .zero)

  var now: ManualInstant {
    lock.withLock { current }
  }

  var minimumResolution: Duration {
    .zero
  }

  func advance(by duration: Duration) {
    lock.withLock { current = current.advanced(by: duration) }
  }

  func sleep(until deadline: ManualInstant, tolerance: Duration?) async throws {
    try Task.checkCancellation()
    lock.withLock {
      if deadline.offset > current.offset {
        current = deadline
      }
    }
  }
}

// MARK: - Token Store Double

/// An in-memory `ChatGPTTokenStore`. `saveError` makes the next save fail, which is how a
/// persistence path is exercised without a disk.
final class InMemoryTokenStore: ChatGPTTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ChatGPTCredential?
  private var pendingSaveError: ChatGPTTokenStoreError?
  private var permanentSaveError: ChatGPTTokenStoreError?
  private var saves = 0

  init(_ initial: ChatGPTCredential? = nil) {
    stored = initial
  }

  var saveCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return saves
  }

  var current: ChatGPTCredential? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func failNextSave(with error: ChatGPTTokenStoreError) {
    lock.lock()
    defer { lock.unlock() }
    pendingSaveError = error
  }

  func failAllSaves(with error: ChatGPTTokenStoreError) {
    lock.lock()
    defer { lock.unlock() }
    permanentSaveError = error
  }

  func load() throws(ChatGPTTokenStoreError) -> ChatGPTCredential? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func save(_ credential: ChatGPTCredential) throws(ChatGPTTokenStoreError) {
    lock.lock()
    defer { lock.unlock() }
    if let error = permanentSaveError {
      throw error
    }
    if let error = pendingSaveError {
      pendingSaveError = nil
      throw error
    }
    stored = credential
    saves += 1
  }

  func delete() throws(ChatGPTTokenStoreError) {
    lock.lock()
    defer { lock.unlock() }
    stored = nil
  }
}

// MARK: - Refresher Doubles

/// A refresher that replies from a fixed script and counts its calls.
actor ScriptedRefresher: ChatGPTOAuthRefreshing {
  enum Reply: Sendable {
    case pair(ChatGPTTokenPair)
    case failure(ChatGPTOAuthFailure)
  }

  private var replies: [Reply]
  private var index = 0
  private var calls = 0

  init(_ replies: [Reply]) {
    self.replies = replies
  }

  func refresh(refreshToken: String, timeout: Duration) async throws -> ChatGPTTokenPair {
    calls += 1
    guard index < replies.count else {
      throw ChatGPTOAuthFailure.transport(detail: "no scripted reply")
    }
    let reply = replies[index]
    index += 1
    switch reply {
    case .pair(let pair):
      return pair
    case .failure(let failure):
      throw failure
    }
  }

  func callCount() -> Int {
    calls
  }
}

/// A refresher that suspends inside `refresh` until the test releases it, so a second caller can be
/// observed joining the one flight already in progress.
actor GatedRefresher: ChatGPTOAuthRefreshing {
  private let pair: ChatGPTTokenPair
  private var calls = 0
  private var gate: CheckedContinuation<Void, Never>?
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []

  init(returning pair: ChatGPTTokenPair) {
    self.pair = pair
  }

  func refresh(refreshToken: String, timeout: Duration) async throws -> ChatGPTTokenPair {
    calls += 1
    for waiter in entryWaiters {
      waiter.resume()
    }
    entryWaiters.removeAll()
    await withCheckedContinuation { continuation in
      gate = continuation
    }
    return pair
  }

  /// Returns once `refresh` has been entered at least once.
  func awaitEntered() async {
    if calls > 0 {
      return
    }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func release() {
    gate?.resume()
    gate = nil
  }

  func callCount() -> Int {
    calls
  }
}

// MARK: - JWT + Credential Builders

/// Base64url without padding, the JWT segment encoding.
func base64URLEncode(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

/// A three-segment token whose payload is the given JSON. The signature is a placeholder: nothing in
/// the library verifies it.
func makeJWT(payloadJSON: String) -> String {
  let header = base64URLEncode(Data(#"{"alg":"none"}"#.utf8))
  let payload = base64URLEncode(Data(payloadJSON.utf8))
  return "\(header).\(payload).signature"
}

/// A stored credential whose access token expires at `expiresAt`.
func makeCredential(
  accessToken: String = "access-token",
  refreshToken: String = "refresh-token",
  expiresAt: Date
) -> ChatGPTCredential {
  ChatGPTCredential(
    profileID: UUID(),
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiresAt
  )
}

/// A token pair with a header-safe access token and the given lifetime.
func makeTokenPair(
  accessToken: String = "rotated-access",
  refreshToken: String? = "rotated-refresh",
  expiresAt: Date
) -> ChatGPTTokenPair {
  ChatGPTTokenPair(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
}
