import XCTest
@testable import Ketto

final class EditOperationsTests: XCTestCase {
    func testAddedZoomIsManualAndSurvivesRegeneration() {
        let events = Fixtures.demoEvents()
        var doc = EditDocument.default
        doc.zooms = AutoZoomGenerator().generate(events: events)
        let manual = doc.addZoom(start: 15, duration: 2, target: SIMD2(0.2, 0.3), scale: 3)
        XCTAssertTrue(manual.userModified)
        XCTAssertEqual(doc.zooms.last?.id, manual.id)
        doc.zooms = AutoZoomGenerator().generate(events: events, existing: doc.zooms)
        XCTAssertTrue(doc.zooms.contains(manual))
    }

    func testUpdateMarksUserModifiedAndClamps() {
        var doc = EditDocument.default
        doc.zooms = [Zoom(id: "a", start: 1, duration: 2, target: SIMD2(0.5, 0.5))]
        doc.updateZoom(id: "a") { $0.scale = 20; $0.target = SIMD2(-1, 2); $0.duration = 0.01 }
        XCTAssertTrue(doc.zooms[0].userModified)
        XCTAssertEqual(doc.zooms[0].scale, 6)
        XCTAssertEqual(doc.zooms[0].target, SIMD2(0, 1))
        XCTAssertEqual(doc.zooms[0].duration, EditDocument.minimumZoomDuration)
    }

    func testMoveAndTrimRespectNeighbours() {
        var doc = EditDocument.default
        doc.zooms = [
            Zoom(id: "a", start: 1, duration: 2, target: SIMD2(0.5, 0.5)),
            Zoom(id: "b", start: 5, duration: 2, target: SIMD2(0.5, 0.5)),
            Zoom(id: "c", start: 9, duration: 2, target: SIMD2(0.5, 0.5)),
        ]
        doc.moveZoom(id: "b", toStart: 0, limit: 20)
        XCTAssertEqual(doc.zooms[1].start, 3, "cannot move before the previous block's end")
        doc.moveZoom(id: "b", toStart: 12, limit: 20)
        XCTAssertEqual(doc.zooms[1].start, 7, "cannot move past the next block")
        doc.moveZoom(id: "c", toStart: 30, limit: 20)
        XCTAssertEqual(doc.zooms[2].end, 20, accuracy: 1e-9, "the recording's end is the limit")
        doc.trimZoom(id: "a", start: -5, end: 4, limit: 20)
        XCTAssertEqual(doc.zooms[0].start, 0)
        XCTAssertEqual(doc.zooms[0].end, 4, accuracy: 1e-9)
        doc.trimZoom(id: "a", end: 100, limit: 20)
        XCTAssertEqual(doc.zooms[0].end, 7, accuracy: 1e-9, "trimming stops at the next block")
        doc.trimZoom(id: "a", start: 6.9, limit: 20)
        XCTAssertEqual(doc.zooms[0].duration, EditDocument.minimumZoomDuration, accuracy: 1e-9)
        doc.deleteZoom(id: "b")
        XCTAssertEqual(doc.zooms.map(\.id), ["a", "c"])
    }

    func testMaskOperations() {
        var doc = EditDocument.default
        let mask = doc.addMask(kind: .highlight, rect: CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5), start: 1, end: 3)
        XCTAssertEqual(mask.rect.maxX, 1, accuracy: 1e-9, "clamped into the frame")
        doc.updateMask(id: mask.id) { $0.end = 0.5; $0.rect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2) }
        XCTAssertEqual(doc.masks[0].end!, 1.1, accuracy: 1e-9, "an end before the start is pushed after it")
        doc.deleteMask(id: mask.id)
        XCTAssertTrue(doc.masks.isEmpty)
    }

    func testSnapperPicksNearestCandidateWithinTolerance() {
        let snapper = TimelineSnapper(candidates: [0, 2.0, 2.3, 10], tolerance: 0.2)
        XCTAssertEqual(snapper.snap(2.1), 2.0)
        XCTAssertEqual(snapper.snap(2.16), 2.3, accuracy: 1e-9)
        XCTAssertEqual(snapper.snap(5), 5)
        XCTAssertEqual(snapper.snap(-0.1), 0)
        XCTAssertEqual(snapper.snap(10.15), 10)
        XCTAssertNil(snapper.nearest(to: 6))
        XCTAssertEqual(snapper.snapBlock(start: 1.9, duration: 5), 2.0, accuracy: 1e-9)
        XCTAssertEqual(snapper.snapBlock(start: 4.9, duration: 5), 5.0, accuracy: 1e-9, "the end edge snaps to 10")
        XCTAssertEqual(TimelineSnapper(candidates: [], tolerance: 1).snap(3), 3)
    }

    func testCanvasPresets() {
        for name in CanvasSpec.presetNames {
            let preset = try! XCTUnwrap(CanvasSpec.preset(name))
            XCTAssertEqual(preset.aspect, name)
            let parts = name.split(separator: ":").map { Double($0)! }
            XCTAssertEqual(preset.aspectRatio, parts[0] / parts[1], accuracy: 1e-3)
        }
        XCTAssertNil(CanvasSpec.preset("3:2"))
        var doc = EditDocument.default
        doc.applyCanvasPreset("1:1")
        XCTAssertEqual(doc.canvas.framing, .fill)
        doc.applyCanvasPreset("16:9")
        XCTAssertEqual(doc.canvas, .default)
    }
}
