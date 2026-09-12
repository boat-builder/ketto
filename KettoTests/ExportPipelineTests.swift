import XCTest
@preconcurrency import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import os
@testable import Ketto

/// End-to-end export on a synthetic bundle: a generated `screen.mov`, a synthetic event track, the real
/// exporter, and assertions on the resulting MP4. No capture or permissions involved.
final class ExportPipelineTests: XCTestCase {
    private static let sourceWidth = 320
    private static let sourceHeight = 200
    private static let sourceFPS = 30
    private static let sourceSeconds = 2.0

    /// Records the highest progress fraction reported from the export queue.
    private final class ProgressRecorder: Sendable {
        private let storage = OSAllocatedUnfairLock<[ExportProgress]>(initialState: [])
        func record(_ progress: ExportProgress) { storage.withLock { $0.append(progress) } }
        var reports: [ExportProgress] { storage.withLock { $0 } }
    }

    private func makeBundle(in directory: URL) async throws -> (RecordingBundle, EventsDocument, EditDocument) {
        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("Synthetic.ketto"))
        try await SyntheticMovie.write(
            to: bundle.screenURL,
            width: Self.sourceWidth,
            height: Self.sourceHeight,
            fps: Self.sourceFPS,
            seconds: Self.sourceSeconds
        )
        let events = SyntheticMovie.scaledEvents(
            SyntheticSource.events(duration: Self.sourceSeconds),
            toWidth: Self.sourceWidth,
            height: Self.sourceHeight
        )
        try bundle.write(events: events)
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        try bundle.write(edit: edit)
        return (bundle, events, edit)
    }

    func testExportsSyntheticRecordingToMP4() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KettoExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (bundle, events, edit) = try await makeBundle(in: directory)

        let outputURL = directory.appendingPathComponent("export.mp4")
        let settings = ExportSettings(width: 640, height: 360, fps: 30)
        let exporter = Exporter(bundle: bundle, events: events, edit: edit, settings: settings, outputURL: outputURL)
        let recorder = ProgressRecorder()
        let url = try await exporter.run { progress in recorder.record(progress) }

        XCTAssertEqual(url, outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
        XCTAssertGreaterThan(size, 10_000)

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let naturalSize = try await XCTUnwrap(videoTracks.first).load(.naturalSize)
        XCTAssertEqual(Int(naturalSize.width), 640)
        XCTAssertEqual(Int(naturalSize.height), 360)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, Self.sourceSeconds, accuracy: 0.1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "a bundle without audio files must export without an audio track")

        let reports = recorder.reports
        XCTAssertEqual(reports.last?.totalFrames, 60)
        XCTAssertEqual(reports.last?.framesRendered, 60)
        XCTAssertEqual(reports.last?.fraction ?? 0, 1, accuracy: 1e-9)
    }

    func testCancelledExportThrowsAndLeavesNoFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KettoExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (bundle, events, edit) = try await makeBundle(in: directory)

        let outputURL = directory.appendingPathComponent("cancelled.mp4")
        let exporter = Exporter(bundle: bundle, events: events, edit: edit, settings: ExportSettings(width: 640, height: 360, fps: 60), outputURL: outputURL)
        exporter.cancel()
        do {
            _ = try await exporter.run { _ in }
            XCTFail("a cancelled export must throw")
        } catch ExportError.cancelled {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testPresetsKeepCanvasAspect() {
        let landscape = ExportSettings.preset(.uhd4K, fps: 60, canvas: .default)
        XCTAssertEqual(landscape.width, 3840)
        XCTAssertEqual(landscape.height, 2160)
        let portrait = ExportSettings.preset(.hd1080, fps: 30, canvas: CanvasSpec(aspect: "9:16", width: 1080, height: 1920))
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
        XCTAssertEqual(ExportSettings(width: 641, height: 361, fps: 30).width % 2, 0)
        XCTAssertLessThanOrEqual(landscape.videoBitrate, 80_000_000)
        XCTAssertGreaterThanOrEqual(ExportSettings(width: 640, height: 360, fps: 30).videoBitrate, 2_000_000)
    }

    func testExportPresetsAndCodecRules() {
        let gif = ExportPreset.gif.settings(canvas: .default)
        XCTAssertEqual(gif.container, .gif)
        XCTAssertEqual(gif.width, 640)
        XCTAssertEqual(gif.height, 360)
        XCTAssertEqual(gif.fps, 15)
        XCTAssertTrue(gif.loop)
        let vertical = ExportSettings.gif(width: 480, fps: 10, canvas: CanvasSpec(aspect: "9:16", width: 1080, height: 1920))
        XCTAssertEqual(vertical.width, 480)
        XCTAssertEqual(vertical.height, 852, "480 / (9/16) = 853.3, rounded to an even number")
        let handoff = ExportPreset.handoff.settings(canvas: .default)
        XCTAssertEqual(handoff.container, .mov)
        XCTAssertEqual(handoff.codec, .proRes422)
        XCTAssertEqual(handoff.fps, 60)
        let social = ExportPreset.social.settings(canvas: .default)
        XCTAssertEqual(social.fps, 30)
        let web = ExportPreset.web.settings(canvas: .default)
        XCTAssertGreaterThan(social.videoBitrate, Int(Double(web.videoBitrate) * 0.7), "half the frames at 1.5× quality")
        XCTAssertEqual(ExportSettings(width: 640, height: 360, fps: 30, container: .mp4, codec: .proRes422).codec, .h264, "ProRes only goes in a MOV")
        XCTAssertFalse(ExportCodec.hevc.isAvailable(in: .gif))
        XCTAssertEqual(Double(ExportSettings(width: 1920, height: 1080, fps: 60, codec: .hevc).videoBitrate), 1920 * 1080 * 60 * 0.065, accuracy: 1)
        XCTAssertGreaterThan(gif.estimatedFileSize(duration: 10), 0)
    }

    func testExportsAnimatedGIF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KettoExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (bundle, events, edit) = try await makeBundle(in: directory)

        let outputURL = directory.appendingPathComponent("export.gif")
        let settings = ExportSettings.gif(width: 320, fps: 10, canvas: edit.canvas)
        let exporter = Exporter(bundle: bundle, events: events, edit: edit, settings: settings, outputURL: outputURL)
        let recorder = ProgressRecorder()
        let url = try await exporter.run { progress in recorder.record(progress) }
        XCTAssertEqual(url, outputURL)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.gif.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 20, "2 seconds at 10 fps")
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(first.width, 320)
        XCTAssertEqual(first.height, 180)
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gifProperties = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(gifProperties[kCGImagePropertyGIFLoopCount] as? Int, 0, "loops forever")
        let frameProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 3, nil) as? [CFString: Any])
        let frameGIF = try XCTUnwrap(frameProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(frameGIF[kCGImagePropertyGIFDelayTime] as? Double ?? 0, 0.1, accuracy: 0.011)
        XCTAssertEqual(recorder.reports.last?.framesRendered, 20)
        XCTAssertEqual(recorder.reports.last?.totalFrames, 20)
    }

    func testExportsHEVCQuickTimeMovie() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KettoExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (bundle, events, edit) = try await makeBundle(in: directory)

        let outputURL = directory.appendingPathComponent("export.mov")
        let settings = ExportSettings(width: 640, height: 360, fps: 30, container: .mov, codec: .hevc)
        let exporter = Exporter(bundle: bundle, events: events, edit: edit, settings: settings, outputURL: outputURL)
        let url = try await exporter.run { _ in }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_HEVC)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, Self.sourceSeconds, accuracy: 0.1)
    }

    func testExportDrawsTheCameraTrack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KettoExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (bundle, events, edit) = try await makeBundle(in: directory)
        try await SyntheticMovie.write(to: bundle.cameraURL, width: 64, height: 48, fps: 30, seconds: Self.sourceSeconds)
        XCTAssertTrue(bundle.hasCameraTrack)

        func exportedFrame(cameraEnabled: Bool) async throws -> BGRAImage {
            var doc = edit
            doc.camera.enabled = cameraEnabled
            doc.camera.dodgeCursor = false
            let outputURL = directory.appendingPathComponent("camera-\(cameraEnabled).mov")
            let settings = ExportSettings(width: 640, height: 360, fps: 30, container: .mov, codec: .proRes422)
            let exporter = Exporter(bundle: bundle, events: events, edit: doc, settings: settings, outputURL: outputURL)
            let url = try await exporter.run { _ in }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            return try XCTUnwrap(BGRAImage(cgImage: image))
        }
        let with = try await exportedFrame(cameraEnabled: true)
        let without = try await exportedFrame(cameraEnabled: false)
        XCTAssertEqual(with.width, 640)
        let difference = try XCTUnwrap(with.difference(to: without))
        XCTAssertGreaterThan(difference.fractionOverThreshold, 0.005, "the camera bubble changes a visible part of the frame")
        XCTAssertLessThan(difference.fractionOverThreshold, 0.3, "and only that part")
    }
}

