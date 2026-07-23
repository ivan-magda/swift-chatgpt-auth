import Foundation
import Testing

@testable import ChatGPTAuth

@Suite
struct ChatGPTCredentialSourceTests {
  private let wallDate = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeSource(
    initial: ChatGPTCredential?,
    store: InMemoryTokenStore,
    oauth: any ChatGPTOAuthRefreshing
  ) -> ChatGPTCredentialSource<ManualClock> {
    let clock = wallDate
    return ChatGPTCredentialSource(
      initialCredential: initial,
      store: store,
      oauth: oauth,
      clock: ManualClock()
    ) { clock }
  }

  private func fresh() -> ChatGPTCredential {
    makeCredential(accessToken: "fresh-access", expiresAt: wallDate.addingTimeInterval(3600))
  }

  private func expiring() -> ChatGPTCredential {
    makeCredential(accessToken: "old-access", expiresAt: wallDate.addingTimeInterval(60))
  }

  private func rotatedPair() -> ChatGPTTokenPair {
    makeTokenPair(
      accessToken: "new-access",
      refreshToken: "new-refresh",
      expiresAt: wallDate.addingTimeInterval(3600)
    )
  }

  // MARK: - Happy paths

  @Test
  func aFreshCredentialAuthorizesWithoutRefreshing() async throws {
    // given
    let refresher = ScriptedRefresher([])
    let source = makeSource(initial: fresh(), store: InMemoryTokenStore(), oauth: refresher)

    // when
    let authorization = try await source.authorization()

    // then
    #expect(authorization.headers["Authorization"] == "Bearer fresh-access")
    #expect(authorization.generation == ChatGPTCredentialGeneration(value: 1))
    #expect(await refresher.callCount() == 0)
  }

  @Test
  func anAuthorizationCarriesTheTypedTokenAndExpiry() async throws {
    // given
    let refresher = ScriptedRefresher([])
    let source = makeSource(initial: fresh(), store: InMemoryTokenStore(), oauth: refresher)

    // when
    let authorization = try await source.authorization()

    // then: a non-URLRequest transport reads the bearer and expiry without parsing headers
    #expect(authorization.accessToken == "fresh-access")
    #expect(authorization.expiresAt == wallDate.addingTimeInterval(3600))
  }

  @Test
  func anExpiringCredentialRefreshesRotatesAndPersists() async throws {
    // given
    let store = InMemoryTokenStore(expiring())
    let refresher = ScriptedRefresher([.pair(rotatedPair())])
    let source = makeSource(initial: expiring(), store: store, oauth: refresher)

    // when
    let authorization = try await source.authorization()

    // then
    #expect(authorization.headers["Authorization"] == "Bearer new-access")
    #expect(authorization.generation == ChatGPTCredentialGeneration(value: 2))
    #expect(store.current?.accessToken == "new-access")
    #expect(store.saveCount == 1)
  }

  @Test
  func concurrentCallersShareASingleRefreshFlight() async throws {
    // given
    let refresher = GatedRefresher(returning: rotatedPair())
    let source = makeSource(initial: expiring(), store: InMemoryTokenStore(), oauth: refresher)

    // when: the first caller starts the flight, the second arrives while it is in progress
    async let first = source.authorization()
    await refresher.awaitEntered()
    async let second = source.authorization()
    await refresher.release()
    let firstResult = try await first
    let secondResult = try await second

    // then
    #expect(await refresher.callCount() == 1)
    #expect(firstResult.generation == secondResult.generation)
  }

  // MARK: - Logout

  @Test
  func logoutClearsTheStoreAndRequiresANewLogin() async throws {
    // given
    let store = InMemoryTokenStore(fresh())
    let source = makeSource(initial: fresh(), store: store, oauth: ScriptedRefresher([]))

    // when
    try await source.logout()

    // then: the pair is gone durably and in memory, and only a new login repairs it
    #expect(store.current == nil)
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    #expect(failure == .authenticationRequired)
  }

