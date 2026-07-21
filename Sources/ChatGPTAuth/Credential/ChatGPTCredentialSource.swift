import Foundation

// MARK: - Source

/// The live ChatGPT credential: one owner of the stored pair, one refresh in flight at a time, and
/// one place where a rotation becomes real.
///
/// The initial credential is loaded and validated before construction, so a load is never a second
/// implicit flight, and the store stays synchronous so that installing a refreshed pair opens no
/// reentrancy window between deciding to publish and having published.
public actor ChatGPTCredentialSource<ClockType: Clock>
where ClockType.Duration == Duration {
  private let store: any ChatGPTTokenStore
  private let oauth: any ChatGPTOAuthRefreshing
  private let clock: ClockType
  private let wallDate: @Sendable () -> Date

  private var state: State
  private var waiters: [Int: CheckedContinuation<ChatGPTAuthorization, any Error>] = [:]
  private var lastWaiterID = 0
  private var lastFlightID: UInt64 = 0
  /// The pair the current one replaced. Requests authorized under it may still be on the wire, so
  /// their diagnostics must still be able to scrub it. One pair deep, which bounds the set.
  private var priorPair: TokenPair?

  public init(
    initialCredential: ChatGPTCredential?,
    store: any ChatGPTTokenStore,
    oauth: any ChatGPTOAuthRefreshing,
    clock: ClockType,
    wallDate: @escaping @Sendable () -> Date
  ) {
    self.store = store
    self.oauth = oauth
    self.clock = clock
    self.wallDate = wallDate

    switch initialCredential {
    case nil:
      state = .missing
    case .some(let stored):
      // A record whose tokens cannot be spent is not a record a refresh can rescue: the refresh
      // token is one of the two values that just failed. Only a new login repairs it.
      state =
        ChatGPTValidatedCredential(stored).map { credential in
          .ready(credential: credential, generation: Self.initialGeneration, forceRefresh: false)
        } ?? .authenticationRequired
    }
  }

  public func authorization() async throws -> ChatGPTAuthorization {
    let now = wallDate()
    switch state {
    case .stopping:
      throw ChatGPTCredentialError.shuttingDown
    case .missing, .authenticationRequired:
      throw ChatGPTCredentialError.authenticationRequired
    case .pendingPersistence(let pending):
      return try retryPublication(of: pending)
    case .refreshing(let flight):
      return try await join(flight)
    case .cooldown(let cooling):
      let remaining = clock.now.duration(to: cooling.until)
      guard remaining <= .zero else {
        throw cooling.failure(retryAfter: remaining)
      }
      return try await join(startFlight(from: cooling.credential, replacing: cooling.generation))
    case .ready(let credential, let generation, let forceRefresh):
      let freshness = ChatGPTCredentialFreshness.classify(expiresAt: credential.expiresAt, now: now)
      guard forceRefresh || freshness != .fresh else {
        return authorization(for: credential, generation: generation)
      }
      return try await join(startFlight(from: credential, replacing: generation))
    }
  }

  /// A verdict about a snapshot, so it only counts while that snapshot is the one being spent: a
  /// late 401 from a request that authorized two rotations ago has nothing to say about the token
  /// now on the wire.
  public func reject(
    generation: ChatGPTCredentialGeneration,
    disposition: ChatGPTCredentialRejection
  ) async {
    switch state {
    case .ready(let credential, let current, _) where current == generation:
      switch disposition {
      case .refresh:
        state = .ready(credential: credential, generation: current, forceRefresh: true)
      case .authenticationRequired:
        state = .authenticationRequired
      }
    case .cooldown(let cooling) where cooling.generation == generation:
      // A cooldown already ends in a refresh, so `.refresh` asks for what is coming. A terminal
      // verdict is worth latching now: it saves the wait and the request that would follow it.
      if disposition == .authenticationRequired {
        state = .authenticationRequired
      }
    default:
      // A refresh in flight is already the answer to `.refresh`, and its own result decides whether
      // the credential is finished. A pending write must not be dropped on a verdict about the
      // generation it is replacing.
      break
    }
  }

  /// The lifecycle's commit point. It runs to a durable answer or a typed failure — never to a quiet
  /// success that lost a rotation the vendor has already performed.
  public func shutdown() async throws {
    let retained = closeAdmission()
    // Cancelled but not forgotten: the worker may be holding a complete pair, and its finalizer is
    // matched by the flight record this keeps.
    retained.flight?.task.cancel()
    await retained.flight?.task.value

    guard case .stopping(let stopping) = state, let pending = stopping.pending else {
      return
    }
    do {
      try commit(pending)
    } catch {
      throw ChatGPTCredentialError.persistenceFailed(error)
    }
    state = .stopping(Stopping())
  }

  /// The one operation-ID-guarded finalizer: the only place that may write, publish, move the
  /// generation, clear the flight, or resume waiters. Waiters do no post-await cleanup, so a
  /// completion from a flight this actor is no longer running cannot disturb the one it is.
  func finalize(flightID: UInt64, result: Result<ChatGPTTokenPair, any Error>) {
    guard let flight = flight(matching: flightID) else {
      return
    }
    switch result {
    case .success(let pair):
      accept(pair, from: flight)
    case .failure(let error):
      settle(error, from: flight)
    }
  }
}

