import Foundation

/// Exact-value redaction: replaces every occurrence of each secret with a fixed marker. Vendor
/// diagnostics can quote a token back, so the exact secret values are scrubbed out before any text
/// reaches a log line, a terminal, or an error a caller might surface.
struct SecretRedactor: Sendable {
  static let replacement = "[redacted]"

  private let secretValues: [String]

  init(secretValues: [String]) {
    self.secretValues = secretValues.filter { value in
      value.isEmpty == false
    }
  }

  func redact(_ text: String) -> String {
    var redacted = text

    for secret in secretValues {
      redacted = redacted.replacingOccurrences(of: secret, with: Self.replacement)
    }

    return redacted
  }
}
