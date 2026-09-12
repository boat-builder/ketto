import Foundation

/// Design metadata shared by the composer (geometry) and the atlas (rasterisation).
/// Every glyph is designed in a 32×32 point box; `hotspot` is normalised within that box.
enum CursorGlyphs {
    /// Size of the design box in points. A 1× macOS cursor is 32 pt wide.
    static let designSize: Double = 32

    static func hotspot(for type: CursorType) -> SIMD2<Double> {
        switch type {
        case .arrow: return SIMD2(3 / 32, 2 / 32)
        case .iBeam: return SIMD2(0.5, 0.5)
        case .pointingHand: return SIMD2(12.75 / 32, 3 / 32)
        case .crosshair: return SIMD2(0.5, 0.5)
        case .resizeLeftRight: return SIMD2(0.5, 0.5)
        case .resizeUpDown: return SIMD2(0.5, 0.5)
        case .openHand, .closedHand: return SIMD2(0.5, 0.5)
        case .notAllowed: return SIMD2(0.5, 0.5)
        }
    }

    static let atlasOrder: [CursorType] = CursorType.allCases

    static func atlasIndex(for type: CursorType) -> Int {
        atlasOrder.firstIndex(of: type) ?? 0
    }
}