// MARK: - State Access

extension ChatGPTCredentialSource {
  var isStopping: Bool {
    if case .stopping = state {
      return true
    }
    return false
  }

  /// A flight record is reachable from exactly two states, and only under its own ID.
  func flight(matching flightID: UInt64) -> Flight? {
    switch state {
    case .refreshing(let flight) where flight.id == flightID:
      return flight
    case .stopping(let stopping) where stopping.flight?.id == flightID:
      return stopping.flight
    default:
      return nil
    }
  }
}

// MARK: - Publication

extension ChatGPTCredentialSource {
  /// A caller retrying a write it did not start. It spends no rotation: the vendor may already have
  /// consumed the refresh token that produced this pair, so asking again could lose it for good.
  func retryPublication(of pending: Pending) throws -> ChatGPTAuthorization {
    // The write is bounded but not free, and it is not cancellable once begun — so the check belongs
    // here, before it starts, rather than inside a store that would have to abandon a half-written
    // envelope to honor it.
    try Task.checkCancellation()
    do {
      try commit(pending)
    } catch {
      throw ChatGPTCredentialError.persistenceFailed(error)
    }
    return install(pending)
  }

  func commit(_ pending: Pending) throws(ChatGPTTokenStoreError) {
    try store.save(pending.credential.stored)
  }

  /// Publication proper: the generation moves only here, and only after the write returned.
  func install(_ pending: Pending) -> ChatGPTAuthorization {
    let generation = ChatGPTCredentialGeneration(value: pending.baseGeneration.value + 1)
    state = .ready(credential: pending.credential, generation: generation, forceRefresh: false)
    return authorization(for: pending.credential, generation: generation)
  }

  func authorization(
    for credential: ChatGPTValidatedCredential,
    generation: ChatGPTCredentialGeneration
  ) -> ChatGPTAuthorization {
    let base = ChatGPTProviderMetadata.authorization(
      accessToken: credential.accessToken,
      generation: generation
    )
    var values = base.redactionValues
    append(credential.refreshToken, to: &values)
    if let priorPair {
      append(priorPair.accessToken, to: &values)
      append(priorPair.refreshToken, to: &values)
    }
    return ChatGPTAuthorization(
      headers: base.headers,
      redactionValues: values,
      generation: base.generation
    )
  }

  func append(_ value: String, to values: inout [String]) {
    guard values.contains(value) == false else {
      return
    }
    values.append(value)
  }
}

// MARK: - Flights

