import Foundation
import Testing

@testable import ChatGPTAuth

@Suite
struct ChatGPTCredentialFreshnessTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test
  func aTokenWellBeyondTheSkewWindowIsFresh() {
    // given
    let expiresAt = now.addingTimeInterval(300)

    // when
    let freshness = ChatGPTCredentialFreshness.classify(expiresAt: expiresAt, now: now)

    // then
    #expect(freshness == .fresh)
  }

  @Test
  func aTokenInsideTheSkewWindowIsExpiring() {
    // given: still valid, but under the 120-second skew
    let expiresAt = now.addingTimeInterval(60)

    // when
    let freshness = ChatGPTCredentialFreshness.classify(expiresAt: expiresAt, now: now)

    // then
    #expect(freshness == .expiring)
  }

  @Test
  func theSkewBoundaryItselfCountsAsExpiring() {
    // given: exactly at now + skew, which is not strictly beyond it
    let expiresAt = now.addingTimeInterval(120)

    // when
    let freshness = ChatGPTCredentialFreshness.classify(expiresAt: expiresAt, now: now)

    // then
    #expect(freshness == .expiring)
  }

  @Test
  func aLapsedTokenIsExpired() {
    // given
    let expiresAt = now.addingTimeInterval(-10)

    // when
    let freshness = ChatGPTCredentialFreshness.classify(expiresAt: expiresAt, now: now)

    // then
    #expect(freshness == .expired)
  }
}
