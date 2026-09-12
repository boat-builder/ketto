import Foundation
import CoreMedia
import os

/// The shared time base of a recording: host-clock seconds of the first captured video frame, plus the
/// pauses taken since. Every track and every event is expressed in *recording time* — seconds since the first
/// frame with pauses removed — so `screen.mov`, `mic.caf`, `system.caf`, `camera.mov` and `events.json` line
/// up, and a paused recording still ends up in one continuous file.
final class RecordingClock: Sendable {
    private struct Pause: Equatable {
        var start: Double
        var end: Double?
    }

    private struct State {
        var base: Double?
        var pauses: [Pause] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Returns the established base, setting it to `hostTime` if none exists yet.
    @discardableResult
    func establish(_ hostTime: Double) -> Double {
        state.withLock { state in
            if let base = state.base { return base }
            state.base = hostTime
            return hostTime
        }
    }

    var base: Double? { state.withLock { $0.base } }

    var isPaused: Bool { state.withLock { $0.pauses.last?.end == nil && !$0.pauses.isEmpty } }

    /// Starts a pause at `hostTime`. Samples and events timestamped inside a pause are dropped by the writers.
    func pause(at hostTime: Double = RecordingClock.now()) {
        state.withLock { state in
            guard state.pauses.last?.end != nil || state.pauses.isEmpty else { return }
            state.pauses.append(Pause(start: hostTime, end: nil))
        }
    }

    /// Ends the current pause at `hostTime`.
    func resume(at hostTime: Double = RecordingClock.now()) {
        state.withLock { state in
            guard let last = state.pauses.last, last.end == nil else { return }
            state.pauses[state.pauses.count - 1].end = max(hostTime, last.start)
        }
    }

    /// Seconds spent paused up to `hostTime` (an open pause counts up to `hostTime`).
    func pausedDuration(before hostTime: Double) -> Double {
        state.withLock { state in
            var total = 0.0
            for pause in state.pauses where pause.start < hostTime {
                total += min(pause.end ?? hostTime, hostTime) - pause.start
            }
            return total
        }
    }

    /// Recording time of a host time: seconds since the base with completed pauses removed. Nil when the
    /// host time falls inside a pause (the sample belongs to nothing) or before the base was established.
    /// Times before the base map to negative values so audio writers can trim them.
    func recordingTime(forHost hostTime: Double) -> Double? {
        state.withLock { state in
            guard let base = state.base else { return nil }
            var paused = 0.0
            for pause in state.pauses {
                if hostTime < pause.start { break }
                guard let end = pause.end, hostTime >= end else { return nil }
                paused += end - pause.start
            }
            return hostTime - base - paused
        }
    }

    /// The recording time that has elapsed at `hostTime`, counting a pause in progress as ended right now.
    /// What the HUD shows, and the length of the recording when it stops.
    func elapsedRecordingTime(at hostTime: Double = RecordingClock.now()) -> Double {
        guard let base else { return 0 }
        return max(0, hostTime - base - pausedDuration(before: hostTime))
    }

    /// The current host time in seconds, on the same clock as `CMSampleBuffer` timestamps and `NSEvent.timestamp`.
    static func now() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}
