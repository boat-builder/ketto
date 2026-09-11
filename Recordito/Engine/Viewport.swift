import Foundation
import CoreGraphics

/// The visible sub-rectangle of the source, in normalised source coordinates (0–1 on both axes).
/// A `Viewport` of size (1/s, 1/s) shows the source zoomed in by `s` while keeping the source aspect ratio.
struct Viewport: Equatable, Sendable {
    var origin: SIMD2<Double>
    var size: SIMD2<Double>

    static let full = Viewport(origin: SIMD2(0, 0), size: SIMD2(1, 1))

    init(origin: SIMD2<Double>, size: SIMD2<Double>) {
        self.origin = origin
        self.size = size
    }

    /// A viewport of zoom factor `scale` centred on `center`, clamped so it never leaves the source bounds.
    init(center: SIMD2<Double>, scale: Double) {
        let s = max(1, scale)
        let side = 1 / s
        self.size = SIMD2(side, side)
        self.origin = center - SIMD2(side, side) / 2
        self = clamped()
    }

    var center: SIMD2<Double> { origin + size / 2 }
    var scale: Double { size.x > 0 ? 1 / size.x : 1 }
    var maxX: Double { origin.x + size.x }
    var maxY: Double { origin.y + size.y }

    func clamped() -> Viewport {
        var v = self
        v.size = SIMD2(min(max(v.size.x, 0.01), 1), min(max(v.size.y, 0.01), 1))
        v.origin.x = min(max(v.origin.x, 0), 1 - v.size.x)
        v.origin.y = min(max(v.origin.y, 0), 1 - v.size.y)
        return v
    }

    static func lerp(_ a: Viewport, _ b: Viewport, _ t: Double) -> Viewport {
        let u = min(max(t, 0), 1)
        return Viewport(origin: a.origin + (b.origin - a.origin) * u, size: a.size + (b.size - a.size) * u).clamped()
    }

    var cgRect: CGRect { CGRect(x: origin.x, y: origin.y, width: size.x, height: size.y) }

    func isApproximatelyEqual(to other: Viewport, tolerance: Double = 1e-6) -> Bool {
        abs(origin.x - other.origin.x) < tolerance && abs(origin.y - other.origin.y) < tolerance
            && abs(size.x - other.size.x) < tolerance && abs(size.y - other.size.y) < tolerance
    }
}
