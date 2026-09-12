import Foundation
import CoreGraphics

struct AutoZoomParameters: Equatable, Sendable {
    /// Clicks closer in time than this join the same cluster.
    var clusterWindow: Double = 1.5
    /// Clicks farther than this (in points) from the cluster centroid start a new cluster.
    var clusterRadiusPoints: Double = 300
    /// Seconds the zoom starts before the first click so it *arrives* as the user clicks.
    var leadIn: Double = 0.4
    /// Seconds the zoom holds after the last click.
    var leadOut: Double = 1.0
    var minDuration: Double = 2.0
    var maxDuration: Double = 12.0
    /// Minimum gap between consecutive zooms.
    var minGap: Double = 0.5
    /// Candidates closer than this fraction of the viewport are merged instead of trimmed.
    var mergeRadiusFraction: Double = 0.35
    /// Consecutive clusters with near-identical targets merge when the gap between them is shorter than this,
    /// so the camera holds rather than zooming out and straight back in.
    var closeTargetMergeGap: Double = 3.0
    /// Zoom factor at intensity 1.
    var baseScale: Double = 2.0
    var intensity: Double = 1.0
    /// Cursor speed (points/second) above which the user is considered "in transit".
    var transitSpeedPoints: Double = 2500
    var transitMinDistancePoints: Double = 600
    var transitMinDuration: Double = 0.15
    /// Clicks in the last part of the recording (typically the Stop button) are ignored.
    var ignoreTrailing: Double = 0.5
    /// Keep the target this fraction inside the focused window's bounds.
    var focusInsetFraction: Double = 0.05

    init() {}

    init(intensity: Double) {
        self.init()
        self.intensity = intensity
    }

    var zoomScale: Double {
        let scale = 1 + (baseScale - 1) * max(0, intensity)
        return min(max(scale, 1.15), 4)
    }
}

/// The view zooms are generated for: the base (un-zoomed) view and the crop they must stay inside.
/// With `fill` framing the base already shows a slice of the recording, so zooms are attenuated to keep the
/// hold from becoming a keyhole — that is what "re-optimised for the crop" means in practice.
struct ZoomFraming: Equatable, Sendable {
    var base: Viewport
    var bounds: Viewport

    static let full = ZoomFraming(base: .full, bounds: .full)

    init(base: Viewport, bounds: Viewport) {
        self.base = base
        self.bounds = bounds
    }

    /// Fraction of the crop the base view covers (1 when the whole crop is visible).
    var coverage: Double {
        let boundsArea = max(bounds.size.x * bounds.size.y, 1e-9)
        return min(max((base.size.x * base.size.y) / boundsArea, 0), 1)
    }

    /// The zoom factor to use so that `scale` on a fully visible recording and this framing feel alike.
    func attenuated(scale: Double) -> Double {
        let factor = coverage.squareRoot()
        return max(1, 1 + (scale - 1) * (0.5 + 0.5 * factor))
    }
}

/// Derives zoom blocks from the event track. Deterministic; never looks at pixels.
struct AutoZoomGenerator: Sendable {
    var parameters: AutoZoomParameters

    init(parameters: AutoZoomParameters = AutoZoomParameters()) {
        self.parameters = parameters
    }

    struct Candidate {
        var start: Double
        var end: Double
        var firstClick: Double
        var lastClick: Double
        var target: SIMD2<Double>   // normalised
        var clickCount: Int
    }

    struct Interval: Equatable {
        var start: Double
        var end: Double
    }

