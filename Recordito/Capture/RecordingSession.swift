import Foundation
@preconcurrency import AVFoundation
import AppKit

struct RecordingConfiguration: Sendable {
    var display: CaptureDisplay
    var fps: Int = 60
    var recordMicrophone: Bool = true
    var microphoneDeviceID: String?
    var recordSystemAudio: Bool = true
    var destinationDirectory: URL = ProjectLibrary.defaultDirectory
}

struct RecordingStatistics: Sendable {
    var duration: Double
    var appendedFrames: Int
    var droppedFrames: Int
    var skippedIdleFrames: Int
    var pixelWidth: Int
    var pixelHeight: Int
}

/// Orchestrates one recording: screen + system audio (ScreenCaptureKit), microphone (AVFoundation) and the
/// event track, all aligned on one clock, written into a fresh `.recordito` bundle.
@MainActor
final class RecordingSession {
    enum State: Equatable {
        case idle, starting, recording, stopping, finished, failed
    }

    let configuration: RecordingConfiguration
    let bundle: RecordingBundle
    let clock = RecordingClock()
    private(set) var state: State = .idle
    private(set) var statistics: RecordingStatistics?
    private var engine: ScreenCaptureEngine?
    private var microphone: MicrophoneCapture?
    private var microphoneWriter: AlignedAudioWriter?
    private var eventRecorder: EventRecorder
    private var startedAt: Date?
    var onUnexpectedStop: (@MainActor (Error?) -> Void)?

    init(configuration: RecordingConfiguration) {
        self.configuration = configuration
        self.bundle = RecordingBundle(url: ProjectLibrary.newBundleURL(in: configuration.destinationDirectory))
        self.eventRecorder = EventRecorder(display: configuration.display)
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    func start() async throws {
        guard state == .idle else { return }
        state = .starting
        do {
            guard CapturePermissions.screenRecordingGranted else { throw CaptureError.screenRecordingDenied }
            if configuration.recordMicrophone {
                guard await CapturePermissions.requestMicrophone() else { throw CaptureError.microphoneDenied }
            }
            try RecordingBundle.create(at: bundle.url)

            let engineConfiguration = ScreenCaptureConfiguration(
                display: configuration.display,
                fps: configuration.fps,
                captureSystemAudio: configuration.recordSystemAudio,
                screenURL: bundle.screenURL,
                systemAudioURL: configuration.recordSystemAudio ? bundle.systemAudioURL : nil
            )
            let engine = ScreenCaptureEngine(configuration: engineConfiguration, clock: clock) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.onUnexpectedStop?(error)
                }
            }
            self.engine = engine
            try await engine.start()
            let pixelSize = engine.capturedPixelSize
            if pixelSize.width > 0 {
                eventRecorder.updateSourceScale(Double(pixelSize.width) / max(configuration.display.frame.width, 1))
            }

            if configuration.recordMicrophone {
                let writer = AlignedAudioWriter(url: bundle.micURL, clock: clock)
                microphoneWriter = writer
                let microphone = try MicrophoneCapture(deviceID: configuration.microphoneDeviceID, writer: writer)
                self.microphone = microphone
                microphone.start()
            }

            eventRecorder.start()
            startedAt = Date()
            state = .recording
        } catch {
            state = .failed
            await teardownAfterFailure()
            throw error
        }
    }

    /// Stops capture, finalises media, derives the event track and auto-zooms, and returns the bundle.
    func stop() async throws -> RecordingBundle {
        guard state == .recording else { return bundle }
        state = .stopping
        eventRecorder.stop()
        let hostNow = RecordingClock.now()
        let epochNow = Date().timeIntervalSince1970

        try await engine?.stop()
        await microphone?.stop()
        microphone = nil

        guard let engine, let videoWriter = engine.videoWriter, let base = clock.base, videoWriter.appendedFrames > 0 else {
            state = .failed
            throw CaptureError.noFramesCaptured
        }
        let duration = max(videoWriter.duration, hostNow - base)
        let pixelSize = engine.capturedPixelSize
        let events = eventRecorder.makeDocument(
            timeBase: base,
            duration: duration,
            recordingStartEpoch: epochNow - (hostNow - base),
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height
        )
        try bundle.write(events: events)

        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        try bundle.write(edit: edit)

        statistics = RecordingStatistics(
            duration: duration,
            appendedFrames: videoWriter.appendedFrames,
            droppedFrames: videoWriter.droppedFrames,
            skippedIdleFrames: videoWriter.skippedIdleFrames,
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height
        )
        await Self.writeThumbnail(for: bundle, at: min(1.0, duration / 2))
        state = .finished
        self.engine = nil
        return bundle
    }

    private func teardownAfterFailure() async {
        eventRecorder.stop()
        try? await engine?.stop()
        await microphone?.stop()
        engine = nil
        microphone = nil
        if (try? FileManager.default.contentsOfDirectory(atPath: bundle.url.path))?.isEmpty ?? false {
            try? FileManager.default.removeItem(at: bundle.url)
        }
    }

    static func writeThumbnail(for bundle: RecordingBundle, at time: Double) async {
        let asset = AVURLAsset(url: bundle.screenURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let result = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
              let image = BGRAImage(cgImage: result.image),
              let data = image.pngData() else { return }
        try? data.write(to: bundle.thumbnailURL, options: .atomic)
    }
}