  @Test
  func logoutResumesInFlightWaitersAndDiscardsTheRotation() async throws {
    // given: a refresh is in flight and a caller is waiting on it
    let store = InMemoryTokenStore(expiring())
    let refresher = GatedRefresher(returning: rotatedPair())
    let source = makeSource(initial: expiring(), store: store, oauth: refresher)
    let waiting = Task { try await source.authorization() }
    await refresher.awaitEntered()

    // when
    try await source.logout()

    // then: the waiter leaves with the terminal verdict, and the late rotation is discarded
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await waiting.value
    }
    #expect(failure == .authenticationRequired)
    await refresher.release()
    await Task.yield()
    #expect(store.current == nil)
  }

  @Test
  func logoutThatCannotDeleteStillClearsMemoryAndReportsTheFailure() async throws {
    // given
    let store = InMemoryTokenStore(fresh())
    store.failNextDelete(with: .unavailable)
    let source = makeSource(initial: fresh(), store: store, oauth: ScriptedRefresher([]))

    // when
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.logout()
    }

    // then: the failure is reported, but the source never spends the pair again
    #expect(failure == .persistenceFailed(.unavailable))
    let next = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    #expect(next == .authenticationRequired)
  }

  @Test
  func logoutOnAStoppingSourceReportsShuttingDown() async throws {
    // given
    let source = makeSource(initial: fresh(), store: InMemoryTokenStore(), oauth: ScriptedRefresher([]))
    try await source.shutdown()

    // when
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.logout()
    }

    // then
    #expect(failure == .shuttingDown)
  }

  // MARK: - Failure paths

  @Test
  func aRetryableRefreshThatNeverRecoversCoolsDownAndSurfacesTheWait() async throws {
    // given: transport failures exhaust the attempt budget
    let refresher = ScriptedRefresher([
      .failure(.transport(detail: "down")),
      .failure(.transport(detail: "down")),
      .failure(.transport(detail: "down"))
    ])
    let source = makeSource(initial: expiring(), store: InMemoryTokenStore(), oauth: refresher)

    // when
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    guard case .temporarilyUnavailable? = failure else {
      Issue.record("expected temporarilyUnavailable, got \(String(describing: failure))")
      return
    }
  }

  @Test
  func aRejectedGrantLatchesAuthenticationRequired() async throws {
    // given
    let refresher = ScriptedRefresher([.failure(.grantRejected(detail: "revoked"))])
    let source = makeSource(initial: expiring(), store: InMemoryTokenStore(), oauth: refresher)

    // when
    let first = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    let second = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then: both are authenticationRequired, and the second did not start another flight
    #expect(first == .authenticationRequired)
    #expect(second == .authenticationRequired)
    #expect(await refresher.callCount() == 1)
  }

  @Test
  func aFailedWriteWithholdsTheRotationUntilARetrySucceeds() async throws {
    // given: the refresh succeeds but the first save fails
    let store = InMemoryTokenStore(expiring())
    store.failNextSave(with: .publicationFailed)
    let refresher = ScriptedRefresher([.pair(rotatedPair())])
    let source = makeSource(initial: expiring(), store: store, oauth: refresher)

    // when
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    let retried = try await source.authorization()

    // then
    guard case .persistenceFailed? = failure else {
      Issue.record("expected persistenceFailed, got \(String(describing: failure))")
      return
    }
    #expect(retried.headers["Authorization"] == "Bearer new-access")
    #expect(store.current?.accessToken == "new-access")
    #expect(await refresher.callCount() == 1)
  }

  // MARK: - Rejection

  @Test
  func aRejectionOfTheCurrentGenerationForcesTheNextAuthorizationToRefresh() async throws {
    // given
    let refresher = ScriptedRefresher([.pair(rotatedPair())])
    let source = makeSource(initial: fresh(), store: InMemoryTokenStore(), oauth: refresher)

    // when
    let first = try await source.authorization()
    await source.reject(generation: first.generation, disposition: .refresh)
    let second = try await source.authorization()

    // then
    #expect(second.headers["Authorization"] == "Bearer new-access")
    #expect(await refresher.callCount() == 1)
  }

  @Test
  func aRejectionOfAStaleGenerationIsIgnored() async throws {
    // given
    let refresher = ScriptedRefresher([])
    let source = makeSource(initial: fresh(), store: InMemoryTokenStore(), oauth: refresher)

    // when
    _ = try await source.authorization()
    await source.reject(generation: ChatGPTCredentialGeneration(value: 99), disposition: .refresh)
    let again = try await source.authorization()

    // then: still the original fresh credential, no refresh provoked
    #expect(again.headers["Authorization"] == "Bearer fresh-access")
    #expect(await refresher.callCount() == 0)
  }

  // MARK: - Shutdown

  @Test
  func shutdownCommitsAWithheldRotation() async throws {
    // given: a rotation held back by a failed write
    let store = InMemoryTokenStore(expiring())
    store.failNextSave(with: .publicationFailed)
    let refresher = ScriptedRefresher([.pair(rotatedPair())])
    let source = makeSource(initial: expiring(), store: store, oauth: refresher)
    _ = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // when
    try await source.shutdown()

    // then
    #expect(store.current?.accessToken == "new-access")
  }

  @Test
  func authorizationAfterShutdownReportsShuttingDown() async throws {
    // given
    let source = makeSource(initial: fresh(), store: InMemoryTokenStore(), oauth: ScriptedRefresher([]))

    // when
    try await source.shutdown()
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    #expect(failure == .shuttingDown)
  }

  // MARK: - Rejection and load-path gates

  @Test
  func aRejectionRequestingReauthenticationLatchesIt() async throws {
    // given
    let refresher = ScriptedRefresher([])
    let source = makeSource(initial: fresh(), store: InMemoryTokenStore(), oauth: refresher)

    // when
    let first = try await source.authorization()
    await source.reject(generation: first.generation, disposition: .authenticationRequired)
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    #expect(failure == .authenticationRequired)
    #expect(await refresher.callCount() == 0)
  }

  @Test
  func aMissingInitialCredentialReportsAuthenticationRequired() async throws {
    // given
    let source = makeSource(initial: nil, store: InMemoryTokenStore(), oauth: ScriptedRefresher([]))

    // when
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    #expect(failure == .authenticationRequired)
  }

  @Test
  func anUnspendableStoredCredentialReportsAuthenticationRequired() async throws {
    // given: an access token that could never be a header
    let unusable = makeCredential(
      accessToken: "has space",
      expiresAt: wallDate.addingTimeInterval(3600)
    )
    let source = makeSource(initial: unusable, store: InMemoryTokenStore(), oauth: ScriptedRefresher([]))

    // when
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // then
    #expect(failure == .authenticationRequired)
  }

  // MARK: - Cooldown and shutdown

  @Test
  func aLapsedCooldownStartsAFreshFlightOnTheNextCall() async throws {
    // given: three transport failures drive a cooldown, then a retry is available
    let now = wallDate
    let clock = ManualClock()
    let store = InMemoryTokenStore(expiring())
    let refresher = ScriptedRefresher([
      .failure(.transport(detail: "down")),
      .failure(.transport(detail: "down")),
      .failure(.transport(detail: "down")),
      .pair(rotatedPair())
    ])
    let source = ChatGPTCredentialSource(
      initialCredential: expiring(),
      store: store,
      oauth: refresher,
      clock: clock
    ) { now }
    _ = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // when: time moves past the cooldown ceiling
    clock.advance(by: .seconds(60))
    let authorization = try await source.authorization()

    // then
    #expect(authorization.headers["Authorization"] == "Bearer new-access")
    #expect(authorization.generation == ChatGPTCredentialGeneration(value: 2))
    #expect(await refresher.callCount() == 4)
  }

  @Test
  func shutdownWithAnUnwritableRotationReportsPersistenceFailed() async throws {
    // given: the rotation cannot be written, now or on the shutdown retry
    let store = InMemoryTokenStore(expiring())
    store.failAllSaves(with: .publicationFailed)
    let refresher = ScriptedRefresher([.pair(rotatedPair())])
    let source = makeSource(initial: expiring(), store: store, oauth: refresher)
    _ = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }

    // when
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.shutdown()
    }

    // then
    guard case .persistenceFailed? = failure else {
      Issue.record("expected persistenceFailed, got \(String(describing: failure))")
      return
    }
  }
}
