import XCTest
@testable import Ketto

final class ComposerV2Tests: XCTestCase {
    private var source: SourceInfo { SourceInfo(display: Fixtures.display) }

    func testCutsMapOutputTimeToSourceTime() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        edit.clips = [Clip(id: "a", sourceStart: 0, sourceEnd: 2), Clip(id: "b", sourceStart: 6, sourceEnd: 20)]
        let composer = FrameComposer(edit: edit, events: events, source: source)
        XCTAssertEqual(composer.duration, 16, accuracy: 1e-9)
        let state = composer.state(at: 2.2)
        XCTAssertEqual(state.sourceTime, 6.2, accuracy: 1e-9)
        let reference = FrameComposer(edit: { var e = edit; e.clips = []; return e }(), events: events, source: source).state(at: 6.2)
        XCTAssertEqual(state.viewport, reference.viewport)
        XCTAssertEqual(state.cursor, reference.cursor)
        // The frame right after the cut has no motion to blur.
        let first = composer.state(at: 2.0, fps: 60)
        XCTAssertEqual(first.previousViewport, first.viewport)
    }

    func testSpeedRampKeepsCursorPinnedAtClicks() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.clips = [Clip(id: "a", sourceStart: 0, sourceEnd: 20, speed: 2)]
        let composer = FrameComposer(edit: edit, events: events, source: source)
        let click = events.clicks[0]
        let state = composer.state(at: click.t / 2)
        let expected = composer.canvasPoint(fromSource: click.position, viewport: state.viewport)
        XCTAssertEqual(state.cursor!.position.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(state.cursor!.position.y, expected.y, accuracy: 1e-6)
    }

    func testMaskFollowsTheViewport() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        edit.masks = [Mask(id: "m", kind: .blur, rect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1), start: 0, end: 5)]
        let composer = FrameComposer(edit: edit, events: events, source: source)
        let full = composer.state(at: 0.2)
        XCTAssertEqual(full.masks.count, 1)
        let expected = composer.canvasRect(fromNormalised: edit.masks[0].rect, viewport: full.viewport)
        XCTAssertEqual(full.masks[0].rect, expected)
        XCTAssertEqual(full.masks[0].kind, .blur)
        let zoomed = composer.state(at: events.clicks[0].t)
        XCTAssertGreaterThan(zoomed.viewport.scale, 1.5)
        XCTAssertGreaterThan(zoomed.masks[0].rect.width, full.masks[0].rect.width, "a zoom magnifies the mask with the content")
        XCTAssertTrue(composer.state(at: 6).masks.isEmpty, "inactive after its end")
    }

    func testOpenEndedMaskLastsToTheEnd() {
        let mask = Mask(id: "m", kind: .highlight, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), start: 2)
        XCTAssertFalse(mask.isActive(at: 1.9))
        XCTAssertTrue(mask.isActive(at: 1000))
        XCTAssertEqual(mask.resolvedEnd(duration: 30), 30)
    }

    func testCameraOverlayDodgesTheCursor() {
        // The cursor sits still at the bottom right of the screen for the whole recording, right under the overlay.
        var events = Fixtures.demoEvents()
        events.cursor = [CursorSample(t: 0, x: 3300, y: 2100), CursorSample(t: 20, x: 3300, y: 2100)]
        events.clicks = []
        var edit = EditDocument.default
        edit.cursor.hideWhenIdle = false
        let composer = FrameComposer(edit: edit, events: events, source: source, cameraAvailable: true)
        let home = FrameComposer.cameraRect(spec: edit.camera, layout: composer.layout)
        let state = composer.state(at: 5)
        let overlay = try! XCTUnwrap(state.camera)
        XCTAssertLessThan(overlay.rect.midX, composer.layout.canvasSize.x / 2, "moved to the other side")
        XCTAssertEqual(overlay.rect.size, home.size)
        XCTAssertEqual(overlay.rect.minY, home.minY)

        var away = events
        away.cursor = [CursorSample(t: 0, x: 200, y: 200), CursorSample(t: 20, x: 200, y: 200)]
        let calm = FrameComposer(edit: edit, events: away, source: source, cameraAvailable: true)
        XCTAssertEqual(calm.state(at: 5).camera?.rect, home)
        XCTAssertNil(FrameComposer(edit: edit, events: away, source: source).state(at: 5).camera, "no overlay without a camera track")
    }

    func testCameraPlacementLandsTheBubbleWhereItFloated() {
        // The floating bubble sat over the recording with its centre 90 % across and 80 % down, a quarter of the
        // screen high. On the canvas the overlay must sit at the same spot relative to the screen frame.
        let edit = EditDocument.default
        let layout = CanvasLayout.compute(canvas: edit.canvas, style: edit.style, sourceAspect: 16.0 / 9.0)
        let placement = CameraPlacement(center: SIMD2(0.9, 0.8), height: 0.25)
        let spec = placement.overlay(from: edit.camera, layout: layout)
        XCTAssertEqual(spec.shape, edit.camera.shape, "only position and size change")
        XCTAssertEqual(spec.border, edit.camera.border)
        let rect = FrameComposer.cameraRect(spec: spec, layout: layout)
        let content = layout.contentRect
        XCTAssertEqual(rect.midX, content.minX + 0.9 * content.width, accuracy: 0.5)
        XCTAssertEqual(rect.midY, content.minY + 0.8 * content.height, accuracy: 0.5)
        XCTAssertEqual(rect.height, 0.25 * content.height, accuracy: 0.5)

        // A bubble dragged off the recording lands on its edge instead of vanishing, and a nonsense size is clamped.
        let outside = CameraPlacement(center: SIMD2(1.7, -0.3), height: .nan).overlay(from: edit.camera, layout: layout)
        XCTAssertEqual(outside.position.x, Double(content.maxX) / layout.canvasSize.x, accuracy: 1e-9)
        XCTAssertEqual(outside.position.y, Double(content.minY) / layout.canvasSize.y, accuracy: 1e-9)
        XCTAssertEqual(outside.size, 0.05)
    }

    func testDodgeScheduleEasesInAndOut() {
        let schedule = CameraDodgeSchedule.make(duration: 10, sampleRate: 10, leadIn: 0.3, blend: 0.4) { t in t >= 3 && t < 5 }
        XCTAssertEqual(schedule.intervals.count, 1)
        XCTAssertEqual(schedule.intervals[0].start, 2.7, accuracy: 1e-9)
        XCTAssertEqual(schedule.progress(at: 2.6), 0)
        XCTAssertEqual(schedule.progress(at: 4), 1)
        let mid = schedule.progress(at: 2.9)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, 1)
        XCTAssertEqual(schedule.progress(at: 6), 0)
        let merged = CameraDodgeSchedule.make(duration: 10, sampleRate: 10) { t in (t >= 3 && t < 4) || (t >= 4.5 && t < 5) }
        XCTAssertEqual(merged.intervals.count, 1, "short gaps merge")
    }

    func testKeystrokeLabelGroupsAndFades() {
        let keys = [
            KeyEvent(t: 1.0, chars: "C", modifiers: ["cmd"]),
            KeyEvent(t: 1.3, chars: "V", modifiers: ["cmd"]),
            KeyEvent(t: 5.0, chars: "a", modifiers: []),
        ]
        XCTAssertEqual(keys[0].label, "⌘C")
        XCTAssertTrue(keys[0].isShortcut)
        XCTAssertFalse(keys[2].isShortcut)
        XCTAssertEqual(KeyEvent(t: 0, chars: "S", modifiers: ["shift", "cmd", "opt"]).label, "⌥⇧⌘S")
        XCTAssertNil(KeystrokeDisplay.label(keys: keys, at: 0.5))
        XCTAssertEqual(KeystrokeDisplay.label(keys: keys, at: 1.5)?.text, "⌘C  ⌘V")
        XCTAssertEqual(KeystrokeDisplay.label(keys: keys, at: 1.5)?.opacity, 1)
        XCTAssertLessThan(KeystrokeDisplay.label(keys: keys, at: 1.3 + KeystrokeDisplay.hold - 0.1)!.opacity, 1)
        XCTAssertNil(KeystrokeDisplay.label(keys: keys, at: 1.3 + KeystrokeDisplay.hold + 0.01))

        var events = Fixtures.demoEvents()
        events.keys = keys
        let shortcuts = FrameComposer(edit: .default, events: events, source: source)
        XCTAssertEqual(shortcuts.state(at: 1.5).keystroke?.text, "⌘C  ⌘V")
        XCTAssertNil(shortcuts.state(at: 5.2).keystroke, "plain typing is hidden by default")
        var edit = EditDocument.default
        edit.keystrokes.shortcutsOnly = false
        let all = FrameComposer(edit: edit, events: events, source: source)
        XCTAssertEqual(all.state(at: 5.2).keystroke?.text, "A")
        let label = try! XCTUnwrap(all.state(at: 1.5).keystroke)
        XCTAssertEqual(label.anchor.x, all.layout.contentRect.midX, accuracy: 1e-9)
        XCTAssertLessThan(label.anchor.y, all.layout.contentRect.maxY)
        edit.keystrokes.enabled = false
        XCTAssertNil(FrameComposer(edit: edit, events: events, source: source).state(at: 1.5).keystroke)
    }

    func testLoopCursorReturnsToStart() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.cursor.loop = true
        edit.cursor.hideWhenIdle = false
        let composer = FrameComposer(edit: edit, events: events, source: source)
        let start = composer.state(at: 0).cursor!.position
        let end = composer.state(at: events.duration).cursor!.position
        XCTAssertEqual(end.x, start.x, accuracy: 1e-6)
        XCTAssertEqual(end.y, start.y, accuracy: 1e-6)
        let plain = FrameComposer(edit: .default, events: events, source: source).state(at: events.duration).cursor!.position
        XCTAssertGreaterThan(simd_length(plain - start), 10, "without looping the cursor ends elsewhere")
    }

    func testManualZoomsPlayWithAutoZoomOff() {
        let events = Fixtures.demoEvents()
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        edit.addZoom(start: 15, duration: 3, target: SIMD2(0.5, 0.5), scale: 2)
        edit.autoZoom.enabled = false
        let composer = FrameComposer(edit: edit, events: events, source: source)
        XCTAssertEqual(composer.state(at: events.clicks[0].t).viewport, .full)
        XCTAssertGreaterThan(composer.state(at: 16.5).viewport.scale, 1.9)
    }

    func testSourcePointRoundTrips() {
        let composer = FrameComposer(edit: .default, events: Fixtures.demoEvents(), source: source)
        let viewport = Viewport(center: SIMD2(0.4, 0.6), scale: 2.5)
        let p = SIMD2(1234.0, 567.0)
        let back = composer.sourcePoint(fromCanvas: composer.canvasPoint(fromSource: p, viewport: viewport), viewport: viewport)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
    }
}
