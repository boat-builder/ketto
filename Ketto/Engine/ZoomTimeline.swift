import Foundation

/// Turns zoom blocks into a continuous camera path: `viewport(at:)` is the visible source rectangle at source
/// time `t`. Zooms ease in from the base view, hold, and ease back out. Consecutive zooms closer than
/// `panThreshold` pan directly between targets instead of zooming out and back in.
///
/// The base view is `.full` for a plain 16:9 edit; with a crop it is the crop, and with `fill` framing it is
/// the moving slice supplied by a `FramingTrack`. Zoom holds are sized relative to the base, so a 2× zoom
/// always shows half the base view on each axis. When a `follow` point is supplied, a hold pans to keep it in
/// view instead of letting the cursor walk out of the frame.
struct ZoomTimeline: Sendable {
    struct Segment: Sendable {
        var start: Double
        var end: Double
        var hold: Viewport
        var easing: Easing
        /// The hold's pan within the zoom, when following is on.
        var path: FramingTrack?
        var duration: Double { end - start }

        func hold(at t: Double) -> Viewport {
            path?.viewport(at: t) ?? hold
        }
    }

    let segments: [Segment]
    let base: Viewport
    let bounds: Viewport
    let framing: FramingTrack?
    var transition: Double = 0.55
    var panThreshold: Double = 1.2

    init(zooms: [Zoom], transition: Double = 0.55, panThreshold: Double = 1.2) {
        self.init(zooms: zooms, base: .full, bounds: .full, framing: nil, transition: transition, panThreshold: panThreshold, follow: nil)
    }

    /// - Parameter follow: the point (normalised source coordinates) a zoom hold keeps in view — the cursor.
    init(zooms: [Zoom], base: Viewport, bounds: Viewport, framing: FramingTrack?, transition: Double = 0.55, panThreshold: Double = 1.2, follow: ((Double) -> SIMD2<Double>?)? = nil) {
        self.base = base
        self.bounds = bounds
        self.framing = framing
        self.transition = transition
        self.panThreshold = panThreshold
        var segments: [Segment] = []
        for zoom in zooms.sorted(by: { $0.start < $1.start }) where zoom.duration > 0.01 && zoom.scale > 1.001 {
            var start = zoom.start
            if let last = segments.last, start < last.end { start = last.end }
            guard zoom.end - start > 0.01 else { continue }
            let hold = Viewport(center: zoom.target, scale: zoom.scale, base: base, bounds: bounds)
            var path: FramingTrack?
            if let follow {
                path = FramingTrack.make(startTime: start, duration: zoom.end - start, size: hold.size, bounds: bounds, initialCenter: hold.center, pointOfInterest: follow)
            }
            segments.append(Segment(start: start, end: zoom.end, hold: hold, easing: zoom.easing, path: path))
        }
        self.segments = segments
    }

    static let identity = ZoomTimeline(zooms: [])

    /// A timeline with no zooms that still follows the base view (the idle camera in `fill` framing).
    static func identity(base: Viewport, bounds: Viewport, framing: FramingTrack?) -> ZoomTimeline {
        ZoomTimeline(zooms: [], base: base, bounds: bounds, framing: framing)
    }

    /// The un-zoomed view at `t`.
    func full(at t: Double) -> Viewport {
        framing?.viewport(at: t) ?? base
    }

    private func rampDuration(_ segment: Segment) -> Double {
        min(transition, segment.duration / 2)
    }

    func viewport(at t: Double) -> Viewport {
        guard !segments.isEmpty else { return full(at: t) }
        if let i = segments.firstIndex(where: { t >= $0.start && t < $0.end }) {
            let seg = segments[i]
            let ramp = rampDuration(seg)
            let prev = i > 0 ? segments[i - 1] : nil
            let next = i + 1 < segments.count ? segments[i + 1] : nil
            if t < seg.start + ramp {
                if let prev, seg.start - prev.end < panThreshold {
                    let ws = prev.end - rampDuration(prev)
                    let we = seg.start + ramp
                    return Viewport.lerp(prev.hold(at: t), seg.hold(at: t), seg.easing.apply((t - ws) / max(we - ws, 1e-6)))
                }
                return Viewport.lerp(full(at: t), seg.hold(at: t), seg.easing.apply((t - seg.start) / max(ramp, 1e-6)))
            }
            if t > seg.end - ramp {
                if let next, next.start - seg.end < panThreshold {
                    let ws = seg.end - ramp
                    let we = next.start + rampDuration(next)
                    return Viewport.lerp(seg.hold(at: t), next.hold(at: t), next.easing.apply((t - ws) / max(we - ws, 1e-6)))
                }
                return Viewport.lerp(seg.hold(at: t), full(at: t), seg.easing.apply((t - (seg.end - ramp)) / max(ramp, 1e-6)))
            }
            return seg.hold(at: t)
        }
        guard let prevIndex = segments.lastIndex(where: { $0.end <= t }) else { return full(at: t) }
        let prev = segments[prevIndex]
        if prevIndex + 1 < segments.count {
            let next = segments[prevIndex + 1]
            if next.start - prev.end < panThreshold {
                let ws = prev.end - rampDuration(prev)
                let we = next.start + rampDuration(next)
                return Viewport.lerp(prev.hold(at: t), next.hold(at: t), next.easing.apply((t - ws) / max(we - ws, 1e-6)))
            }
        }
        return full(at: t)
    }
}
