import XCTest
@testable import Recordito

final class AutoZoomGeneratorTests: XCTestCase {
    private func events(clicks: [ClickEvent], cursor: [CursorSample] = [], focus: [FocusEvent] = [], duration: Double = 30) -> EventsDocument {
        EventsDocument(recordingStart: 0, duration: duration, display: Fixtures.display, cursor: cursor, clicks: clicks, keys: [], focus: focus)
    }

    func testNoClicksProducesNoZooms() {
        XCTAssertTrue(AutoZoomGenerator().generate(events: events(clicks: [])).isEmpty)
    }

    func testTwoDistantClustersProduceTwoZooms() {
        let doc = events(clicks: [
            ClickEvent(t: 2.0, x: 1000, y: 800), ClickEvent(t: 2.5, x: 1050, y: 820),
            ClickEvent(t: 10.0, x: 2800, y: 1800),
        ])
        let zooms = AutoZoomGenerator().generate(events: doc)
        XCTAssertEqual(zooms.count, 2)
        XCTAssertEqual(zooms[0].start, 1.6, accuracy: 1e-6) // lead-in 0.4 s before the first click
        XCTAssertEqual(zooms[0].target.x, 1025.0 / 3456.0, accuracy: 0.01)
        XCTAssertEqual(zooms[0].target.y, 810.0 / 2234.0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(zooms[0].duration, 2.0)
        XCTAssertEqual(zooms[1].start, 9.6, accuracy: 1e-6)
        XCTAssertEqual(zooms[1].scale, 2.0, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(zooms[1].start, zooms[0].end + 0.5)
    }

    func testNearbyClicksInsideWindowJoinOneCluster() {
        let doc = events(clicks: [
            ClickEvent(t: 1.0, x: 1000, y: 800), ClickEvent(t: 2.0, x: 1100, y: 850), ClickEvent(t: 3.0, x: 1200, y: 900),
        ])
        let zooms = AutoZoomGenerator().generate(events: doc)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].end, 4.0, accuracy: 1e-6) // last click + lead-out 1.0
    }

    func testTargetIsClampedSoViewportStaysInsideSource() {
        let doc = events(clicks: [ClickEvent(t: 1.0, x: 10, y: 10)])
        let zooms = AutoZoomGenerator().generate(events: doc)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].target.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(zooms[0].target.y, 0.25, accuracy: 1e-6)
        let viewport = Viewport(center: zooms[0].target, scale: zooms[0].scale)
        XCTAssertGreaterThanOrEqual(viewport.origin.x, 0)
        XCTAssertGreaterThanOrEqual(viewport.origin.y, 0)
    }

    func testTargetIsConstrainedToFocusedWindow() {
        // Window occupies the right half of the display; the click lands in it, the cluster centroid is fine,
        // but a click outside is pulled to the window edge.
        let frame = CGRect(x: 1728, y: 0, width: 1728, height: 2234)
        let doc = events(clicks: [ClickEvent(t: 2.0, x: 1000, y: 1000)], focus: [FocusEvent(t: 0, bundleId: "x", frame: frame)])
        let zooms = AutoZoomGenerator().generate(events: doc)
        XCTAssertEqual(zooms.count, 1)
        let expectedMinX = (frame.minX + frame.width * 0.05) / 3456
        XCTAssertGreaterThanOrEqual(zooms[0].target.x, expectedMinX - 1e-6)
    }

    func testUserModifiedZoomsArePreservedAndNotOverlapped() {
        let doc = events(clicks: [ClickEvent(t: 5.0, x: 1000, y: 800), ClickEvent(t: 15.0, x: 2000, y: 1200)])
        let manual = Zoom(id: "mine", start: 4.0, duration: 4.0, target: SIMD2(0.5, 0.5), scale: 3, userModified: true)
        let zooms = AutoZoomGenerator().generate(events: doc, existing: [manual, Zoom(id: "old", start: 0, duration: 1, target: SIMD2(0.5, 0.5))])
        XCTAssertTrue(zooms.contains(manual))
        XCTAssertFalse(zooms.contains { $0.id == "old" })
        XCTAssertEqual(zooms.count, 2)
        for zoom in zooms where zoom.id != "mine" {
            XCTAssertTrue(zoom.start >= manual.end + 0.5 || zoom.end + 0.5 <= manual.start)
        }
    }

    func testTrailingClickIsIgnored() {
        let doc = events(clicks: [ClickEvent(t: 29.8, x: 1000, y: 800)], duration: 30)
        XCTAssertTrue(AutoZoomGenerator().generate(events: doc).isEmpty)
    }

    func testIntensityChangesScale() {
        let doc = events(clicks: [ClickEvent(t: 2.0, x: 1000, y: 800)])
        let strong = AutoZoomGenerator(parameters: AutoZoomParameters(intensity: 1.5)).generate(events: doc)
        let weak = AutoZoomGenerator(parameters: AutoZoomParameters(intensity: 0.5)).generate(events: doc)
        XCTAssertEqual(strong[0].scale, 2.5, accuracy: 1e-6)
        XCTAssertEqual(weak[0].scale, 1.5, accuracy: 1e-6)
    }

    func testTransitSuppressionDelaysZoomStart() {
        // Cursor flies across the display between t=1.0 and t=1.25 (fast, far), click lands at t=1.3.
        var cursor: [CursorSample] = []
        for i in 0...15 {
            let t = 1.0 + Double(i) / 60
            cursor.append(CursorSample(t: t, x: 200 + Double(i) * 200, y: 800))
        }
        let doc = events(clicks: [ClickEvent(t: 1.3, x: 3200, y: 800)], cursor: cursor)
        let generator = AutoZoomGenerator()
        let transit = generator.transitIntervals(events: doc)
        XCTAssertEqual(transit.count, 1)
        let zooms = generator.generate(events: doc)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertGreaterThan(zooms[0].start, 0.9) // plain lead-in would start at 0.9
        XCTAssertLessThanOrEqual(zooms[0].start, 1.3)
    }

    func testDeterministic() {
        let doc = Fixtures.demoEvents()
        let a = AutoZoomGenerator().generate(events: doc)
        let b = AutoZoomGenerator().generate(events: doc)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 2)
    }
}
