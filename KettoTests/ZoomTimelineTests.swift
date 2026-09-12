import XCTest
@testable import Ketto

final class ZoomTimelineTests: XCTestCase {
    func testViewportRampsInHoldsAndRampsOut() {
        let zoom = Zoom(id: "a", start: 2, duration: 4, target: SIMD2(0.5, 0.5), scale: 2)
        let timeline = ZoomTimeline(zooms: [zoom])
        XCTAssertEqual(timeline.viewport(at: 0), .full)
        XCTAssertEqual(timeline.viewport(at: 1.99), .full)
        let hold = timeline.viewport(at: 4)
        XCTAssertEqual(hold.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(hold.center.x, 0.5, accuracy: 1e-9)
        let mid = timeline.viewport(at: 2.275)
        XCTAssertGreaterThan(mid.scale, 1.05)
        XCTAssertLessThan(mid.scale, 1.95)
        XCTAssertEqual(timeline.viewport(at: 6.0), .full)
        XCTAssertEqual(timeline.viewport(at: 10), .full)
    }

    func testMotionIsContinuous() {
        let zooms = [
            Zoom(id: "a", start: 1, duration: 3, target: SIMD2(0.3, 0.3), scale: 2),
            Zoom(id: "b", start: 4.6, duration: 3, target: SIMD2(0.7, 0.7), scale: 2.5),
            Zoom(id: "c", start: 12, duration: 2, target: SIMD2(0.5, 0.5), scale: 1.5),
        ]
        let timeline = ZoomTimeline(zooms: zooms)
        var previous = timeline.viewport(at: 0)
        var t = 0.0
        while t < 16 {
            t += 1.0 / 240
            let current = timeline.viewport(at: t)
            XCTAssertLessThan(simd_length(current.origin - previous.origin), 0.02, "jump at t=\(t)")
            XCTAssertLessThan(abs(current.size.x - previous.size.x), 0.02, "size jump at t=\(t)")
            previous = current
        }
    }

    func testCloseZoomsPanDirectlyInsteadOfZoomingOut() {
        let zooms = [
            Zoom(id: "a", start: 1, duration: 3, target: SIMD2(0.3, 0.3), scale: 2),
            Zoom(id: "b", start: 4.5, duration: 3, target: SIMD2(0.7, 0.7), scale: 2),
        ]
        let timeline = ZoomTimeline(zooms: zooms)
        let gap = timeline.viewport(at: 4.25)
        XCTAssertNotEqual(gap, .full)
        XCTAssertEqual(gap.scale, 2, accuracy: 1e-6)
        XCTAssertGreaterThan(gap.center.x, 0.3)
        XCTAssertLessThan(gap.center.x, 0.7)
    }

    func testFarApartZoomsReturnToFullView() {
        let zooms = [
            Zoom(id: "a", start: 1, duration: 3, target: SIMD2(0.3, 0.3), scale: 2),
            Zoom(id: "b", start: 8, duration: 3, target: SIMD2(0.7, 0.7), scale: 2),
        ]
        XCTAssertEqual(ZoomTimeline(zooms: zooms).viewport(at: 6), .full)
    }

    func testViewportClamping() {
        let v = Viewport(center: SIMD2(0.05, 0.95), scale: 2)
        XCTAssertEqual(v.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(v.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(v.size.x, 0.5, accuracy: 1e-9)
    }

    func testEasingEndpoints() {
        for easing in Easing.allCases {
            XCTAssertEqual(easing.apply(0), 0, accuracy: 1e-9, "\(easing)")
            XCTAssertEqual(easing.apply(1), 1, accuracy: 1e-9, "\(easing)")
            XCTAssertEqual(easing.apply(2), 1, accuracy: 1e-9)
        }
    }
}
