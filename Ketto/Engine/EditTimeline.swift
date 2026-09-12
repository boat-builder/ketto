import Foundation

/// The edited (output) timeline laid over the recording (source): which source ranges play, in what order and
/// at what speed. Everything that refers to recorded content — zooms, masks, clicks, the cursor — stays in
/// source seconds; the player, the exporter and the timeline UI speak output seconds and convert through here.
struct EditTimeline: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        var clipID: String
        var sourceStart: Double
        var sourceEnd: Double
        var speed: Double
        var outputStart: Double
        var outputEnd: Double

        var sourceDuration: Double { sourceEnd - sourceStart }
        var outputDuration: Double { outputEnd - outputStart }

        func sourceTime(forOutput t: Double) -> Double {
            sourceStart + (t - outputStart) * speed
        }

        func outputTime(forSource t: Double) -> Double {
            outputStart + (t - sourceStart) / speed
        }

        func containsOutput(_ t: Double) -> Bool { t >= outputStart && t < outputEnd }
        func containsSource(_ t: Double) -> Bool { t >= sourceStart && t < sourceEnd }
    }

    let segments: [Segment]
    let sourceDuration: Double

    /// Builds the timeline from already resolved clips (see `EditDocument.resolvedClips(sourceDuration:)`).
    init(clips: [Clip], sourceDuration: Double) {
        self.sourceDuration = max(0, sourceDuration)
        var segments: [Segment] = []
        var cursor = 0.0
        for clip in clips where clip.sourceEnd - clip.sourceStart > 1e-6 {
            let duration = (clip.sourceEnd - clip.sourceStart) / clip.speed
            segments.append(Segment(
                clipID: clip.id,
                sourceStart: clip.sourceStart,
                sourceEnd: clip.sourceEnd,
                speed: clip.speed,
                outputStart: cursor,
                outputEnd: cursor + duration
            ))
            cursor += duration
        }
        self.segments = segments
    }

    init(edit: EditDocument, sourceDuration: Double) {
        self.init(clips: edit.resolvedClips(sourceDuration: sourceDuration), sourceDuration: sourceDuration)
    }

    /// The whole recording at 1×.
    static func identity(duration: Double) -> EditTimeline {
        EditTimeline(clips: [Clip(id: Clip.mainID, sourceStart: 0, sourceEnd: max(0, duration))], sourceDuration: duration)
    }

    var outputDuration: Double { segments.last?.outputEnd ?? 0 }

    /// True when output time equals source time everywhere.
    var isIdentity: Bool {
        guard segments.count == 1, let only = segments.first else { return segments.isEmpty }
        return only.sourceStart == 0 && abs(only.sourceEnd - sourceDuration) < 1e-9 && only.speed == 1
    }

    func segmentIndex(atOutput t: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        if t < 0 { return 0 }
        if let i = segments.firstIndex(where: { $0.containsOutput(t) }) { return i }
        return segments.count - 1
    }

    func segment(atOutput t: Double) -> Segment? {
        segmentIndex(atOutput: t).map { segments[$0] }
    }

    /// The source time shown at output time `t`. Times past the end hold the last frame.
    func sourceTime(forOutput t: Double) -> Double {
        guard let segment = segment(atOutput: t) else { return min(max(t, 0), sourceDuration) }
        let clampedOutput = min(max(t, segment.outputStart), segment.outputEnd)
        return min(max(segment.sourceTime(forOutput: clampedOutput), segment.sourceStart), segment.sourceEnd)
    }

    /// The output time at which source time `t` appears. A time inside a cut maps to the point where the cut
    /// happens on the output timeline, so markers never vanish.
    func outputTime(forSource t: Double) -> Double {
        guard let first = segments.first else { return min(max(t, 0), sourceDuration) }
        if t < first.sourceStart { return first.outputStart }
        for (index, segment) in segments.enumerated() {
            if segment.containsSource(t) || (index == segments.count - 1 && abs(t - segment.sourceEnd) < 1e-9) {
                return segment.outputTime(forSource: t)
            }
            if t < segment.sourceStart { return segment.outputStart }
        }
        // Past the last segment, or inside a trailing cut.
        if let last = segments.last, t >= last.sourceEnd { return last.outputEnd }
        return outputDuration
    }

    func isVisible(sourceTime t: Double) -> Bool {
        segments.contains { $0.containsSource(t) }
    }

    /// The output range covered by a source range, or nil when it lies entirely inside cuts.
    func outputRange(sourceStart: Double, sourceEnd: Double) -> ClosedRange<Double>? {
        guard sourceEnd > sourceStart else { return nil }
        var lower = Double.infinity
        var upper = -Double.infinity
        for segment in segments {
            let start = max(sourceStart, segment.sourceStart)
            let end = min(sourceEnd, segment.sourceEnd)
            guard end > start else { continue }
            lower = min(lower, segment.outputTime(forSource: start))
            upper = max(upper, segment.outputTime(forSource: end))
        }
        guard lower.isFinite, upper.isFinite, upper > lower else { return nil }
        return lower...upper
    }

    /// The speed in effect at output time `t` (1 when there is no content).
    func speed(atOutput t: Double) -> Double {
        segment(atOutput: t)?.speed ?? 1
    }

    /// The source ranges that are *not* played, in order — the v1 `cuts` view of this timeline.
    var cuts: [Cut] {
        var result: [Cut] = []
        var cursor = 0.0
        for segment in segments {
            if segment.sourceStart > cursor + 1e-6 { result.append(Cut(start: cursor, end: segment.sourceStart)) }
            cursor = max(cursor, segment.sourceEnd)
        }
        if cursor < sourceDuration - 1e-6 { result.append(Cut(start: cursor, end: sourceDuration)) }
        return result
    }
}

