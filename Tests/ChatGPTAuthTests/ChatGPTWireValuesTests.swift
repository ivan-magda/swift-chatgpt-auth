import Foundation
import Testing

@testable import ChatGPTAuth

@Suite
struct ChatGPTWireValuesTests {
  @Test
  func positiveIntegerAcceptsWholeNumbersAndDecimalStrings() {
    // given / when / then
    #expect(ChatGPTWireValues.positiveInteger(.number(5)) == 5)
    #expect(ChatGPTWireValues.positiveInteger(.string("42")) == 42)
  }

  @Test
  func positiveIntegerRejectsZeroFractionalNegativeAndNonNumeric() {
    // given / when / then
    #expect(ChatGPTWireValues.positiveInteger(.number(0)) == nil)
    #expect(ChatGPTWireValues.positiveInteger(.number(5.5)) == nil)
    #expect(ChatGPTWireValues.positiveInteger(.number(-3)) == nil)
    #expect(ChatGPTWireValues.positiveInteger(.string("-3")) == nil)
    #expect(ChatGPTWireValues.positiveInteger(.string("4.5")) == nil)
    #expect(ChatGPTWireValues.positiveInteger(.string("")) == nil)
    #expect(ChatGPTWireValues.positiveInteger(.bool(true)) == nil)
  }

  @Test
  func headerSafeTokenRejectsWhitespaceControlsAndNonASCII() {
    // given / when / then
    #expect(ChatGPTWireValues.headerSafeToken("abc123", maxBytes: 64) == "abc123")
    #expect(ChatGPTWireValues.headerSafeToken("has space", maxBytes: 64) == nil)
    #expect(ChatGPTWireValues.headerSafeToken("has\nnewline", maxBytes: 64) == nil)
    #expect(ChatGPTWireValues.headerSafeToken("café", maxBytes: 64) == nil)
    #expect(ChatGPTWireValues.headerSafeToken("", maxBytes: 64) == nil)
  }

  @Test
  func headerSafeTokenRejectsValuesOverTheByteBound() {
    // given
    let token = String(repeating: "a", count: 65)

    // when / then
    #expect(ChatGPTWireValues.headerSafeToken(token, maxBytes: 64) == nil)
  }

  @Test
  func controlFreeAllowsSpacesAndNonASCIIButNotControls() {
    // given / when / then
    #expect(ChatGPTWireValues.controlFree("user code", maxBytes: 64) == "user code")
    #expect(ChatGPTWireValues.controlFree("café", maxBytes: 64) == "café")
    #expect(ChatGPTWireValues.controlFree("with\u{1B}escape", maxBytes: 64) == nil)
    #expect(ChatGPTWireValues.controlFree("", maxBytes: 64) == nil)
  }

  @Test
  func safeRemoteDiagnosticStripsEscapesCollapsesWhitespaceAndRedacts() {
    // given
    let raw = "error \u{1B}[31mred\u{1B}[0m\n\ttoken=SECRET"

    // when
    let cleaned = ChatGPTWireValues.safeRemoteDiagnostic(
      raw,
      redacting: ["SECRET"],
      maxBytes: 1024
    )

    // then
    #expect(cleaned == "error red token=[redacted]")
  }

  @Test
  func safeRemoteDiagnosticRedactsBeforeTruncatingSoASecretCannotSurviveTheCut() {
    // given: the secret sits at the end, where a truncate-first order would expose its prefix
    let raw = "padding padding SECRETSECRET"

    // when
    let cleaned = ChatGPTWireValues.safeRemoteDiagnostic(
      raw,
      redacting: ["SECRETSECRET"],
      maxBytes: 1024
    )

    // then
    #expect(cleaned.contains("SECRET") == false)
    #expect(cleaned.contains("[redacted]"))
  }

  @Test
  func safeRemoteDiagnosticBoundsTheResultToTheByteCap() {
    // given
    let raw = String(repeating: "x", count: 500)

    // when
    let cleaned = ChatGPTWireValues.safeRemoteDiagnostic(raw, redacting: [], maxBytes: 64)

    // then
    #expect(cleaned.utf8.count <= 64)
  }
}
