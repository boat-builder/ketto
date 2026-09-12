import XCTest
@testable import Ketto

final class FramingTests: XCTestCase {
    private var source: SourceInfo { SourceInfo(display: Fixtures.display) }

    func testFitFramingUsesTheCrop() {
        var edit = EditDocument.default
        edit.crop = CropSpec(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let framing = FrameComposer.framing(edit: edit, source: source)
        XCTAssertEqual(framing.base, edit.crop.viewport)
        XCTAssertEqual(framing.bounds, edit.crop.viewport)
        XCTAssertEqual(framing.coverage, 1, accuracy: 1e-9)
        let composer = FrameComposer(edit: edit, events: Fixtures.demoEvents(), source: source)
        XCTAssertEqual(composer.state(at: 0.1).viewport, edit.crop.viewport)
        let expectedAspect = (0.5 * 3456) / (0.5 * 2234)
        XCTAssertEqual(composer.layout.contentRect.width / composer.layout.contentRect.height, expectedAspect, accuracy: 1e-6)
    }

    func testVerticalPresetFillsThePaddedCanvas() {
        var edit = EditDocument.default
        edit.applyCanvasPreset("9:16")
        XCTAssertEqual(edit.canvas.framing, .fill)
        XCTAssertEqual(edit.canvas.width, 1080)
        XCTAssertEqual(edit.canvas.height, 1920)
        let composer = FrameComposer(edit: edit, events: Fixtures.demoEvents(), source: source)
        let rect = composer.layout.contentRect
        XCTAssertEqual(rect.width, 1080 - 2 * 64, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 1920 - 2 * 64, accuracy: 1e-9)
        let base = composer.framing.base
        XCTAssertEqual(base.size.y, 1, accuracy: 1e-9, "full height of the recording")
        XCTAssertLessThan(base.size.x, 0.4, "a narrow slice of the width")
        let pixelAspect = (base.size.x * 3456) / (base.size.y * 2234)
        XCTAssertEqual(pixelAspect, rect.width / rect.height, accuracy: 1e-6, "the slice has the frame's aspect, so nothing is stretched")
        XCTAssertLessThan(composer.framing.coverage, 0.4)
    }

    func testIdleCameraFollowsTheCursorAndStaysInBounds() {
        let bounds = Viewport.full
        let size = SIMD2(0.3, 1.0)
        // The point of interest moves from the far left to the far right over 4 seconds and stays there.
        let track = FramingTrack.make(duration: 8, size: size, bounds: bounds) { t in
            SIMD2(min(t / 4, 1), 0.5)
        }
        let start = track.viewport(at: 0)
        XCTAssertEqual(start.origin.x, 0, accuracy: 1e-9)
        let end = track.viewport(at: 8)
        XCTAssertEqual(end.maxX, 1, accuracy: 1e-3)
        XCTAssertEqual(end.size, size)
        var previous = track.viewport(at: 0)
        var t = 0.0
        while t < 8 {
            t += 1 / 120
            let current = track.viewport(at: t)
            XCTAssertGreaterThanOrEqual(current.origin.x, previous.origin.x - 1e-9, "never moves backwards while the target moves forwards")
            XCTAssertLessThan(abs(current.origin.x - previous.origin.x), 0.02, "no jumps")
            XCTAssertGreaterThanOrEqual(current.origin.x, 0)
            XCTAssertLessThanOrEqual(current.maxX, 1 + 1e-9)
            previous = current
        }
    }

    func testIdleCameraIgnoresSmallMotion() {
        let track = FramingTrack.make(duration: 4, size: SIMD2(0.3, 1.0), bounds: .full) { t in
            SIMD2(0.5 + 0.03 * sin(t * 10), 0.5)
        }
        for t in stride(from: 0.0, through: 4.0, by: 0.1) {
            XCTAssertEqual(track.center(at: t).x, 0.5, accuracy: 1e-9, "motion inside the dead zone does not move the camera")
        }
    }

    /// The v2 acceptance criterion: a vertical export frames the action without re-targeting every zoom.
    func testVerticalExportKeepsEveryClickInView() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.applyCanvasPreset("9:16")
        let framing = FrameComposer.framing(edit: edit, source: source)
        edit.zooms = AutoZoomGenerator().generate(events: events, framing: framing)
        XCTAssertFalse(edit.zooms.isEmpty)
        let composer = FrameComposer(edit: edit, events: events, source: source)
        for click in events.clicks where click.phase == .down {
            let viewport = composer.state(at: click.t).viewport
            let normalised = click.position / source.size
            XCTAssertTrue(viewport.contains(normalised), "click at \(click.t) is outside the frame \(viewport)")
        }
        // Between clicks the camera follows the cursor, inside zooms and out: the demo cursor crosses most of
        // the screen between clusters, and the frame may lag it for a moment, never lose it.
        var inView = 0
        var samples = 0
        for t in stride(from: 0.0, through: events.duration, by: 0.1) {
            let state = composer.state(at: t)
            let cursor = composer.cursorTrack.position(at: t) / source.size
            samples += 1
            if state.viewport.contains(cursor) { inView += 1 }
        }
        XCTAssertGreaterThan(Double(inView) / Double(samples), 0.9, "cursor in view for \(inView) of \(samples) samples")
    }