extension Clip {
    /// The id of the single clip a fresh recording starts with.
    static let mainID = "main"
}

extension EditDocument {
    /// The clips that make up the main track, in order, sanitised: clamped to the recording, non-overlapping,
    /// with empty ones dropped. Without explicit clips the v1 `cuts` are honoured; without either the whole
    /// recording plays at 1×.
    func resolvedClips(sourceDuration: Double) -> [Clip] {
        let duration = max(0, sourceDuration)
        if !clips.isEmpty {
            var result: [Clip] = []
            var previousEnd = 0.0
            for clip in clips.sorted(by: { $0.sourceStart < $1.sourceStart }) {
                // Clips past the known duration are kept when the duration is unknown (0), clamped otherwise.
                let limit = duration > 0 ? duration : Double.greatestFiniteMagnitude
                let start = min(max(clip.sourceStart, previousEnd), limit)
                let end = min(max(clip.sourceEnd, start), limit)
                guard end - start >= Clip.minimumDuration else { continue }
                result.append(Clip(id: clip.id, sourceStart: start, sourceEnd: end, speed: clip.speed))
                previousEnd = end
            }
            if !result.isEmpty { return result }
        }
        if !cuts.isEmpty, duration > 0 {
            var result: [Clip] = []
            var cursor = 0.0
            var index = 1
            for cut in cuts.sorted(by: { $0.start < $1.start }) {
                let start = min(max(cut.start, 0), duration)
                let end = min(max(cut.end, start), duration)
                if start - cursor >= Clip.minimumDuration {
                    result.append(Clip(id: index == 1 ? Clip.mainID : "\(Clip.mainID)-\(index)", sourceStart: cursor, sourceEnd: start))
                    index += 1
                }
                cursor = max(cursor, end)
            }
            if duration - cursor >= Clip.minimumDuration {
                result.append(Clip(id: index == 1 ? Clip.mainID : "\(Clip.mainID)-\(index)", sourceStart: cursor, sourceEnd: duration))
            }
            if !result.isEmpty { return result }
        }
        return [Clip(id: Clip.mainID, sourceStart: 0, sourceEnd: duration)]
    }

    func timeline(sourceDuration: Double) -> EditTimeline {
        EditTimeline(edit: self, sourceDuration: sourceDuration)
    }
}