/// Writes a short H.264 movie from `SyntheticSource.patternImage` frames and scales the synthetic events to it.
enum SyntheticMovie {
    static func write(to url: URL, width: Int, height: Int, fps: Int, seconds: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ExportError.writerSetupFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)
        let frameCount = Int(seconds * Double(fps))
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let image = SyntheticSource.patternImage(width: width, height: height, frameIndex: index)
            let buffer = SyntheticSource.pixelBuffer(image: image)
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? ExportError.writerFailed(nil)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.writerFailed(nil)
        }
    }

    /// Rescales a 640×400 synthetic event track to another source size.
    static func scaledEvents(_ events: EventsDocument, toWidth width: Int, height: Int) -> EventsDocument {
        let sx = Double(width) / Double(max(events.display.width, 1))
        let sy = Double(height) / Double(max(events.display.height, 1))
        var scaled = events
        scaled.display = DisplayInfo(id: events.display.id, width: width, height: height, scale: events.display.scale)
        scaled.cursor = events.cursor.map { CursorSample(t: $0.t, x: $0.x * sx, y: $0.y * sy, type: $0.type) }
        scaled.clicks = events.clicks.map { ClickEvent(t: $0.t, x: $0.x * sx, y: $0.y * sy, button: $0.button, phase: $0.phase) }
        scaled.focus = events.focus.map { focus in
            let rect = focus.rect.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
            return FocusEvent(t: focus.t, bundleId: focus.bundleId, frame: rect)
        }
        return scaled
    }
}
