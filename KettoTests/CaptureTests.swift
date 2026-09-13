import XCTest
import CoreMedia
import CoreVideo
@testable import Ketto

/// The capture pieces that can be checked without a capture: the pausable clock, sample retiming and the
/// geometry of capture sources.
final class CaptureTests: XCTestCase {
    func testClockMapsHostTimeToRecordingTimeAcrossPauses() {
        let clock = RecordingClock()
        XCTAssertNil(clock.recordingTime(forHost: 100))
        XCTAssertEqual(clock.establish(100), 100)
        XCTAssertEqual(clock.establish(105), 100, "the base is set once")
        XCTAssertEqual(clock.recordingTime(forHost: 101), 1)
        XCTAssertEqual(clock.recordingTime(forHost: 99.9)!, -0.1, accuracy: 1e-9, "before the base: negative, so audio can be trimmed")

        clock.pause(at: 110)
        XCTAssertTrue(clock.isPaused)
        XCTAssertNil(clock.recordingTime(forHost: 112), "inside the pause")
        XCTAssertEqual(clock.recordingTime(forHost: 109.5), 9.5, "before the pause is unaffected")
        XCTAssertEqual(clock.elapsedRecordingTime(at: 115), 10, "the HUD clock stands still")
        clock.pause(at: 116) // a second pause while paused is ignored
        clock.resume(at: 120)
        XCTAssertFalse(clock.isPaused)
        XCTAssertNil(clock.recordingTime(forHost: 115), "still inside the completed pause")
        XCTAssertEqual(clock.recordingTime(forHost: 120), 10)
        XCTAssertEqual(clock.recordingTime(forHost: 125), 15)
        XCTAssertEqual(clock.elapsedRecordingTime(at: 125), 15)

        clock.pause(at: 130)
        clock.resume(at: 131)
        XCTAssertEqual(clock.recordingTime(forHost: 133)!, 22, accuracy: 1e-9)
        XCTAssertEqual(clock.pausedDuration(before: 133), 11, accuracy: 1e-9)
        XCTAssertEqual(clock.recordingTime(forHost: 128), 18, "between the pauses only the first is subtracted")
        clock.resume(at: 140) // nothing to resume
        XCTAssertEqual(clock.recordingTime(forHost: 140)!, 29, accuracy: 1e-9)
    }

    func testRetimedSampleBufferKeepsPixelsAndChangesTime() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        var created: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &created), noErr)
        let description = try XCTUnwrap(created)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(seconds: 12, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let original = try XCTUnwrap(sample)

        let retimed = try XCTUnwrap(VideoTrackWriter.retimed(original, to: CMTime(seconds: 7, preferredTimescale: 600)))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(retimed).seconds, 7, accuracy: 1e-9)
        XCTAssertEqual(CMSampleBufferGetDuration(retimed).seconds, 1.0 / 60, accuracy: 1e-9)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(retimed) === image, "the pixels are shared, not copied")
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(original).seconds, 12, accuracy: 1e-9, "the original is untouched")
    }

    func testCameraWarningExplainsAMissingOrLateCameraTrack() {
        XCTAssertNil(RecordingSession.cameraWarning(for: CameraCapture.Outcome(frames: 120, receivedFrames: 150, firstFrameTime: 0.03, error: nil)), "a normal capture needs no warning")
        let late = RecordingSession.cameraWarning(for: CameraCapture.Outcome(frames: 120, receivedFrames: 120, firstFrameTime: 2.4, error: nil))
        XCTAssertTrue(late?.contains("2.4") ?? false, "a late start says how late: \(late ?? "nil")")
        XCTAssertNotNil(RecordingSession.cameraWarning(for: nil), "camera on, never started")
        let silent = RecordingSession.cameraWarning(for: CameraCapture.Outcome(frames: 0, receivedFrames: 0, firstFrameTime: nil, error: nil))
        XCTAssertTrue(silent?.contains("no frames") ?? false, "\(silent ?? "nil")")
        let failed = RecordingSession.cameraWarning(for: CameraCapture.Outcome(frames: 0, receivedFrames: 90, firstFrameTime: nil, error: "disk full"))
        XCTAssertTrue(failed?.contains("disk full") ?? false, "\(failed ?? "nil")")
        let early = RecordingSession.cameraWarning(for: CameraCapture.Outcome(frames: 0, receivedFrames: 90, firstFrameTime: nil, error: nil))
        XCTAssertTrue(early?.contains("before") ?? false, "\(early ?? "nil")")
    }

    func testCaptureSourceGeometry() {
        let main = CaptureDisplay(id: 1, name: "Main", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), pixelWidth: 3456, pixelHeight: 2234, scale: 2, isMain: true)
        let side = CaptureDisplay(id: 2, name: "Side", frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080, scale: 1, isMain: false)
        XCTAssertEqual(CaptureSource.display(main).frame, main.frame)
        XCTAssertEqual(CaptureSource.display(main).pixelSize.width, 3456)

        let region = CaptureSource.region(main, CGRect(x: 100.4, y: 50, width: 601, height: 301))
        XCTAssertEqual(region.pixelSize.width, 1202)
        XCTAssertEqual(region.pixelSize.height, 602)
        XCTAssertEqual(region.display, main)
        let overflowing = CaptureSource.region(main, CGRect(x: 1600, y: 1000, width: 500, height: 500))
        XCTAssertEqual(overflowing.frame, CGRect(x: 1600, y: 1000, width: 128, height: 117), "clamped to the display")
        let empty = CaptureSource.region(main, CGRect(x: 5000, y: 5000, width: 10, height: 10))
        XCTAssertTrue(main.frame.contains(empty.frame), "a region off the display falls back to something on it")

        let window = CaptureWindow(id: 42, title: "Notes", applicationName: "Notes", bundleIdentifier: "com.apple.Notes", frame: CGRect(x: 1800, y: 100, width: 800, height: 600), display: side)
        XCTAssertEqual(CaptureSource.window(window).display, side)
        XCTAssertEqual(CaptureSource.window(window).pixelSize.width, 800)
        XCTAssertEqual(CaptureSource.display(for: window.frame, among: [main, side]), side)
        XCTAssertEqual(CaptureSource.display(for: CGRect(x: 1650, y: 0, width: 100, height: 100), among: [main, side]), main, "78 of its 100 points lie on the main display")
        XCTAssertEqual(CaptureSource.pixelSize(points: CGSize(width: 101, height: 51), scale: 1).width, 100, "even sizes only")
        XCTAssertEqual(window.displayName, "Notes — Notes")
    }
}
