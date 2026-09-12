import XCTest
@testable import Ketto

/// The editor session on a synthetic bundle: undo/redo grouping, the timeline operations and the preset
/// re-optimisation, without a window.
@MainActor
final class ProjectSessionTests: XCTestCase {
    private func makeSession() async throws -> (ProjectSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KettoSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("Session.ketto"))
        try await SyntheticMovie.write(to: bundle.screenURL, width: 160, height: 100, fps: 30, seconds: 8)
        let events = SyntheticMovie.scaledEvents(SyntheticSource.events(duration: 8), toWidth: 160, height: 100)
        try bundle.write(events: events)
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        try bundle.write(edit: edit)
        let session = try ProjectSession(bundle: bundle)
        // The player loads asynchronously; seeks clamp to its duration, so wait for it.
        for _ in 0..<400 where session.player.duration <= 0 && session.player.loadError == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(session.player.loadError)
        XCTAssertEqual(session.player.duration, 8, accuracy: 0.05)
        return (session, directory)
    }

    func testUndoGroupsSliderDragsAndGestures() async throws {
        let (session, directory) = try await makeSession()
        defer { session.close(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(session.canUndo)
        let original = session.edit

        // Quick successive assignments (a slider drag) are one step.
        session.edit.style.padding = 10
        session.edit.style.padding = 20
        session.edit.style.padding = 30
        XCTAssertTrue(session.canUndo)
        session.undo()
        XCTAssertEqual(session.edit.style.padding, original.style.padding)
        XCTAssertFalse(session.canUndo)
        XCTAssertTrue(session.canRedo)
        session.redo()
        XCTAssertEqual(session.edit.style.padding, 30)

        // `apply` is always its own step, even right after another change.
        session.apply { $0.style.cornerRadius = 3 }
        session.apply { $0.style.cornerRadius = 4 }
        session.undo()
        XCTAssertEqual(session.edit.style.cornerRadius, 3)
        session.undo()
        XCTAssertEqual(session.edit.style.cornerRadius, original.style.cornerRadius)
        XCTAssertEqual(session.edit.style.padding, 30)

        // A timeline drag is one step however many updates it sends.
        let zoomID = try XCTUnwrap(session.edit.zooms.first?.id)
        let start = try XCTUnwrap(session.edit.zooms.first?.start)
        session.beginGesture()
        for step in 1...5 {
            session.updateGesture { $0.moveZoom(id: zoomID, toStart: start + Double(step) * 0.05, limit: 8) }
        }
        session.endGesture()
        XCTAssertEqual(session.edit.zooms.first?.start ?? 0, start + 0.25, accuracy: 1e-9)
        session.undo()
        XCTAssertEqual(session.edit.zooms.first?.start ?? 0, start, accuracy: 1e-9)
        XCTAssertEqual(session.edit.style.padding, 30, "the earlier step is still there")
    }

    func testTimelineOperationsFollowThePlayhead() async throws {
        let (session, directory) = try await makeSession()
        defer { session.close(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(session.duration, 8, accuracy: 1e-9)
        XCTAssertEqual(session.timeline.segments.count, 1)

        session.player.seek(to: 3)
        XCTAssertEqual(session.playheadSourceTime, 3, accuracy: 1e-9)
        session.splitAtPlayhead()
        XCTAssertEqual(session.timeline.segments.count, 2)
        guard case .clip(let rightID) = session.selection else { return XCTFail("the right half is selected") }
        XCTAssertEqual(session.selectedClip?.sourceStart ?? 0, 3, accuracy: 1e-9)

        session.setClipSpeed(id: rightID, speed: 2)
        XCTAssertEqual(session.duration, 3 + 2.5, accuracy: 1e-9)
        XCTAssertEqual(session.timeline.sourceTime(forOutput: 4), 5, accuracy: 1e-9)

        session.deleteSelection()
        XCTAssertNil(session.selection)
        XCTAssertEqual(session.timeline.segments.count, 1)
        XCTAssertEqual(session.duration, 3, accuracy: 1e-9)
        session.undo()
        XCTAssertEqual(session.timeline.segments.count, 2)

        session.player.seek(to: 1)
        let zoomsBefore = session.edit.zooms.count
        session.addZoomAtPlayhead()
        guard case .zoom(let zoomID) = session.selection else { return XCTFail("the new zoom is selected") }
        XCTAssertEqual(session.edit.zooms.count, zoomsBefore + 1)
        let zoom = try XCTUnwrap(session.edit.zooms.first { $0.id == zoomID })
        XCTAssertTrue(zoom.userModified)
        XCTAssertGreaterThanOrEqual(zoom.start, 1)

        session.addMask(kind: .highlight)
        guard case .mask = session.selection else { return XCTFail("the new mask is selected") }
        XCTAssertEqual(session.edit.masks.count, 1)
        XCTAssertEqual(session.edit.masks[0].kind, .highlight)
        XCTAssertNil(session.edit.masks[0].end)
    }

    func testPresetsAndCropReoptimiseAutomaticZoomsButKeepManualOnes() async throws {
        let (session, directory) = try await makeSession()
        defer { session.close(); try? FileManager.default.removeItem(at: directory) }
        session.player.seek(to: 6.5)
        session.addZoomAtPlayhead()
        let manual = try XCTUnwrap(session.selectedZoom)
        let automaticBefore = session.edit.zooms.filter { !$0.userModified }
        XCTAssertFalse(automaticBefore.isEmpty)

        session.applyCanvasPreset("9:16")
        XCTAssertEqual(session.edit.canvas.framing, .fill)
        XCTAssertEqual(session.composer.layout.canvasSize.y, 1920)
        XCTAssertTrue(session.edit.zooms.contains(manual), "manual zooms survive")
        let automaticAfter = session.edit.zooms.filter { !$0.userModified }
        XCTAssertFalse(automaticAfter.isEmpty)
        XCTAssertLessThan(automaticAfter[0].scale, automaticBefore[0].scale, "zooms are attenuated for the narrow slice")

        session.beginCropEditing()
        XCTAssertTrue(session.isEditingCrop)
        XCTAssertEqual(session.previewComposer.state(at: 1).viewport, .full, "the crop editor shows the whole recording")
        session.updateGesture { $0.crop = CropSpec(x: 0.25, y: 0, width: 0.5, height: 1) }
        session.endGesture()
        session.endCropEditing()
        XCTAssertFalse(session.isEditingCrop)
        XCTAssertEqual(session.edit.crop.width, 0.5, accuracy: 1e-9)
        XCTAssertTrue(session.edit.zooms.contains(manual))
        XCTAssertTrue(session.composer.framing.bounds.isApproximatelyEqual(to: session.edit.crop.viewport))

        session.saveNow()
        let saved = session.bundle.readEdit()
        XCTAssertEqual(saved, session.edit)
    }
}
