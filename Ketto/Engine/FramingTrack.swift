import Foundation

/// A camera that keeps a point of interest in view: the idle camera for `fill` framing (when the canvas shows
/// only a slice of the recording, the slice follows the action instead of sitting in the middle) and the
/// pan inside a zoom hold when the cursor heads for the edge. Deterministic and precomputed, so preview and
/// export see the same path.
///
/// The camera centre only moves when the point of interest leaves a dead zone in the middle of the view,
/// and then eases towards it, so small cursor motion never nudges the frame.
struct FramingTrack: Equatable, Sendable {
    struct Parameters: Equatable, Sendable {
        /// Sample rate of the precomputed path.
        var fps: Double = 20
        /// Fraction of the view (per axis) inside which the point of interest may move without the camera following.
        var deadZone: Double = 0.6
        /// Time constant of the ease towards the target, in seconds.
        var responsiveness: Double = 0.35

        init() {}

        init(fps: Double, deadZone: Double, responsiveness: Double) {
            self.fps = fps
            self.deadZone = deadZone
            self.responsiveness = responsiveness
        }
    }

    /// Source time of `centers[0]`.
    let startTime: Double
    let fps: Double
    /// Camera centres at `startTime + i / fps`, in normalised source coordinates.
    let centers: [SIMD2<Double>]
    let size: SIMD2<Double>
    let bounds: Viewport

    /// - Parameters:
    ///   - startTime: source time the path starts at; before it the first centre holds.
    ///   - duration: length of the path in seconds.
    ///   - size: size of the view in normalised source units.
    ///   - bounds: the crop; the view never leaves it.
    ///   - initialCenter: where the camera starts; defaults to the point of interest, then the centre of the bounds.
    ///   - pointOfInterest: the position the camera keeps in view at a given source time, normalised.
    static func make(
        startTime: Double = 0,
        duration: Double,
        size: SIMD2<Double>,
        bounds: Viewport,
        initialCenter: SIMD2<Double>? = nil,
        parameters: Parameters = Parameters(),
        pointOfInterest: (Double) -> SIMD2<Double>?
    ) -> FramingTrack {
        let fps = max(parameters.fps, 1)
        let dt = 1 / fps
        let count = max(1, Int((max(duration, 0) * fps).rounded(.up)) + 1)
        let half = size / 2
        let inner = half * min(max(parameters.deadZone, 0), 1)
        let alpha = 1 - exp(-dt / max(parameters.responsiveness, 1e-3))
        func clampCenter(_ c: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(
                min(max(c.x, bounds.origin.x + half.x), max(bounds.maxX - half.x, bounds.origin.x + half.x)),
                min(max(c.y, bounds.origin.y + half.y), max(bounds.maxY - half.y, bounds.origin.y + half.y))
            )
        }
        var center = clampCenter(initialCenter ?? pointOfInterest(startTime) ?? bounds.center)
        var centers = [SIMD2<Double>](repeating: center, count: count)
        for i in 0..<count {
            let t = startTime + Double(i) * dt
            if let p = pointOfInterest(t) {
                var target = center
                if p.x < center.x - inner.x { target.x = p.x + inner.x } else if p.x > center.x + inner.x { target.x = p.x - inner.x }
                if p.y < center.y - inner.y { target.y = p.y + inner.y } else if p.y > center.y + inner.y { target.y = p.y - inner.y }
                target = clampCenter(target)
                center += (target - center) * alpha
            }
            centers[i] = clampCenter(center)
        }
        return FramingTrack(startTime: startTime, fps: fps, centers: centers, size: size, bounds: bounds)
    }

    /// A camera that never moves.
    static func fixed(_ viewport: Viewport, bounds: Viewport) -> FramingTrack {
        FramingTrack(startTime: 0, fps: 1, centers: [viewport.center], size: viewport.size, bounds: bounds)
    }

    func center(at t: Double) -> SIMD2<Double> {
        guard !centers.isEmpty else { return bounds.center }
        let x = (t - startTime) * fps
        if x <= 0 { return centers[0] }
        let i = Int(x)
        if i >= centers.count - 1 { return centers[centers.count - 1] }
        let f = x - Double(i)
        return centers[i] + (centers[i + 1] - centers[i]) * f
    }

    func viewport(at t: Double) -> Viewport {
        let c = center(at: t)
        return Viewport(origin: c - size / 2, size: size).clamped(within: bounds)
    }
}
