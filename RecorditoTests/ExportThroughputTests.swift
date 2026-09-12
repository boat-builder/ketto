import XCTest
@preconcurrency import AVFoundation
import CoreMedia
@testable import Recordito

/// Opt-in throughput benchmark for the v1 acceptance criteria in docs/SPEC.md section 6: a two-minute export must
/// finish faster than real time at 1080p60, and at no worse than half real time at 4K60.
///
/// It is skipped by default because it writes a two-minute source movie and renders every frame of it; run it
/// with a Release build, which is what the numbers are supposed to describe:
///
///     TEST_RUNNER_RECORDITO_RUN_BENCHMARKS=1 xcodebuild test -configuration Release \
///       -project Recordito.xcodeproj -scheme Recordito -destination 'platform=macOS,arch=arm64' \
///       -only-testing:RecorditoTests/ExportThroughputTests
///
/// No capture, display or permission is involved: the source is a synthetic H.264 movie and the events come
/// from `BenchmarkEvents`, so this measures exactly the decode → compose → render → encode path that the
/// Export sheet drives.
final class ExportThroughputTests: XCTestCase {
    private static let enabled = ProcessInfo.processInfo.environment["RECORDITO_RUN_BENCHMARKS"] == "1"
    private static let seconds = 120.0
    private static let sourceFPS = 60

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.enabled, "set RECORDITO_RUN_BENCHMARKS=1 to run the export throughput benchmark")
    }

    func test1080p60ExportIsFasterThanRealTime() async throws {
        let ratio = try await measureExport(sourceWidth: 1920, sourceHeight: 1080, resolution: .hd1080)
        XCTAssertGreaterThan(ratio, 1.0, "1080p60 export must finish faster than real time (got \(String(format: "%.2f", ratio))× real time)")
    }

    func test4K60ExportIsAtLeastHalfRealTime() async throws {
        let ratio = try await measureExport(sourceWidth: 3840, sourceHeight: 2160, resolution: .uhd4K)
        XCTAssertGreaterThan(ratio, 0.5, "4K60 export must reach at least 0.5× real time (got \(String(format: "%.2f", ratio))× real time)")
    }

    /// Builds a synthetic bundle, exports the whole thing and returns elapsed-vs-real-time as a speed multiple.
    private func measureExport(sourceWidth: Int, sourceHeight: Int, resolution: ExportSettings.Resolution) async throws -> Double {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecorditoBenchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("Benchmark.recordito"))
        let sourceStarted = Date()
        try await BenchmarkMovie.write(to: bundle.screenURL, width: sourceWidth, height: sourceHeight, fps: Self.sourceFPS, seconds: Self.seconds)
        let events = BenchmarkEvents.make(duration: Self.seconds, width: sourceWidth, height: sourceHeight)
        try bundle.write(events: events)
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        try bundle.write(edit: edit)

        let settings = ExportSettings.preset(resolution, fps: 60, canvas: edit.canvas)
        let outputURL = directory.appendingPathComponent("benchmark.mp4")
        let exporter = Exporter(bundle: bundle, events: events, edit: edit, settings: settings, outputURL: outputURL)

        let started = Date()
        _ = try await exporter.run { _ in }
        let elapsed = Date().timeIntervalSince(started)
        let ratio = Self.seconds / elapsed

        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        print("""
        [benchmark] \(settings.sizeDescription) @ \(settings.fps) fps from a \(sourceWidth)×\(sourceHeight) source
        [benchmark]   zooms generated: \(edit.zooms.count)
        [benchmark]   source movie written in \(String(format: "%.1f", started.timeIntervalSince(sourceStarted))) s (not counted)
        [benchmark]   exported \(String(format: "%.0f", Self.seconds)) s of video in \(String(format: "%.1f", elapsed)) s = \(String(format: "%.2f", ratio))× real time
        [benchmark]   output \(String(format: "%.1f", Double(size) / 1_000_000)) MB
        """)
        return ratio
    }
}

