import Foundation

/// When the webcam overlay slides out of the cursor's way. Computed once per composer from the cursor path,
/// so the overlay's position is a pure function of time — preview and export agree, and scrubbing backwards
/// shows exactly what playing forwards showed.
struct CameraDodgeSchedule: Equatable, Sendable {
    struct Interval: Equatable, Sendable {
        var start: Double
        var end: Double
    }

    /// Source-time intervals during which the overlay sits on its alternate side. Sorted, non-overlapping,
    /// and separated by more than `blend`.
    let intervals: [Interval]
    /// Seconds the slide between the two positions takes.
    let blend: Double

    static let empty = CameraDodgeSchedule(intervals: [], blend: 0.35)

    /// Samples `shouldDodge` at `sampleRate` over `duration`, starts each dodge `leadIn` seconds early so
    /// the overlay is out of the way when the cursor arrives, merges dodges closer than `mergeGap`, and drops
    /// blips shorter than `minimumLength`.
    static func make(
        duration: Double,
        sampleRate: Double = 8,
        leadIn: Double = 0.3,
        mergeGap: Double = 0.8,
        minimumLength: Double = 0.15,
        blend: Double = 0.35,
        shouldDodge: (Double) -> Bool
    ) -> CameraDodgeSchedule {
        let rate = max(sampleRate, 1)
        let count = max(0, Int((max(duration, 0) * rate).rounded(.up)) + 1)
        var raw: [Interval] = []
        var current: Interval?
        for i in 0..<count {
            let t = Double(i) / rate
            if shouldDodge(t) {
                if current == nil { current = Interval(start: t, end: t) }
                current?.end = t + 1 / rate
            } else if let interval = current {
                raw.append(interval)
                current = nil
            }
        }
        if let interval = current { raw.append(interval) }

        var merged: [Interval] = []
        for interval in raw {
            var shifted = interval
            shifted.start = max(0, interval.start - leadIn)
            if var last = merged.last, shifted.start - last.end < max(mergeGap, blend + 0.05) {
                last.end = max(last.end, shifted.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(shifted)
            }
        }
        return CameraDodgeSchedule(intervals: merged.filter { $0.end - $0.start >= minimumLength }, blend: blend)
    }

    /// 0 = home position, 1 = alternate position, eased in between.
    func progress(at t: Double) -> Double {
        var result = 0.0
        for interval in intervals {
            if t < interval.start - 1e-9 { break }
            let value: Double
            if t < interval.start + blend {
                value = Easing.easeInOutCubic.apply((t - interval.start) / max(blend, 1e-6))
            } else if t < interval.end {
                value = 1
            } else if t < interval.end + blend {
                value = 1 - Easing.easeInOutCubic.apply((t - interval.end) / max(blend, 1e-6))
            } else {
                value = 0
            }
            result = max(result, value)
        }
        return result
    }
}
