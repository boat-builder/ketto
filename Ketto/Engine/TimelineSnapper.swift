import Foundation

/// Nearest-candidate snapping for timeline drags: the playhead, clip and block edges and click times pull a
/// dragged edge in when it comes within `tolerance` seconds.
struct TimelineSnapper: Equatable, Sendable {
    /// Sorted snap targets, in the same time base as the values being snapped.
    let candidates: [Double]
    let tolerance: Double

    init(candidates: [Double], tolerance: Double) {
        self.candidates = candidates.filter(\.isFinite).sorted()
        self.tolerance = max(0, tolerance)
    }

    /// The candidate closest to `t` if it is within tolerance, otherwise nil.
    func nearest(to t: Double) -> Double? {
        guard !candidates.isEmpty else { return nil }
        var lo = 0
        var hi = candidates.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if candidates[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var best: Double?
        for index in [lo - 1, lo, lo + 1] where index >= 0 && index < candidates.count {
            let candidate = candidates[index]
            let distance = abs(candidate - t)
            if distance <= tolerance, best == nil || distance < abs(best! - t) { best = candidate }
        }
        return best
    }

    /// `t` snapped to the nearest candidate within tolerance, or `t` itself.
    func snap(_ t: Double) -> Double {
        nearest(to: t) ?? t
    }

    /// Snaps a block by whichever of its edges is closest to a candidate, returning the adjusted start.
    func snapBlock(start: Double, duration: Double) -> Double {
        let startSnap = nearest(to: start).map { ($0, abs($0 - start)) }
        let endSnap = nearest(to: start + duration).map { ($0 - duration, abs($0 - (start + duration))) }
        switch (startSnap, endSnap) {
        case (nil, nil): return start
        case (let s?, nil): return s.0
        case (nil, let e?): return e.0
        case (let s?, let e?): return s.1 <= e.1 ? s.0 : e.0
        }
    }
}