/// Writes a long synthetic movie cheaply: a small pool of distinct frames is built once and cycled, so the
/// cost is encoding rather than pixel generation, while the content still changes frame to frame. The encoder
/// settings come from `VideoTrackWriter`, so the decode side of the benchmark faces the same HEVC bitstream a
/// real capture produces rather than an easier H.264 one.
enum BenchmarkMovie {
    private static let poolSize = 24

    static func write(to url: URL, width: Int, height: Int, fps: Int, seconds: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoTrackWriter.outputSettings(width: width, height: height, fps: fps))
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

        let pool = (0..<poolSize).map { SyntheticSource.pixelBuffer(image: SyntheticSource.patternImage(width: width, height: height, frameIndex: $0 * 7)) }
        let frameCount = Int(seconds * Double(fps))
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            guard adaptor.append(pool[index % poolSize], withPresentationTime: time) else {
                throw writer.error ?? ExportError.writerFailed(nil)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.writerFailed(nil)
        }
    }
}

/// A busy event track that stays active for the whole recording: the cursor moves continuously and clicks
/// every few seconds in a new part of the screen, so the camera is ramping, panning or holding a zoom for most
/// of the export rather than sitting on the static full view. That keeps the benchmark on the expensive render
/// path — `FrameRenderer` drops to a single sample per frame whenever the viewport is not moving, so an idle
/// track would measure something much cheaper than a real demo recording.
enum BenchmarkEvents {
    private static let clickInterval = 6.0

    static func make(duration: Double, width: Int, height: Int) -> EventsDocument {
        let w = Double(width), h = Double(height)
        // Click targets walk around the screen on an irrational-ish step so consecutive targets are far apart
        // and every cluster generates its own zoom instead of merging into the previous one.
        var targets: [(Double, SIMD2<Double>)] = []
        var index = 0
        var t = 2.0
        while t < duration - 1 {
            let u = Double(index) * 0.37
            let x = (0.15 + 0.7 * abs(((u * 2).truncatingRemainder(dividingBy: 2)) - 1)) * w
            let y = (0.15 + 0.7 * abs(((u * 3 + 0.5).truncatingRemainder(dividingBy: 2)) - 1)) * h
            targets.append((t, SIMD2(x, y)))
            t += clickInterval
            index += 1
        }

        var cursor: [CursorSample] = []
        var clicks: [ClickEvent] = []
        var position = SIMD2<Double>(w * 0.5, h * 0.5)
        var time = 0.0
        for (clickTime, target) in targets {
            // Fly to the target over the second before the click, then dwell on it until the next one.
            let flightStart = max(time, clickTime - 1.0)
            while time < flightStart {
                time += 1.0 / 60
                cursor.append(CursorSample(t: time, x: position.x, y: position.y, type: .arrow))
            }
            let origin = position
            while time < clickTime {
                time += 1.0 / 60
                let progress = min(max((time - flightStart) / max(clickTime - flightStart, 1e-6), 0), 1)
                position = origin + (target - origin) * progress
                cursor.append(CursorSample(t: time, x: position.x, y: position.y, type: progress > 0.6 ? .pointingHand : .arrow))
            }
            position = target
            clicks.append(ClickEvent(t: clickTime, x: target.x, y: target.y, button: .left, phase: .down))
            clicks.append(ClickEvent(t: clickTime + 0.08, x: target.x, y: target.y, button: .left, phase: .up))
        }
        while time < duration {
            time += 1.0 / 60
            cursor.append(CursorSample(t: time, x: position.x, y: position.y, type: .arrow))
        }

        let display = DisplayInfo(id: 1, width: width, height: height, scale: 2)
        let focus = [FocusEvent(t: 0, bundleId: "com.example.benchmark", frame: CGRect(x: w * 0.05, y: h * 0.05, width: w * 0.9, height: h * 0.9))]
        return EventsDocument(recordingStart: 1_757_606_400, duration: duration, display: display, cursor: cursor, clicks: clicks, keys: [], focus: focus)
    }
}
