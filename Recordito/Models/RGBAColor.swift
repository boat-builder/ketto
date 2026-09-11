import Foundation
import simd

/// A colour stored as `#RRGGBB` / `#RRGGBBAA` in the edit document.
struct RGBAColor: Equatable, Hashable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 6 {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        } else {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        }
    }

    var hex: String {
        func component(_ v: Double) -> String {
            String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded()))
        }
        let base = "#" + component(red) + component(green) + component(blue)
        return alpha >= 0.999 ? base : base + component(alpha)
    }

    var simd: SIMD4<Float> { SIMD4(Float(red), Float(green), Float(blue), Float(alpha)) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = RGBAColor(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid colour \(text)")
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)
}
