import XCTest
@testable import Recordito

final class CursorSmootherTests: XCTestCase {
    func testCursorIsPixelExactAtEveryClick() {
        let events = Fixtures.demoEvents()
        let track = CursorSmoother.smooth(events: events, parameters: CursorSmoothingParameters())
        for click in events.clicks {
            let p = track.position(at: click.t)
            XCTAssertEqual(p.x, click.x, accuracy: 1e-9, "x at t=\(click.t)")
            XCTAssertEqual(p.y, click.y, accuracy: 1e-9, "y at t=\(click.t)")
        }
    }

    func testCloseClicksAreAllExact() {
        var events = Fixtures.demoEvents()
        events.clicks = [
            ClickEvent(t: 3.00, x: 1000, y: 700, phase: .down),
            ClickEvent(t: 3.08, x: 1000, y: 700, phase: .up),
            ClickEvent(t: 3.15, x: 1004, y: 702, phase: .down),
            ClickEvent(t: 3.22, x: 1004, y: 702, phase: .up),
        ]
        let track = CursorSmoother.smooth(events: events, parameters: CursorSmoothingParameters())
        for click in events.clicks {
            let p = track.position(at: click.t)
            XCTAssertEqual(p.x, click.x, accuracy: 1e-9)
            XCTAssertEqual(p.y, click.y, accuracy: 1e-9)
        }
    }

    func testSmoothingReducesJitter() {
        var rng = SystemRandomNumberGenerator()
        var cursor: [CursorSample] = []
        for i in 0..<600 {
            let t = Double(i) / 120
            let jitterX = Double.random(in: -3...3, using: &rng)
            let jitterY = Double.random(in: -3...3, using: &rng)
            cursor.append(CursorSample(t: t, x: 400 + t * 300 + jitterX, y: 300 + t * 120 + jitterY))
        }
        let events = EventsDocument(recordingStart: 0, duration: 5, display: Fixtures.display, cursor: cursor)
        var params = CursorSmoothingParameters()
        params.smoothing = 0.8
        let smooth = CursorSmoother.smooth(events: events, parameters: params)
        params.smoothing = 0
        let raw = CursorSmoother.smooth(events: events, parameters: params)
        func roughness(_ track: CursorTrack) -> Double {
            var total = 0.0
            for i in 2..<track.frames.count {
                let second = track.frames[i] - 2 * track.frames[i - 1] + track.frames[i - 2]
                total += simd_length(second)
            }
            return total / Double(track.frames.count)
        }
        XCTAssertLessThan(roughness(smooth), roughness(raw) * 0.5)
        // The smoothed track still follows the line: check the midpoint is within a few pixels.
        let mid = smooth.position(at: 2.5)
        XCTAssertEqual(mid.x, 400 + 2.5 * 300, accuracy: 25)
        XCTAssertEqual(mid.y, 300 + 2.5 * 120, accuracy: 25)
    }

    func testCursorHoldsStillAcrossGapsInSamples() {
        let cursor = [
            CursorSample(t: 0.0, x: 100, y: 100),
            CursorSample(t: 0.5, x: 200, y: 100),
            CursorSample(t: 5.0, x: 210, y: 100), // 4.5 s with no events: the mouse did not move
            CursorSample(t: 5.1, x: 400, y: 100),
        ]
        let events = EventsDocument(recordingStart: 0, duration: 6, display: Fixtures.display, cursor: cursor)
        let track = CursorSmoother.smooth(events: events, parameters: CursorSmoothingParameters())
        let p = track.position(at: 2.5)
        XCTAssertEqual(p.x, 200, accuracy: 2)
        XCTAssertEqual(p.y, 100, accuracy: 1e-6)
    }

    func testIdleAutoHide() {
        let cursor = [
            CursorSample(t: 0.0, x: 100, y: 100),
            CursorSample(t: 0.5, x: 300, y: 100),
            CursorSample(t: 8.0, x: 500, y: 100),
            CursorSample(t: 8.5, x: 700, y: 100),
        ]
        let events = EventsDocument(recordingStart: 0, duration: 10, display: Fixtures.display, cursor: cursor)
        var params = CursorSmoothingParameters()
        let track = CursorSmoother.smooth(events: events, parameters: params)
        XCTAssertEqual(track.opacity(at: 0.3), 1)
        XCTAssertEqual(track.opacity(at: 1.0), 1)      // 0.5 s idle
        XCTAssertEqual(track.opacity(at: 4.0), 0)      // idle > 2.4 s
        XCTAssertEqual(track.opacity(at: 8.5), 1)      // moving again, faded back in
        XCTAssertGreaterThan(track.opacity(at: 8.05), 0)
        XCTAssertLessThan(track.opacity(at: 8.05), 1)
        params.hideWhenIdle = false
        let always = CursorSmoother.smooth(events: events, parameters: params)
        XCTAssertEqual(always.opacity(at: 4.0), 1)
    }

    func testCursorTypeFollowsSamples() {
        let cursor = [
            CursorSample(t: 0.0, x: 100, y: 100, type: .arrow),
            CursorSample(t: 1.0, x: 100, y: 100, type: .iBeam),
            CursorSample(t: 2.0, x: 100, y: 100, type: .pointingHand),
        ]
        let events = EventsDocument(recordingStart: 0, duration: 3, display: Fixtures.display, cursor: cursor)
        let track = CursorSmoother.smooth(events: events, parameters: CursorSmoothingParameters())
        XCTAssertEqual(track.cursorType(at: 0.5), .arrow)
        XCTAssertEqual(track.cursorType(at: 1.5), .iBeam)
        XCTAssertEqual(track.cursorType(at: 2.5), .pointingHand)
    }

    func testTimedSplineInterpolatesThroughPoints() {
        let spline = TimedSpline(points: [TimedPoint(t: 0, p: SIMD2(0, 0)), TimedPoint(t: 1, p: SIMD2(10, 0)), TimedPoint(t: 2, p: SIMD2(20, 10))])
        XCTAssertEqual(spline.position(at: 1).x, 10, accuracy: 1e-9)
        XCTAssertEqual(spline.position(at: -1).x, 0)
        XCTAssertEqual(spline.position(at: 5).y, 10)
        let mid = spline.position(at: 0.5)
        XCTAssertGreaterThan(mid.x, 0)
        XCTAssertLessThan(mid.x, 10)
    }
}
