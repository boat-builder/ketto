import Foundation

/// Turns zoom blocks into a continuous camera path: `viewport(at:)` is the visible source rectangle at time `t`.
/// Zooms ease in from the full view, hold, and ease back out. Consecutive zooms closer than `panThreshold`
/// pan directly between targets instead of zooming out and back in.
struct ZoomTimeline: Sendable {
    struct Segment: Equatable, Sendable {
        var start: Double
        var end: Double
        var hold: Viewport
        var easing: Easing
        var duration: Double { end - start }
    }

    let segments: [Segment]
    var transition: Double = 0.55
    var panThreshold: Double = 1.2

    init(zooms: [Zoom], transition: Double = 0.55, panThreshold: Double = 1.2) {
        self.transition = transition
        self.panThreshold = panThreshold
        var segments: [Segment] = []
        for zoom in zooms.sorted(by: { $0.start < $1.start }) where zoom.duration > 0.01 && zoom.scale > 1.001 {
            var start = zoom.start
            if let last = segments.last, start < last.end { start = last.end }
            guard zoom.end - start > 0.01 else { continue }
            segments.append(Segment(start: start, end: zoom.end, hold: Viewport(center: zoom.target, scale: zoom.scale), easing: zoom.easing))
        }
        self.segments = segments
    }

    static let identity = ZoomTimeline(zooms: [])

    private func rampDuration(_ segment: Segment) -> Double {
        min(transition, segment.duration / 2)
    }

    func viewport(at t: Double) -> Viewport {
        guard !segments.isEmpty else { return .full }
        if let i = segments.firstIndex(where: { t >= $0.start && t < $0.end }) {
            let seg = segments[i]
            let ramp = rampDuration(seg)
            let prev = i > 0 ? segments[i - 1] : nil
            let next = i + 1 < segments.count ? segments[i + 1] : nil
            if t < seg.start + ramp {
                if let prev, seg.start - prev.end < panThreshold {
                    let ws = prev.end - rampDuration(prev)
                    let we = seg.start + ramp
                    return Viewport.lerp(prev.hold, seg.hold, seg.easing.apply((t - ws) / max(we - ws, 1e-6)))
                }
                return Viewport.lerp(.full, seg.hold, seg.easing.apply((t - seg.start) / max(ramp, 1e-6)))
            }
            if t > seg.end - ramp {
                if let next, next.start - seg.end < panThreshold {
                    let ws = seg.end - ramp
                    let we = next.start + rampDuration(next)
                    return Viewport.lerp(seg.hold, next.hold, next.easing.apply((t - ws) / max(we - ws, 1e-6)))
                }
                return Viewport.lerp(seg.hold, .full, seg.easing.apply((t - (seg.end - ramp)) / max(ramp, 1e-6)))
            }
            return seg.hold
        }
        guard let prevIndex = segments.lastIndex(where: { $0.end <= t }) else { return .full }
        let prev = segments[prevIndex]
        if prevIndex + 1 < segments.count {
            let next = segments[prevIndex + 1]
            if next.start - prev.end < panThreshold {
                let ws = prev.end - rampDuration(prev)
                let we = next.start + rampDuration(next)
                return Viewport.lerp(prev.hold, next.hold, next.easing.apply((t - ws) / max(we - ws, 1e-6)))
            }
        }
        return .full
    }
}