    /// Generates zooms. Zooms in `existing` flagged `userModified` are preserved verbatim and generated zooms
    /// never overlap them. Clicks outside the crop are ignored.
    func generate(events: EventsDocument, existing: [Zoom] = [], framing: ZoomFraming = .full) -> [Zoom] {
        let kept = existing.filter(\.userModified).sorted { $0.start < $1.start }
        let display = events.display
        let width = Double(max(display.width, 1))
        let height = Double(max(display.height, 1))
        let scaleFactor = max(display.scale, 0.01)
        let duration = events.duration
        let p = parameters
        let zoomScale = framing.attenuated(scale: p.zoomScale)
        let crop = framing.bounds

        // 1. Cluster clicks by time window and spatial radius.
        let downs = events.clicks
            .filter { $0.phase == .down && $0.t >= 0 && $0.t <= duration - p.ignoreTrailing }
            .filter { crop.contains(SIMD2($0.x / width, $0.y / height)) }
            .sorted { $0.t < $1.t }
        var clusters: [[ClickEvent]] = []
        var centroid = SIMD2<Double>.zero
        let radius = p.clusterRadiusPoints * scaleFactor
        for click in downs {
            if var current = clusters.last, let last = current.last,
               click.t - last.t <= p.clusterWindow, simd_length(click.position - centroid) <= radius {
                current.append(click)
                clusters[clusters.count - 1] = current
                centroid = current.reduce(SIMD2<Double>.zero) { $0 + $1.position } / Double(current.count)
            } else {
                clusters.append([click])
                centroid = click.position
            }
        }

        // 2–4. Candidates: centroid target, constrained to the focused window, with lead-in / lead-out.
        let transit = transitIntervals(events: events)
        var candidates: [Candidate] = []
        for cluster in clusters {
            guard let first = cluster.first, let last = cluster.last else { continue }
            var center = cluster.reduce(SIMD2<Double>.zero) { $0 + $1.position } / Double(cluster.count)
            if let frame = events.focus(at: first.t)?.rect {
                let inset = CGSize(width: frame.width * p.focusInsetFraction, height: frame.height * p.focusInsetFraction)
                let bounds = frame.insetBy(dx: inset.width, dy: inset.height)
                if bounds.width > 0, bounds.height > 0 {
                    center.x = min(max(center.x, bounds.minX), bounds.maxX)
                    center.y = min(max(center.y, bounds.minY), bounds.maxY)
                }
            }
            let target = Viewport(center: SIMD2(center.x / width, center.y / height), scale: zoomScale, base: framing.base, bounds: crop).center
            var start = max(0, first.t - p.leadIn)
            var end = last.t + p.leadOut
            // 6. Transit suppression.
            let span = Interval(start: start, end: end)
            let covered = transit.reduce(0.0) { $0 + overlap($1, span) }
            if covered > 0.5 * max(end - start, 1e-6) { continue }
            for interval in transit where interval.start < first.t && interval.end > start {
                start = min(max(start, interval.end - 0.1), first.t)
            }
            if end - start < p.minDuration { end = start + p.minDuration }
            if end - start > p.maxDuration { end = start + p.maxDuration }
            end = min(end, max(duration, start + 0.1))
            candidates.append(Candidate(start: start, end: end, firstClick: first.t, lastClick: last.t, target: target, clickCount: cluster.count))
        }

        // 5. Merge overlapping candidates; enforce minimum duration and gap.
        var merged: [Candidate] = []
        let mergeRadius = p.mergeRadiusFraction / zoomScale
        for candidate in candidates {
            var c = candidate
            guard var last = merged.last else { merged.append(c); continue }
            let targetsClose = simd_length(last.target - c.target) <= mergeRadius
            if c.start < last.end + (targetsClose ? p.closeTargetMergeGap : p.minGap) {
                if targetsClose {
                    let total = Double(last.clickCount + c.clickCount)
                    last.target = (last.target * Double(last.clickCount) + c.target * Double(c.clickCount)) / total
                    last.target = Viewport(center: last.target, scale: zoomScale, base: framing.base, bounds: crop).center
                    last.end = max(last.end, c.end)
                    last.lastClick = max(last.lastClick, c.lastClick)
                    last.clickCount += c.clickCount
                    if last.end - last.start > p.maxDuration { last.end = last.start + p.maxDuration }
                    merged[merged.count - 1] = last
                    continue
                }
                let trimmedEnd = c.start - p.minGap
                if trimmedEnd - last.start >= 0.6 * p.minDuration, trimmedEnd >= last.lastClick {
                    last.end = trimmedEnd
                    merged[merged.count - 1] = last
                } else {
                    c.start = last.end + p.minGap
                    if c.start > c.lastClick { continue }
                    if c.end - c.start < 0.6 * p.minDuration { c.end = min(c.start + 0.6 * p.minDuration, max(duration, c.start + 0.1)) }
                }
            }
            merged.append(c)
        }

        // Preserve user-modified zooms; drop generated candidates that would collide with them.
        var generated: [Zoom] = []
        for (index, c) in merged.enumerated() {
            let collides = kept.contains { z in c.start < z.end + p.minGap && z.start < c.end + p.minGap }
            if collides { continue }
            generated.append(Zoom(
                id: "auto-\(index + 1)",
                start: round(c.start, places: 3),
                duration: round(c.end - c.start, places: 3),
                target: SIMD2(round(c.target.x, places: 4), round(c.target.y, places: 4)),
                scale: round(zoomScale, places: 3),
                easing: .easeInOutCubic
            ))
        }
        return (kept + generated).sorted { $0.start < $1.start }
    }

    /// Intervals during which the cursor travels fast and far: the user is moving, not working.
    func transitIntervals(events: EventsDocument) -> [Interval] {
        let scaleFactor = max(events.display.scale, 0.01)
        let samples = events.cursor.sorted { $0.t < $1.t }
        guard samples.count >= 2 else { return [] }
        var result: [Interval] = []
        var current: Interval?
        var distance = 0.0
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            let dt = b.t - a.t
            guard dt > 0 else { continue }
            let step = simd_length(b.position - a.position) / scaleFactor
            let speed = step / dt
            if speed >= parameters.transitSpeedPoints {
                if current == nil { current = Interval(start: a.t, end: b.t); distance = 0 }
                current?.end = b.t
                distance += step
            } else if let interval = current {
                if interval.end - interval.start >= parameters.transitMinDuration, distance >= parameters.transitMinDistancePoints {
                    result.append(interval)
                }
                current = nil
            }
        }
        if let interval = current, interval.end - interval.start >= parameters.transitMinDuration, distance >= parameters.transitMinDistancePoints {
            result.append(interval)
        }
        return result
    }

    private func overlap(_ a: Interval, _ b: Interval) -> Double {
        max(0, min(a.end, b.end) - max(a.start, b.start))
    }

    private func round(_ value: Double, places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }
}
