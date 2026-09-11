import Foundation

/// Helpers so that a missing key in `events.json` / `edit.json` is never an error.
extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue()
    }
}

enum DocumentJSON {
    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return encoder
    }

    static let decoder = JSONDecoder()
}