    func testZoomHoldPansToKeepTheCursorInView() {
        // One zoom on a click at the left; the cursor then walks to the far right while the zoom holds.
        var events = Fixtures.demoEvents(duration: 10)
        events.clicks = [ClickEvent(t: 2, x: 600, y: 1100), ClickEvent(t: 2.1, x: 600, y: 1100, phase: .up)]
        events.cursor = []
        for i in 0...600 {
            let t = Double(i) / 60
            let x = t < 2 ? 600.0 : min(600 + (t - 2) * 700, 3300)
            events.cursor.append(CursorSample(t: t, x: x, y: 1100))
        }
        var edit = EditDocument.default
        edit.zooms = [Zoom(id: "z", start: 1.6, duration: 6, target: SIMD2(600.0 / 3456, 1100.0 / 2234), scale: 2.5)]
        let composer = FrameComposer(edit: edit, events: events, source: source)
        let fixedTimeline = ZoomTimeline(zooms: edit.zooms)
        // After the ramp-in (0.55 s) the hold sits on the click; the target is near the left edge, so the
        // viewport is clamped to it.
        let atClick = composer.state(at: 2.3).viewport
        XCTAssertEqual(atClick.center.x, fixedTimeline.viewport(at: 2.3).center.x, accuracy: 0.01)
        XCTAssertEqual(atClick.origin.x, 0, accuracy: 1e-9)
        let later = composer.state(at: 6).viewport
        XCTAssertGreaterThan(later.center.x, atClick.center.x + 0.2, "the hold panned right")
        XCTAssertEqual(later.scale, 2.5, accuracy: 1e-6, "without zooming out")
        XCTAssertTrue(later.contains(composer.cursorTrack.position(at: 6) / source.size))
        XCTAssertEqual(fixedTimeline.viewport(at: 6).center.x, atClick.center.x, accuracy: 0.01, "a timeline without a follow point holds still")
    }

    func testZoomsAreAttenuatedForNarrowFraming() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.applyCanvasPreset("9:16")
        let framing = FrameComposer.framing(edit: edit, source: source)
        let vertical = AutoZoomGenerator().generate(events: events, framing: framing)
        let landscape = AutoZoomGenerator().generate(events: events)
        XCTAssertLessThan(vertical[0].scale, landscape[0].scale)
        XCTAssertGreaterThan(vertical[0].scale, 1.2)
        XCTAssertEqual(ZoomFraming.full.attenuated(scale: 2), 2, accuracy: 1e-9)
    }

    func testZoomHoldKeepsBaseAspect() {
        let base = Viewport(origin: SIMD2(0.35, 0), size: SIMD2(0.3, 1))
        let hold = Viewport(center: SIMD2(0.95, 0.9), scale: 2, base: base, bounds: .full)
        XCTAssertEqual(hold.size.x, 0.15, accuracy: 1e-9)
        XCTAssertEqual(hold.size.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(hold.maxX, 1, accuracy: 1e-9, "clamped to the right edge")
        XCTAssertEqual(hold.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(hold.scale(relativeTo: base), 2, accuracy: 1e-9)
    }

    func testFittingViewportHasRequestedPixelAspect() {
        let sourceSize = SIMD2(3456.0, 2234.0)
        let fitted = Viewport.fitting(pixelAspect: 9.0 / 16.0, within: .full, sourceSize: sourceSize)
        XCTAssertEqual(fitted.size.y, 1, accuracy: 1e-9)
        XCTAssertEqual((fitted.size.x * sourceSize.x) / (fitted.size.y * sourceSize.y), 9.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(fitted.center.x, 0.5, accuracy: 1e-9)
        let wide = Viewport.fitting(pixelAspect: 4, within: .full, sourceSize: sourceSize)
        XCTAssertEqual(wide.size.x, 1, accuracy: 1e-9)
        XCTAssertLessThan(wide.size.y, 1)
    }

    func testCropSpecIsSanitised() {
        let crop = CropSpec(x: 0.9, y: -1, width: 0.5, height: 5)
        XCTAssertEqual(crop.width, 0.5)
        XCTAssertEqual(crop.height, 1)
        XCTAssertEqual(crop.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(crop.y, 0)
        XCTAssertFalse(crop.isFull)
        XCTAssertTrue(CropSpec.full.isFull)
    }

    func testClicksOutsideTheCropAreIgnored() {
        var events = Fixtures.demoEvents()
        events.clicks = [ClickEvent(t: 3, x: 100, y: 100)]
        let framing = ZoomFraming(base: CropSpec(x: 0.5, y: 0.5, width: 0.5, height: 0.5).viewport, bounds: CropSpec(x: 0.5, y: 0.5, width: 0.5, height: 0.5).viewport)
        XCTAssertTrue(AutoZoomGenerator().generate(events: events, framing: framing).isEmpty)
    }
}
