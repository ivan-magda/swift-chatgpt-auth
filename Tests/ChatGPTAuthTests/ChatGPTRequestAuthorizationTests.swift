import Foundation
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@testable import ChatGPTAuth

@Suite
struct ChatGPTRequestAuthorizationTests {
  private let wallDate = Date(timeIntervalSince1970: 1_700_000_000)
  private let apiURL = URL(string: "https://api.example.com/v1/things")

  private func makeSource(
    initial: ChatGPTCredential,
    oauth: any ChatGPTOAuthRefreshing
  ) -> ChatGPTCredentialSource<ManualClock> {
    let clock = wallDate
    return ChatGPTCredentialSource(
      initialCredential: initial,
      store: InMemoryTokenStore(initial),
      oauth: oauth,
      clock: ManualClock()
    ) { clock }
  }

  private func fresh() -> ChatGPTCredential {
    makeCredential(accessToken: "fresh-access", expiresAt: wallDate.addingTimeInterval(3600))
  }

  private func rotatedPair() -> ChatGPTTokenPair {
    makeTokenPair(
      accessToken: "new-access",
      refreshToken: "new-refresh",
      expiresAt: wallDate.addingTimeInterval(3600)
    )
  }

  // MARK: - apply(to:)

  @Test
  func applyStampsEveryHeaderOntoTheRequest() throws {
    // given
    let authorization = ChatGPTAuthorization(
      headers: ["Authorization": "Bearer token", "ChatGPT-Account-ID": "account"],
      redactionValues: ["token"],
      generation: ChatGPTCredentialGeneration(value: 1),
      accessToken: "token",
      expiresAt: wallDate
    )
    let url = try #require(apiURL)
    var request = URLRequest(url: url)

    // when
    authorization.apply(to: &request)

    // then
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account")
  }

  @Test
  func applyRemovesACredentialHeaderTheNewAuthorizationNoLongerCarries() throws {
    // given: a request already authorized by a token that named an account
    let withAccount = ChatGPTAuthorization(
      headers: ["Authorization": "Bearer old", "ChatGPT-Account-ID": "account"],
      redactionValues: ["old"],
      generation: ChatGPTCredentialGeneration(value: 1),
      accessToken: "old",
      expiresAt: wallDate
    )
    let withoutAccount = ChatGPTAuthorization(
      headers: ["Authorization": "Bearer new"],
      redactionValues: ["new"],
      generation: ChatGPTCredentialGeneration(value: 2),
      accessToken: "new",
      expiresAt: wallDate
    )
    let url = try #require(apiURL)
    var request = URLRequest(url: url)
    withAccount.apply(to: &request)

    // when: the rotated token has no safe account claim
    withoutAccount.apply(to: &request)

    // then: the new bearer travels with no stale account routing
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
  }

  // MARK: - authorizeRequest(_:)

  @Test
  func authorizeRequestAttachesTheBearerAndReturnsTheSnapshot() async throws {
    // given
    let source = makeSource(initial: fresh(), oauth: ScriptedRefresher([]))
    let url = try #require(apiURL)
    var request = URLRequest(url: url)

    // when
    let authorization = try await source.authorizeRequest(&request)

    // then: the caller holds the generation to feed back and the values a diagnostic must scrub
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
    #expect(authorization.generation == ChatGPTCredentialGeneration(value: 1))
    #expect(authorization.redactionValues.contains("fresh-access"))
  }

  // MARK: - withAuthorization

  @Test
  func withAuthorizationReturnsTheValueWhenTheRequestSucceeds() async throws {
    // given
    let refresher = ScriptedRefresher([])
    let source = makeSource(initial: fresh(), oauth: refresher)

    // when
    let value = try await source.withAuthorization { authorization in
      (value: authorization.accessToken, status: 200)
    }

    // then
    #expect(value == "fresh-access")
    #expect(await refresher.callCount() == 0)
  }

  @Test
  func withAuthorizationRefreshesAndRetriesOnceAfterAClean401() async throws {
    // given: the send closure rejects the original token and accepts the rotated one
    let refresher = ScriptedRefresher([.pair(rotatedPair())])
    let source = makeSource(initial: fresh(), oauth: refresher)

    // when
    let value = try await source.withAuthorization { authorization in
      (value: authorization.accessToken, status: authorization.accessToken == "fresh-access" ? 401 : 200)
    }

    // then: the retry spent the rotated token, and exactly one refresh flew
    #expect(value == "new-access")
    #expect(await refresher.callCount() == 1)
  }

  @Test
  func withAuthorizationDoesNotLatchWhenTheRetrys401IsStale() async throws {
    // given: enough scripted rotations for a concurrent caller to move the credential mid-retry
    let second = makeTokenPair(
      accessToken: "second-access",
      refreshToken: "second-refresh",
      expiresAt: wallDate.addingTimeInterval(3600)
    )
    let third = makeTokenPair(
      accessToken: "third-access",
      refreshToken: "third-refresh",
      expiresAt: wallDate.addingTimeInterval(3600)
    )
    let refresher = ScriptedRefresher([.pair(second), .pair(third)])
    let source = makeSource(initial: fresh(), oauth: refresher)

    // when: the retry's token is rotated away beneath it before its 401 lands
    let value = try await source.withAuthorization { authorization in
      switch authorization.accessToken {
      case "fresh-access":
        return (value: authorization.accessToken, status: 401)
      case "second-access":
        // A concurrent caller gets its own clean 401 and rotates while this retry is in flight.
        await source.reject(generation: authorization.generation, disposition: .refresh)
        _ = try await source.authorization()
        return (value: authorization.accessToken, status: 401)
      default:
        return (value: authorization.accessToken, status: 200)
      }
    }

    // then: the stale 401 neither latches the source nor reaches the caller as terminal
    #expect(value == "third-access")
    let next = try await source.authorization()
    #expect(next.accessToken == "third-access")
  }

  @Test
  func rejectReportsWhetherTheVerdictWasApplied() async throws {
    // given
    let refresher = ScriptedRefresher([.pair(rotatedPair())])
    let source = makeSource(initial: fresh(), oauth: refresher)
    let first = try await source.authorization()

    // when: the credential rotates, making the first generation stale
    let applied = await source.reject(generation: first.generation, disposition: .refresh)
    let rotated = try await source.authorization()
    let stale = await source.reject(generation: first.generation, disposition: .authenticationRequired)

    // then
    #expect(applied == true)
    #expect(stale == false)
    #expect(rotated.generation != first.generation)
  }

  @Test
  func withAuthorizationLatchesAuthenticationRequiredAfterASecond401() async throws {
    // given: the server refuses both the original token and the freshly rotated one
    let refresher = ScriptedRefresher([.pair(rotatedPair())])
    let source = makeSource(initial: fresh(), oauth: refresher)

    // when
    let failure = await captureError(ChatGPTCredentialError.self) {
      try await source.withAuthorization { authorization in
        (value: authorization.accessToken, status: 401)
      }
    }

    // then: the second verdict is terminal, and the source is latched for the next caller too
    #expect(failure == .authenticationRequired)
    let next = await captureError(ChatGPTCredentialError.self) {
      try await source.authorization()
    }
    #expect(next == .authenticationRequired)
  }
}
