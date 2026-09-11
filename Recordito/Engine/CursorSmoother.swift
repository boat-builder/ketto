import Foundation

struct CursorSmoothingParameters: Equatable, Sendable {
    /// Sample rate of the smoothed track.
    var fps: Double = 60
    /// 0 = raw positions, 1 = heavy smoothing (driven by `cursor.smoothing` in edit.json).
    var smoothing: Double = 0.8
    /// Half-width of the window over which a click pin is blended in, in seconds.
    var pinWindow: Double = 0.25
    /// Gaps between raw samples longer than this are treated as the cursor holding still.
    var holdGap: Double = 0.1
    /// Seconds without motion before the cursor starts fading out.
    var idleTimeout: Double = 2.0
    var fadeOutDuration: Double = 0.4
    var fadeInDuration: Double = 0.15
    var hideWhenIdle: Bool = true

    init() {}
}

/// A pin forces the smoothed track through `target` at exactly time `t`, blending the correction in over ±`window`.
struct CursorPin: Equatable, Sendable {
    var t: Double
    var target: SIMD2<Double>
    var window: Double
    var correction: SIMD2<Double>
}

/// The smoothed cursor track: positions resampled at `fps`, with click pins applied on evaluation.
struct CursorTrack: Sendable {
    let fps: Double
    let duration: Double
    /// Filtered positions at frame times i / fps (before pins).
    let frames: [SIMD2<Double>]
    let pins: [CursorPin]
    let types: [(t: Double, type: CursorType)]
    /// Times at which the cursor was moving or clicking, used for idle auto-hide.
    let activity: [Double]
    let parameters: CursorSmoothingParameters

    var isEmpty: Bool { frames.isEmpty }

    private func interpolatedFrame(at t: Double) -> SIMD2<Double> {
        guard !frames.isEmpty else { return .zero }
        let x = t * fps
        if x <= 0 { return frames[0] }
        let i = Int(x)
        if i >= frames.count - 1 { return frames[frames.count - 1] }
        let f = x - Double(i)
        return frames[i] + (frames[i + 1] - frames[i]) * f
    }

    /// Smoothed position in source pixels. Exactly equals the click position at each click time.
    func position(at t: Double) -> SIMD2<Double> {
        var p = interpolatedFrame(at: t)
        for pin in pins {
            let u = abs(t - pin.t) / max(pin.window, 1e-9)
            if u < 1 {
                let w = 0.5 * (1 + cos(Double.pi * u))
                p += pin.correction * w
            }
        }
        return p
    }

    func cursorType(at t: Double) -> CursorType {
        var result = CursorType.arrow
        for entry in types {
            if entry.t <= t { result = entry.type } else { break }
        }
        return result
    }

    /// Opacity of the cursor at `t`, implementing idle auto-hide with fades.
    func opacity(at t: Double) -> Double {
        guard parameters.hideWhenIdle, !activity.isEmpty else { return 1 }
        // Index of the last activity at or before t.
        var lo = 0
        var hi = activity.count - 1
        if activity[0] > t {
            // Nothing happened yet: treat the recording start as activity.
            let idle = t
            return Self.fadeOut(idle: idle, parameters: parameters)
        }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if activity[mid] <= t { lo = mid } else { hi = mid }
        }
        let index = activity[hi] <= t ? hi : lo
        let last = activity[index]
        let idle = t - last
        let base: Double
        if index > 0 {
            let gap = last - activity[index - 1]
            base = Self.fadeOut(idle: gap, parameters: parameters)
        } else {
            base = Self.fadeOut(idle: last, parameters: parameters)
        }
        let fadeIn = min(1, base + (1 - base) * min(1, idle / max(parameters.fadeInDuration, 1e-6)))
        let fadeOut = Self.fadeOut(idle: idle, parameters: parameters)
        return min(fadeIn, fadeOut)
    }

    private static func fadeOut(idle: Double, parameters: CursorSmoothingParameters) -> Double {
        guard idle > parameters.idleTimeout else { return 1 }
        let progress = (idle - parameters.idleTimeout) / max(parameters.fadeOutDuration, 1e-6)
        return max(0, 1 - progress)
    }
}