extension ChatGPTCredentialSource {
  /// Starts exactly one flight and records it before anything can suspend, so the next caller
  /// through the door finds it rather than starting a second.
  ///
  /// Unlike `retryPublication`, this does not check for cancellation first: a caller that is already
  /// cancelled still starts the flight and only then abandons it in `join`. That asymmetry is
  /// deliberate. The rotation is under way and its answer lands durably for whoever comes next,
  /// whereas a publication retry would spend a rotation the vendor may already have consumed.
  func startFlight(
    from credential: ChatGPTValidatedCredential,
    replacing generation: ChatGPTCredentialGeneration
  ) -> Flight {
    lastFlightID += 1
    let flightID = lastFlightID
    let task = Task {
      await self.runRefresh(flightID: flightID, snapshot: credential)
    }
    let flight = Flight(
      id: flightID,
      baseGeneration: generation,
      credential: credential,
      task: task
    )
    state = .refreshing(flight)
    return flight
  }

  /// The refresh worker. It is deliberately outside the actor: only its finalizer touches state, and
  /// only through the actor's own door.
  nonisolated func runRefresh(flightID: UInt64, snapshot: ChatGPTValidatedCredential) async {
    var attempt = 1
    while true {
      do {
        let pair = try await oauth.refresh(
          refreshToken: snapshot.refreshToken,
          timeout: ChatGPTProviderMetadata.requestTimeout
        )
        // The commit point. Cancellation may already have been delivered; the handoff happens
        // anyway, because a decoded pair means the vendor has rotated whether we stop or not.
        await finalize(flightID: flightID, result: .success(pair))
        return
      } catch {
        guard Self.isWorthRetrying(error), attempt < ChatGPTRefreshPolicy.attemptBudget else {
          await finalize(flightID: flightID, result: .failure(error))
          return
        }
        do {
          try await clock.sleep(for: ChatGPTRefreshPolicy.backoff(afterAttempt: attempt))
        } catch let interruption {
          await finalize(flightID: flightID, result: .failure(interruption))
          return
        }
        attempt += 1
      }
    }
  }

  nonisolated static func isWorthRetrying(_ error: any Error) -> Bool {
    guard case .transport = error as? ChatGPTOAuthFailure else {
      return false
    }
    return true
  }

  func join(_ flight: Flight) async throws -> ChatGPTAuthorization {
    lastWaiterID += 1
    let waiterID = lastWaiterID
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Runs on this actor with no suspension between the state check that chose this flight and
        // the registration, so a finalizer cannot slip past a caller on its way in.
        waiters[waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.abandon(waiterID: waiterID)
      }
    }
  }

  /// One waiter leaving. It resumes only itself: the flight belongs to every other waiter too, and
  /// none of them asked to stop.
  func abandon(waiterID: Int) {
    waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
  }

  func resumeWaiters(with result: Result<ChatGPTAuthorization, any Error>) {
    let parked = waiters
    waiters.removeAll()
    for waiter in parked.values {
      waiter.resume(with: result)
    }
  }
}

// MARK: - Finalization

extension ChatGPTCredentialSource {
  func accept(_ pair: ChatGPTTokenPair, from flight: Flight) {
    guard let rotated = ChatGPTValidatedCredential(rotating: flight.credential, with: pair) else {
      // The old refresh token may already be spent, so there is nothing left to retry with. A
      // source on its way down says so instead: there is no next caller here to tell.
      guard isStopping == false else {
        state = .stopping(Stopping())
        return
      }
      finish(.authenticationRequired, resuming: .authenticationRequired)
      return
    }
    priorPair = TokenPair(
      accessToken: flight.credential.accessToken,
      refreshToken: flight.credential.refreshToken
    )
    let pending = Pending(credential: rotated, baseGeneration: flight.baseGeneration)
    do {
      try commit(pending)
    } catch {
      withhold(pending, after: error)
      return
    }
    guard isStopping == false else {
      state = .stopping(Stopping())
      return
    }
    resumeWaiters(with: .success(install(pending)))
  }

  /// A rotated pair that could not be written. It is kept whole and unused: exposing it would let a
  /// restart authorize with a token the disk has never heard of.
  func withhold(_ pending: Pending, after failure: ChatGPTTokenStoreError) {
    guard isStopping == false else {
      state = .stopping(Stopping(flight: nil, pending: pending))
      return
    }
    state = .pendingPersistence(pending)
    resumeWaiters(with: .failure(ChatGPTCredentialError.persistenceFailed(failure)))
  }

