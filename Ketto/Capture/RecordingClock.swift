import Foundation
import CoreMedia
import os

/// The host-clock time (seconds) of the first captured video frame. Every track and every event is
/// expressed relative to this base so `screen.mov`, `mic.caf`, `system.caf` and `events.json` line up.
final class RecordingClock: Sendable {
    private let state = OSAllocatedUnfairLock<Double?>(initialState: nil)

    /// Returns the established base, setting it to `hostTime` if none exists yet.
    @discardableResult
    func establish(_ hostTime: Double) -> Double {
        state.withLock { base in
            if let base { return base }
            base = hostTime
            return hostTime
        }
    }

    var base: Double? { state.withLock { $0 } }

    /// The current host time in seconds, on the same clock as `CMSampleBuffer` timestamps and `NSEvent.timestamp`.
    static func now() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}
