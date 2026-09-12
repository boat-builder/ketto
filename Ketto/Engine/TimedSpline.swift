import Foundation

struct TimedPoint: Equatable, Sendable {
    var t: Double
    var p: SIMD2<Double>
}

/// A cubic Hermite spline through time-stamped points (Catmull-Rom style tangents in the time domain),
/// which handles irregularly spaced samples. Tangents are limited to the slower adjacent chord so a hold
/// (two identical consecutive positions) never overshoots.
struct TimedSpline: Sendable {
    let points: [TimedPoint]
    let tangents: [SIMD2<Double>]

    init(points input: [TimedPoint]) {
        var pts: [TimedPoint] = []
        for point in input.sorted(by: { $0.t < $1.t }) {
            if let last = pts.last, point.t - last.t < 1e-6 {
                pts[pts.count - 1] = point
            } else {
                pts.append(point)
            }
        }
        self.points = pts
        var tangents = [SIMD2<Double>](repeating: .zero, count: pts.count)
        guard pts.count >= 2 else {
            self.tangents = tangents
            return
        }
        for i in pts.indices {
            let prev = pts[max(i - 1, 0)]
            let next = pts[min(i + 1, pts.count - 1)]
            let dt = next.t - prev.t
            guard dt > 0 else { continue }
            var m = (next.p - prev.p) / dt
            // Limit the tangent to 1.5x the slower adjacent chord speed to suppress overshoot.
            var limit = Double.infinity
            if i > 0 {
                let chord = pts[i].p - pts[i - 1].p
                let speed = simd_length(chord) / max(pts[i].t - pts[i - 1].t, 1e-6)
                limit = min(limit, speed)
            }
            if i + 1 < pts.count {
                let chord = pts[i + 1].p - pts[i].p
                let speed = simd_length(chord) / max(pts[i + 1].t - pts[i].t, 1e-6)
                limit = min(limit, speed)
            }
            let mSpeed = simd_length(m)
            if mSpeed > 1.5 * limit {
                m = limit.isFinite && limit > 0 ? m * (1.5 * limit / mSpeed) : .zero
            }
            tangents[i] = m
        }
        self.tangents = tangents
    }

    var startTime: Double { points.first?.t ?? 0 }
    var endTime: Double { points.last?.t ?? 0 }

    func position(at t: Double) -> SIMD2<Double> {
        guard let first = points.first, let last = points.last else { return .zero }
        if t <= first.t { return first.p }
        if t >= last.t { return last.p }
        // Binary search for the segment containing t.
        var lo = 0
        var hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].t <= t { lo = mid } else { hi = mid }
        }
        let p0 = points[lo], p1 = points[hi]
        let h = p1.t - p0.t
        guard h > 0 else { return p1.p }
        let s = (t - p0.t) / h
        let s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1
        let h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2
        let h11 = s3 - s2
        return h00 * p0.p + h10 * h * tangents[lo] + h01 * p1.p + h11 * h * tangents[hi]
    }
}
