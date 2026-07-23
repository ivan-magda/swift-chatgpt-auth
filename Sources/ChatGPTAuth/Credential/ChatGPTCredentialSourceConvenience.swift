import Foundation

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
