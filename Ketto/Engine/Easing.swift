import Foundation

enum Easing: String, Codable, CaseIterable, Sendable {
    case linear
    case easeInQuad
    case easeOutQuad
    case easeInOutQuad
    case easeInOutCubic
    case easeOutCubic
    case easeInOutSine
    case easeOutExpo

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Easing(rawValue: raw) ?? .easeInOutCubic
    }

    /// Maps a progress value in 0...1 to eased progress in 0...1.
    func apply(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        switch self {
        case .linear:
            return t
        case .easeInQuad:
            return t * t
        case .easeOutQuad:
            return 1 - (1 - t) * (1 - t)
        case .easeInOutQuad:
            return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .easeInOutCubic:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .easeOutCubic:
            return 1 - pow(1 - t, 3)
        case .easeInOutSine:
            return -(cos(Double.pi * t) - 1) / 2
        case .easeOutExpo:
            return t >= 1 ? 1 : 1 - pow(2, -10 * t)
        }
    }
}