  func settle(_ error: any Error, from flight: Flight) {
    guard isStopping == false else {
      state = .stopping(Stopping())
      return
    }
    // A cancellation is not special-cased here. The only one this actor ever delivers comes from
    // shutdown, which sets the stopping state the guard above already caught; any cancellation
    // reaching this point is one a waiter never asked for, so it earns the transient cooldown below
    // rather than a false "you cancelled" handed to live requests.
    guard let cooling = cooling(for: error, from: flight) else {
      finish(.authenticationRequired, resuming: .authenticationRequired)
      return
    }
    state = .cooldown(cooling)
    resumeWaiters(
      with: .failure(cooling.failure(retryAfter: clock.now.duration(to: cooling.until)))
    )
  }

  func finish(_ next: State, resuming failure: ChatGPTCredentialError) {
    state = next
    resumeWaiters(with: .failure(failure))
  }

  /// The wait a failure earns, or nil when it earns none because only a login will do.
  ///
  /// Nothing here interpolates the raw error: an unrecognized one may carry a path or key material
  /// in its description, and the two `detail`s that are used arrived already sanitized and redacted.
  func cooling(for error: any Error, from flight: Flight) -> Cooling? {
    let reason: Cooling.Reason
    let delay: Duration
    switch error as? ChatGPTOAuthFailure {
    case .grantRejected:
      return nil
    case .throttled(let retryAfter):
      reason = .throttled
      delay = retryAfter ?? ChatGPTRefreshPolicy.maximumCooldown
    case .malformedResponse(let detail), .transport(let detail):
      reason = .unavailable(detail: detail)
      delay = ChatGPTRefreshPolicy.maximumCooldown
    // `.deadlineExceeded` names a login window that closed, which only the device-code poll can
    // reach; a refresh cannot raise it. It shares the catch-all rather than claiming an event of
    // its own so no caller is ever told a story about a deadline this path does not keep.
    case nil, .deadlineExceeded:
      reason = .unavailable(detail: "the refresh did not complete")
      delay = ChatGPTRefreshPolicy.maximumCooldown
    }
    return Cooling(
      credential: flight.credential,
      generation: flight.baseGeneration,
      reason: reason,
      until: clock.now.advanced(by: delay)
    )
  }
}

// MARK: - Shutdown

extension ChatGPTCredentialSource {
  /// Closes the door and resumes everyone already inside, keeping only what the commit rule still
  /// owes: an active flight, or a pair that was never written.
  func closeAdmission() -> Stopping {
    let retained: Stopping
    switch state {
    case .refreshing(let flight):
      retained = Stopping(flight: flight, pending: nil)
    case .pendingPersistence(let pending):
      retained = Stopping(flight: nil, pending: pending)
    case .stopping(let stopping):
      retained = stopping
    case .missing, .ready, .cooldown, .authenticationRequired:
      retained = Stopping()
    }
    state = .stopping(retained)
    // Everyone parked here is leaving because the source is shutting down, not because their own
    // task was cancelled — that distinction is what `abandon` keeps for a single departing waiter.
    resumeWaiters(with: .failure(ChatGPTCredentialError.shuttingDown))
    return retained
  }
}

// MARK: - Convenience

public extension ChatGPTCredentialSource where ClockType == ContinuousClock {
  /// The everyday source: a continuous clock measures cooldowns and the system wall clock measures a
  /// token's expiry. Mirrors the zero-clock initializers on `ChatGPTDeviceLogin` and
  /// `ChatGPTDeviceAuthorization`.
  init(
    initialCredential: ChatGPTCredential?,
    store: any ChatGPTTokenStore,
    oauth: any ChatGPTOAuthRefreshing
  ) {
    self.init(
      initialCredential: initialCredential,
      store: store,
      oauth: oauth,
      clock: ContinuousClock()
    ) { Date() }
  }
}
