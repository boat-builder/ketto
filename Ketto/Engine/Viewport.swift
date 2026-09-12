import Foundation
import CoreGraphics

/// The visible sub-rectangle of the source, in normalised source coordinates (0–1 on both axes).
/// A `Viewport` of size (1/s, 1/s) shows the source zoomed in by `s` while keeping the source aspect ratio.
/// With a non-square `base` (a crop, or a vertical canvas filled from a landscape recording) a zoom of `s`
/// shows `base.size / s`, so the picture is never stretched.
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
        self.init(center: center, scale: scale, base: .full, bounds: .full)
    }

    /// A viewport showing `base.size / scale` centred on `center`, clamped so it never leaves `bounds`.
    init(center: SIMD2<Double>, scale: Double, base: Viewport, bounds: Viewport) {
        let s = max(1, scale.isFinite ? scale : 1)
        let size = base.size / s
        self.size = size
        self.origin = center - size / 2
        self = clamped(within: bounds)
    }

    var center: SIMD2<Double> { origin + size / 2 }
    /// Zoom factor relative to the full source width.
    var scale: Double { size.x > 0 ? 1 / size.x : 1 }
    var maxX: Double { origin.x + size.x }
    var maxY: Double { origin.y + size.y }
    /// Width / height in normalised units (multiply by the source aspect for the pixel aspect).
    var aspect: Double { size.y > 0 ? size.x / size.y : 1 }

    /// Zoom factor relative to `base`: how much larger than the base view the picture appears.
    func scale(relativeTo base: Viewport) -> Double {
        size.x > 0 ? base.size.x / size.x : 1
    }

    func clamped() -> Viewport {
        clamped(within: .full)
    }

    /// Shrinks the viewport to fit inside `bounds` if needed and moves it so it never leaves them.
    func clamped(within bounds: Viewport) -> Viewport {
        var v = self
        let minSide = 0.01
        v.size = SIMD2(
            min(max(v.size.x, minSide), max(bounds.size.x, minSide)),
            min(max(v.size.y, minSide), max(bounds.size.y, minSide))
        )
        v.origin.x = min(max(v.origin.x, bounds.origin.x), bounds.origin.x + bounds.size.x - v.size.x)
        v.origin.y = min(max(v.origin.y, bounds.origin.y), bounds.origin.y + bounds.size.y - v.size.y)
        return v
    }

    static func lerp(_ a: Viewport, _ b: Viewport, _ t: Double) -> Viewport {
        let u = min(max(t, 0), 1)
        return Viewport(origin: a.origin + (b.origin - a.origin) * u, size: a.size + (b.size - a.size) * u).clamped()
    }

    var cgRect: CGRect { CGRect(x: origin.x, y: origin.y, width: size.x, height: size.y) }

    func contains(_ p: SIMD2<Double>) -> Bool {
        p.x >= origin.x && p.x <= maxX && p.y >= origin.y && p.y <= maxY
    }

    func isApproximatelyEqual(to other: Viewport, tolerance: Double = 1e-6) -> Bool {
        abs(origin.x - other.origin.x) < tolerance && abs(origin.y - other.origin.y) < tolerance
            && abs(size.x - other.size.x) < tolerance && abs(size.y - other.size.y) < tolerance
    }

    /// The largest viewport of pixel aspect `pixelAspect` (width / height in source pixels) that fits inside
    /// `bounds` of a source whose pixel size is `sourceSize`, centred in it.
    static func fitting(pixelAspect: Double, within bounds: Viewport, sourceSize: SIMD2<Double>) -> Viewport {
        let boundsPixelWidth = bounds.size.x * sourceSize.x
        let boundsPixelHeight = bounds.size.y * sourceSize.y
        guard boundsPixelWidth > 0, boundsPixelHeight > 0, pixelAspect > 0 else { return bounds }
        var widthPixels = boundsPixelWidth
        var heightPixels = widthPixels / pixelAspect
        if heightPixels > boundsPixelHeight {
            heightPixels = boundsPixelHeight
            widthPixels = heightPixels * pixelAspect
        }
        let size = SIMD2(widthPixels / sourceSize.x, heightPixels / sourceSize.y)
        return Viewport(origin: bounds.center - size / 2, size: size).clamped(within: bounds)
    }
}
