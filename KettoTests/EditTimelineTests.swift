import XCTest
@testable import Ketto

final class EditTimelineTests: XCTestCase {
    func testIdentityMapsTimesThrough() {
        let timeline = EditTimeline.identity(duration: 10)
        XCTAssertTrue(timeline.isIdentity)
        XCTAssertEqual(timeline.outputDuration, 10)
        XCTAssertEqual(timeline.sourceTime(forOutput: 4.2), 4.2, accuracy: 1e-9)
        XCTAssertEqual(timeline.outputTime(forSource: 4.2), 4.2, accuracy: 1e-9)
        XCTAssertEqual(timeline.sourceTime(forOutput: 12), 10, accuracy: 1e-9)
        XCTAssertTrue(timeline.cuts.isEmpty)
    }

    func testDefaultDocumentResolvesToOneClip() {
        let clips = EditDocument.default.resolvedClips(sourceDuration: 8)
        XCTAssertEqual(clips, [Clip(id: Clip.mainID, sourceStart: 0, sourceEnd: 8)])
        XCTAssertTrue(EditTimeline(edit: .default, sourceDuration: 8).isIdentity)
    }

    func testLegacyCutsBecomeClips() {
        var doc = EditDocument.default
        doc.cuts = [Cut(start: 2, end: 3), Cut(start: 7, end: 10)]
        let timeline = EditTimeline(edit: doc, sourceDuration: 10)
        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertEqual(timeline.outputDuration, 6, accuracy: 1e-9)
        XCTAssertEqual(timeline.sourceTime(forOutput: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(timeline.sourceTime(forOutput: 2.5), 3.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.outputTime(forSource: 2.5), 2, accuracy: 1e-9, "a time inside a cut lands on the cut")
        XCTAssertEqual(timeline.outputTime(forSource: 8), 6, accuracy: 1e-9)
        XCTAssertFalse(timeline.isVisible(sourceTime: 2.5))
        XCTAssertTrue(timeline.isVisible(sourceTime: 5))
        XCTAssertEqual(timeline.cuts, doc.cuts)
    }

    func testSpeedScalesOutputTime() {
        var doc = EditDocument.default
        doc.clips = [
            Clip(id: "a", sourceStart: 0, sourceEnd: 4, speed: 2),
            Clip(id: "b", sourceStart: 4, sourceEnd: 8, speed: 0.5),
        ]
        let timeline = EditTimeline(edit: doc, sourceDuration: 8)
        XCTAssertEqual(timeline.outputDuration, 2 + 8, accuracy: 1e-9)
        XCTAssertEqual(timeline.sourceTime(forOutput: 1), 2, accuracy: 1e-9)
        XCTAssertEqual(timeline.sourceTime(forOutput: 6), 6, accuracy: 1e-9)
        XCTAssertEqual(timeline.outputTime(forSource: 6), 6, accuracy: 1e-9)
        XCTAssertEqual(timeline.speed(atOutput: 0.5), 2)
        XCTAssertEqual(timeline.speed(atOutput: 5), 0.5)
        XCTAssertEqual(timeline.outputRange(sourceStart: 3, sourceEnd: 5)!, 1.5...4, "a range spanning the speed change")
        XCTAssertNil(timeline.outputRange(sourceStart: 9, sourceEnd: 10))
    }

    func testOverlappingAndOutOfRangeClipsAreSanitised() {
        var doc = EditDocument.default
        doc.clips = [
            Clip(id: "b", sourceStart: 3, sourceEnd: 20),
            Clip(id: "a", sourceStart: 0, sourceEnd: 5),
            Clip(id: "empty", sourceStart: 6, sourceEnd: 6.01),
        ]
        let clips = doc.resolvedClips(sourceDuration: 10)
        XCTAssertEqual(clips.map(\.id), ["a", "b"])
        XCTAssertEqual(clips[1].sourceStart, 5)
        XCTAssertEqual(clips[1].sourceEnd, 10)
    }

    func testSplitDeleteTrimAndSpeed() {
        var doc = EditDocument.default
        let split = doc.splitClip(atSource: 4, sourceDuration: 10)
        XCTAssertNotNil(split)
        XCTAssertEqual(doc.clips.count, 2)
        XCTAssertEqual(doc.clips[0].sourceEnd, 4)
        XCTAssertEqual(doc.clips[1].sourceStart, 4)
        XCTAssertEqual(doc.clips[0].id, Clip.mainID)
        XCTAssertNil(doc.splitClip(atSource: 4.01, sourceDuration: 10), "too close to an edge")

        XCTAssertTrue(doc.deleteClip(id: split!.right, sourceDuration: 10))
        XCTAssertEqual(doc.clips.count, 1)
        XCTAssertFalse(doc.deleteClip(id: Clip.mainID, sourceDuration: 10), "the last clip stays")
        XCTAssertEqual(EditTimeline(edit: doc, sourceDuration: 10).outputDuration, 4, accuracy: 1e-9)

        doc.trimClip(id: Clip.mainID, sourceStart: 1, sourceDuration: 10)
        XCTAssertEqual(doc.clips[0].sourceStart, 1)
        doc.trimClip(id: Clip.mainID, sourceEnd: 30, sourceDuration: 10)
        XCTAssertEqual(doc.clips[0].sourceEnd, 10, "trimming out cannot pass the end of the recording")
        doc.trimClip(id: Clip.mainID, sourceStart: 9.99, sourceDuration: 10)
        XCTAssertEqual(doc.clips[0].sourceEnd - doc.clips[0].sourceStart, Clip.minimumDuration, accuracy: 1e-9)

        doc.setClipSpeed(id: Clip.mainID, speed: 9, sourceDuration: 10)
        XCTAssertEqual(doc.clips[0].speed, Clip.speedRange.upperBound)
        XCTAssertTrue(doc.cuts.isEmpty, "materialising clips retires the legacy cuts")
    }

    func testJoinUndoesASplit() {
        var doc = EditDocument.default
        doc.splitClip(atSource: 5, sourceDuration: 10)
        XCTAssertTrue(doc.joinClipWithNext(id: Clip.mainID, sourceDuration: 10))
        XCTAssertEqual(doc.clips, [Clip(id: Clip.mainID, sourceStart: 0, sourceEnd: 10)])
        doc.splitClip(atSource: 5, sourceDuration: 10)
        doc.trimClip(id: Clip.mainID, sourceEnd: 4, sourceDuration: 10)
        XCTAssertFalse(doc.joinClipWithNext(id: Clip.mainID, sourceDuration: 10), "a gap between the clips is a cut, not a split")
    }

    func testTrimCannotCrossNeighbour() {
        var doc = EditDocument.default
        doc.splitClip(atSource: 5, sourceDuration: 10)
        let right = doc.clips[1].id
        doc.trimClip(id: right, sourceStart: 2, sourceDuration: 10)
        XCTAssertEqual(doc.clips[1].sourceStart, 5)
        doc.trimClip(id: Clip.mainID, sourceEnd: 3, sourceDuration: 10)
        doc.trimClip(id: right, sourceStart: 2, sourceDuration: 10)
        XCTAssertEqual(doc.clips[1].sourceStart, 3, "the neighbour's new edge is the limit")
    }
}
