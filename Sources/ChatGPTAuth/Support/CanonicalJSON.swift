import Foundation

/// Encodes a value to JSON with sorted keys and no slash escaping, so the same input always produces
/// the same bytes. The device flow uses it for request bodies a test can pin exactly.
enum CanonicalJSON {
  static func encode<Value: Encodable>(_ value: Value) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    guard
      let data = try? encoder.encode(value),
      let json = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    return json
  }
}
