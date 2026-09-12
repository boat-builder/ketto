import XCTest
@preconcurrency import AVFoundation
import CoreMedia
@testable import Ketto

/// The pieces underneath the editor's playback: compositions built on the edited timeline, waveform and
/// filmstrip loading, and the derived voice track. All on synthetic media, no capture or permissions.
final class PlaybackTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KettoPlaybackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A mono float CAF: silence for the first half, a 440 Hz tone at `amplitude` for the second half, plus
    /// white noise at `noise` throughout.
    private func writeTone(to url: URL, seconds: Double, amplitude: Float, noise: Float, sampleRate: Double = 48_000) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = Int(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        var generator = SplitMix64(seed: 7)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let tone = t >= seconds / 2 ? amplitude * Float(sin(2 * .pi * 440 * t)) : 0
            data[0][i] = tone + Float(generator.nextUniform() * 2 - 1) * noise
        }
        try file.write(from: buffer)
    }

    func testCompositionFollowsTheEditTimeline() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("Composition.ketto"))
        try await SyntheticMovie.write(to: bundle.screenURL, width: 160, height: 100, fps: 30, seconds: 2)
        try writeTone(to: bundle.micURL, seconds: 2, amplitude: 0.5, noise: 0)

        var edit = EditDocument.default
        edit.clips = [Clip(id: "a", sourceStart: 0, sourceEnd: 0.5), Clip(id: "b", sourceStart: 1, sourceEnd: 2, speed: 2)]
        edit.audio.micVolume = 0.5
        let timeline = edit.timeline(sourceDuration: 2)
        XCTAssertEqual(timeline.outputDuration, 1.0, accuracy: 1e-9)

        let media = try await CompositionBuilder.screenMedia(for: PlaybackSource(bundle: bundle, timeline: timeline, audio: edit.audio))
        XCTAssertEqual(media.sourceDuration, 2, accuracy: 0.05)
        XCTAssertEqual(media.composition.duration.seconds, 1.0, accuracy: 0.02)
        XCTAssertTrue(media.hasAudio)
        XCTAssertEqual(media.audioMix?.inputParameters.count, 1)

        let video = try XCTUnwrap(media.composition.tracks(withMediaType: .video).first)
        let segments = try await video.load(.segments)
        XCTAssertEqual(segments.count, 2)
        let second = try XCTUnwrap(segments.last)
        XCTAssertEqual(second.timeMapping.source.start.seconds, 1, accuracy: 1e-3)
        XCTAssertEqual(second.timeMapping.source.duration.seconds, 1, accuracy: 1e-3)
        XCTAssertEqual(second.timeMapping.target.start.seconds, 0.5, accuracy: 1e-3)
        XCTAssertEqual(second.timeMapping.target.duration.seconds, 0.5, accuracy: 1e-3, "played at 2× the clip takes half its length")

        let audio = try XCTUnwrap(media.composition.tracks(withMediaType: .audio).first)
        let audioRange = try await audio.load(.timeRange)
        XCTAssertEqual(audioRange.end.seconds, 1.0, accuracy: 0.02)

        // Without a camera track there is no camera composition; without clips the whole recording plays.
        let camera = try await CompositionBuilder.cameraComposition(for: PlaybackSource(bundle: bundle, timeline: timeline, audio: edit.audio))
        XCTAssertNil(camera)
        let whole = try await CompositionBuilder.screenMedia(for: PlaybackSource(bundle: bundle, timeline: EditTimeline(clips: [], sourceDuration: 0), audio: .default))
        XCTAssertEqual(whole.composition.duration.seconds, 2, accuracy: 0.05)
    }

    func testCameraCompositionStartsWhereTheCameraStarted() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("Camera.ketto"))
        try await SyntheticMovie.write(to: bundle.screenURL, width: 160, height: 100, fps: 30, seconds: 2)
        try await SyntheticMovie.write(to: bundle.cameraURL, width: 64, height: 48, fps: 30, seconds: 1)
        XCTAssertTrue(bundle.hasCameraTrack)
        let timeline = EditTimeline(clips: [Clip(id: "a", sourceStart: 0.5, sourceEnd: 2)], sourceDuration: 2)
        let camera = try await XCTUnwrap(CompositionBuilder.cameraComposition(for: PlaybackSource(bundle: bundle, timeline: timeline, audio: .default)))
        let track = try XCTUnwrap(camera.tracks(withMediaType: .video).first)
        // The camera file ends at 1 s, so only the first half second of the clip has camera frames.
        let range = try await track.load(.timeRange)
        XCTAssertEqual(range.end.seconds, 0.5, accuracy: 0.02)
    }

    func testWaveformLoaderBucketsPeaks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tone.caf")
        try writeTone(to: url, seconds: 2, amplitude: 0.8, noise: 0)
        let waveform = try WaveformLoader.load(url: url, bucketsPerSecond: 50)
        XCTAssertEqual(waveform.peaks.count, 100)
        XCTAssertEqual(waveform.duration, 2, accuracy: 1e-9)
        XCTAssertEqual(waveform.peak(at: 0.5), 0, accuracy: 1e-6)
        XCTAssertEqual(waveform.peak(at: 1.5), 0.8, accuracy: 0.02)
        XCTAssertEqual(waveform.peak(from: 0.9, to: 1.1), 0.8, accuracy: 0.02)
        XCTAssertEqual(waveform.peak(at: 5), 0)
    }

    func testFilmstripLoaderProducesThumbnails() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("strip.mov")
        try await SyntheticMovie.write(to: url, width: 160, height: 100, fps: 30, seconds: 2)
        XCTAssertEqual(Filmstrip.interval(forDuration: 600, targetCount: 120), 5)
        XCTAssertEqual(Filmstrip.interval(forDuration: 10, targetCount: 120), 0.5)
        let collector = FilmstripCollector()
        await FilmstripLoader.load(url: url, duration: 2, height: 40, targetCount: 4) { collector.record($0) }
        let strip = try XCTUnwrap(collector.last)
        XCTAssertEqual(strip.images.count, 5)
        XCTAssertGreaterThanOrEqual(strip.images.compactMap { $0 }.count, 4)
        let image = try XCTUnwrap(strip.image(at: 1.0))
        XCTAssertEqual(image.image.height, 40)
        XCTAssertEqual(image.image.width, 64)
    }

    func testAudioProcessorWritesADerivedTrack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("Voice.ketto"))
        try writeTone(to: bundle.micURL, seconds: 3, amplitude: 0.1, noise: 0.02)
        let options = AudioProcessor.Options(noiseRemoval: true, normalize: true)
        let url = AudioProcessor.derivedURL(for: bundle, options: options)
        XCTAssertEqual(url.lastPathComponent, "mic-nr1-norm1.caf")
        XCTAssertEqual(url.deletingLastPathComponent(), bundle.derivedDirectory)
        try AudioProcessor.process(micURL: bundle.micURL, to: url, options: options)

        let original = try WaveformLoader.load(url: bundle.micURL, bucketsPerSecond: 10)
        let processed = try WaveformLoader.load(url: url, bucketsPerSecond: 10)
        XCTAssertEqual(processed.peaks.count, original.peaks.count, "same length as the source")
        // The quiet half is noise only and comes down; the voiced half is brought up towards the target level.
        XCTAssertLessThan(processed.peak(from: 0.3, to: 1.2), original.peak(from: 0.3, to: 1.2) * 0.5)
        XCTAssertGreaterThan(processed.peak(from: 2, to: 2.9), original.peak(from: 2, to: 2.9) * 1.3)
        XCTAssertLessThanOrEqual(processed.peak(from: 0, to: 3), 1)

        // Identity options never write anything; a second run for the same options overwrites cleanly.
        let identity = AudioProcessor.Options(noiseRemoval: false, normalize: false)
        XCTAssertTrue(identity.isIdentity)
        try AudioProcessor.process(micURL: bundle.micURL, to: url, options: options)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.derivedDirectory.path).filter { $0.hasPrefix(".") }
        XCTAssertTrue(leftovers.isEmpty, "no temporary files left behind: \(leftovers)")
    }

    func testExportFollowsTheEditTimeline() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("Cut.ketto"))
        try await SyntheticMovie.write(to: bundle.screenURL, width: 320, height: 200, fps: 30, seconds: 2)
        try writeTone(to: bundle.micURL, seconds: 2, amplitude: 0.5, noise: 0)
        let events = SyntheticMovie.scaledEvents(SyntheticSource.events(duration: 2), toWidth: 320, height: 200)
        try bundle.write(events: events)
        var edit = EditDocument.default
        edit.clips = [Clip(id: "a", sourceStart: 0, sourceEnd: 0.5), Clip(id: "b", sourceStart: 1, sourceEnd: 2, speed: 2)]
        try bundle.write(edit: edit)

        let outputURL = directory.appendingPathComponent("cut.mp4")
        let exporter = Exporter(bundle: bundle, events: events, edit: edit, settings: ExportSettings(width: 640, height: 360, fps: 30), outputURL: outputURL)
        let url = try await exporter.run { _ in }
        XCTAssertEqual(exporter.duration, 1.0, accuracy: 1e-9)
        XCTAssertEqual(exporter.totalFrames, 30)
        let asset = AVURLAsset(url: url)
        XCTAssertEqual(try await asset.load(.duration).seconds, 1.0, accuracy: 0.1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "the voice track is exported on the edited timeline")
    }
}

/// Collects filmstrip deliveries from the loader's `@Sendable` progress callback.
private final class FilmstripCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var strips: [Filmstrip] = []

    func record(_ strip: Filmstrip) {
        lock.lock()
        strips.append(strip)
        lock.unlock()
    }

    var last: Filmstrip? {
        lock.lock()
        defer { lock.unlock() }
        return strips.last
    }
}
