import XCTest
@testable import Ketto

final class AudioAlignmentTests: XCTestCase {
    func testContiguousBuffersNeedNoCorrection() {
        var planner = AudioAlignmentPlanner(sampleRate: 48_000)
        let first = planner.plan(offsetSeconds: 0, frameCount: 480)
        XCTAssertEqual(first, .init(silenceFrames: 0, skipFrames: 0))
        let second = planner.plan(offsetSeconds: 0.01 + 0.0001, frameCount: 480) // within tolerance
        XCTAssertEqual(second, .init(silenceFrames: 0, skipFrames: 0))
        XCTAssertEqual(planner.writtenFrames, 960)
    }

    func testLateStartInsertsLeadingSilence() {
        var planner = AudioAlignmentPlanner(sampleRate: 48_000)
        let plan = planner.plan(offsetSeconds: 0.25, frameCount: 480)
        XCTAssertEqual(plan.silenceFrames, 12_000)
        XCTAssertEqual(plan.skipFrames, 0)
        XCTAssertEqual(planner.writtenFrames, 12_480)
    }

    func testEarlyBufferIsTrimmed() {
        var planner = AudioAlignmentPlanner(sampleRate: 48_000)
        let plan = planner.plan(offsetSeconds: -0.005, frameCount: 480) // starts 240 frames before the base
        XCTAssertEqual(plan.skipFrames, 240)
        XCTAssertEqual(plan.silenceFrames, 0)
        XCTAssertEqual(planner.writtenFrames, 240)
        let wholeBufferEarly = planner.plan(offsetSeconds: -1, frameCount: 480)
        XCTAssertEqual(wholeBufferEarly.skipFrames, 480)
        XCTAssertEqual(planner.writtenFrames, 240)
    }

    func testGapMidStreamIsFilledWithSilence() {
        var planner = AudioAlignmentPlanner(sampleRate: 48_000)
        _ = planner.plan(offsetSeconds: 0, frameCount: 4800)
        let plan = planner.plan(offsetSeconds: 0.2, frameCount: 4800) // 0.1 s gap after the first 0.1 s
        XCTAssertEqual(plan.silenceFrames, 4800)
        XCTAssertEqual(planner.writtenFrames, 14_400)
    }
}