enum CursorSmoother {
    /// Builds the smoothed cursor track: spline through raw samples → resample at fps → one-euro filter → click pins.
    static func smooth(events: EventsDocument, parameters: CursorSmoothingParameters) -> CursorTrack {
        let duration = max(events.duration, 0)
        let samples = conditioned(samples: events.cursor, duration: duration, holdGap: parameters.holdGap)
        let frameCount = max(1, Int((duration * parameters.fps).rounded(.up)) + 1)
        let width = Double(max(events.display.width, 1))

        var frames = [SIMD2<Double>](repeating: .zero, count: frameCount)
        if !samples.isEmpty {
            let spline = TimedSpline(points: samples.map { TimedPoint(t: $0.t, p: $0.position) })
            let smoothing = min(max(parameters.smoothing, 0), 1)
            var filter = OneEuroFilter(
                minCutoff: 8.0 + (1.2 - 8.0) * smoothing,
                beta: 8.0 + (1.5 - 8.0) * smoothing
            )
            let dt = 1 / parameters.fps
            for i in 0..<frameCount {
                let t = Double(i) * dt
                let raw = spline.position(at: t)
                frames[i] = smoothing <= 0.001 ? raw : filter.filter(raw, dt: dt, speedScale: 1 / width)
            }
        }

        let types: [(t: Double, type: CursorType)] = {
            var result: [(Double, CursorType)] = []
            var last: CursorType?
            for sample in samples where sample.type != last {
                result.append((sample.t, sample.type))
                last = sample.type
            }
            return result.map { (t: $0.0, type: $0.1) }
        }()

        var track = CursorTrack(
            fps: parameters.fps, duration: duration, frames: frames, pins: [], types: types,
            activity: activityTimes(samples: samples, clicks: events.clicks), parameters: parameters
        )
        track = CursorTrack(
            fps: parameters.fps, duration: duration, frames: frames,
            pins: pins(for: events.clicks, track: track, window: parameters.pinWindow),
            types: types, activity: track.activity, parameters: parameters
        )
        return track
    }

    /// Sorts, dedupes and inserts hold points so that long gaps between samples read as "the cursor stayed put".
    static func conditioned(samples input: [CursorSample], duration: Double, holdGap: Double) -> [CursorSample] {
        let sorted = input.filter { $0.t.isFinite && $0.t >= -1 }.sorted { $0.t < $1.t }
        guard !sorted.isEmpty else { return [] }
        var result: [CursorSample] = []
        result.reserveCapacity(sorted.count + 16)
        if sorted[0].t > 0 {
            var first = sorted[0]
            first.t = 0
            result.append(first)
        }
        for sample in sorted {
            if let last = result.last {
                if sample.t - last.t < 1e-4 {
                    result[result.count - 1] = sample
                    continue
                }
                if sample.t - last.t > holdGap {
                    var hold = last
                    hold.t = sample.t - min(0.02, holdGap / 2)
                    result.append(hold)
                }
            }
            result.append(sample)
        }
        if let last = result.last, last.t < duration {
            var hold = last
            hold.t = duration
            result.append(hold)
        }
        return result
    }

    static func activityTimes(samples: [CursorSample], clicks: [ClickEvent]) -> [Double] {
        var times: [Double] = []
        var previous: CursorSample?
        for sample in samples {
            if let prev = previous, simd_length(sample.position - prev.position) > 1.0 {
                times.append(sample.t)
            }
            previous = sample
        }
        times.append(contentsOf: clicks.map(\.t))
        return times.sorted()
    }

    /// Pin the track at every click so the cursor is pixel-exact at the moment of the click.
    /// Windows are shrunk to half the distance to neighbouring pins so every pin stays exact.
    static func pins(for clicks: [ClickEvent], track: CursorTrack, window: Double) -> [CursorPin] {
        var unique: [(t: Double, p: SIMD2<Double>)] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) {
            if let last = unique.last, click.t - last.t < 1e-4 {
                unique[unique.count - 1] = (click.t, click.position)
            } else {
                unique.append((click.t, click.position))
            }
        }
        var result: [CursorPin] = []
        for (i, entry) in unique.enumerated() {
            var w = window
            if i > 0 { w = min(w, (entry.t - unique[i - 1].t) / 2) }
            if i + 1 < unique.count { w = min(w, (unique[i + 1].t - entry.t) / 2) }
            w = max(w, 1e-4)
            let correction = entry.p - track.position(at: entry.t)
            result.append(CursorPin(t: entry.t, target: entry.p, window: w, correction: correction))
        }
        return result
    }
}
