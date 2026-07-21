import Foundation
import Testing

@testable import ChatGPTAuth

@Suite
struct ChatGPTTokenMetadataTests {
  @Test
  func extractsExpiryAndAccountFromAWellFormedToken() {
    // given
    let token = makeJWT(
      payloadJSON: """
        {"exp": 2000000000, "https://api.openai.com/auth": {"chatgpt_account_id": "acct_abc"}}
        """
    )

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == Date(timeIntervalSince1970: 2000000000))
    #expect(metadata.accountID == "acct_abc")
  }

  @Test
  func acceptsAnExpiryEncodedAsADecimalString() {
    // given
    let token = makeJWT(payloadJSON: #"{"exp": "1893456000"}"#)

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == Date(timeIntervalSince1970: 1893456000))
    #expect(metadata.accountID == nil)
  }

  @Test
  func reportsAbsentWhenTheAccountClaimIsNotHeaderSafe() {
    // given
    let token = makeJWT(
      payloadJSON: """
        {"https://api.openai.com/auth": {"chatgpt_account_id": "has space"}}
        """
    )

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.accountID == nil)
  }

  @Test
  func degradesToNoMetadataForATokenThatIsNotThreeSegments() {
    // given / when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: "not.a.jwt.token")

    // then
    #expect(metadata.expiresAt == nil)
    #expect(metadata.accountID == nil)
  }

  @Test
  func degradesToNoMetadataWhenThePayloadIsNotAJSONObject() {
    // given
    let token = makeJWT(payloadJSON: "[1, 2, 3]")

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == nil)
    #expect(metadata.accountID == nil)
  }

  @Test
  func degradesToNoMetadataWhenTheSegmentIsNotBase64URL() {
    // given: a middle segment carrying characters outside the base64url alphabet
    let token = "header.***not base64***.signature"

    // when
    let metadata = ChatGPTTokenMetadata.extract(accessToken: token)

    // then
    #expect(metadata.expiresAt == nil)
    #expect(metadata.accountID == nil)
  }
}
