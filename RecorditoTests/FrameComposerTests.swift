import XCTest
@testable import Recordito

final class FrameComposerTests: XCTestCase {
    func testLayoutFitsSourceAspectInsidePadding() {
        let layout = CanvasLayout.compute(canvas: .default, style: .default, sourceAspect: 3456.0 / 2234.0)
        let aspect = 3456.0 / 2234.0
        XCTAssertEqual(layout.contentRect.height, 1080 - 128, accuracy: 1e-9)
        XCTAssertEqual(layout.contentRect.width, (1080 - 128) * aspect, accuracy: 1e-9)
        XCTAssertEqual(layout.contentRect.minX, (1920 - (1080 - 128) * aspect) / 2, accuracy: 1e-9)
        XCTAssertEqual(layout.contentRect.width / layout.contentRect.height, 3456.0 / 2234.0, accuracy: 1e-9)
        XCTAssertEqual(layout.contentRect.midY, 540, accuracy: 1e-9)
    }

    func testCursorLandsAtClickPositionOnCanvas() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        let composer = FrameComposer(edit: edit, events: events, source: SourceInfo(display: events.display))
        let click = events.clicks[0]
        let state = composer.state(at: click.t)
        let expected = composer.canvasPoint(fromSource: click.position, viewport: state.viewport)
        XCTAssertEqual(state.cursor?.position.x ?? -1, expected.x, accuracy: 1e-6)
        XCTAssertEqual(state.cursor?.position.y ?? -1, expected.y, accuracy: 1e-6)
        XCTAssertTrue(state.layout.contentRect.contains(CGPoint(x: expected.x, y: expected.y)))
        XCTAssertGreaterThan(state.viewport.scale, 1.5, "auto zoom should be holding at the first click")
        XCTAssertFalse(state.ripples.isEmpty)
        XCTAssertEqual(state.cursor?.opacity, 1)
    }

    func testDisablingAutoZoomYieldsFullViewport() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        edit.autoZoom.enabled = false
        let composer = FrameComposer(edit: edit, events: events, source: SourceInfo(display: events.display))
        XCTAssertEqual(composer.state(at: events.clicks[0].t).viewport, .full)
    }

    func testStateIsDeterministic() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        let a = FrameComposer(edit: edit, events: events, source: SourceInfo(display: events.display))
        let b = FrameComposer(edit: edit, events: events, source: SourceInfo(display: events.display))
        for t in stride(from: 0.0, through: 20.0, by: 0.37) {
            XCTAssertEqual(a.state(at: t), b.state(at: t))
        }
    }
}
