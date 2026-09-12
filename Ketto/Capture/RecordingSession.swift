import Foundation
@preconcurrency import AVFoundation
import AppKit
import Observation

struct RecordingConfiguration: Sendable {
    var source: CaptureSource
    var fps: Int = 60
    var recordMicrophone: Bool = true
    var microphoneDeviceID: String?
    var recordSystemAudio: Bool = true
    var recordCamera: Bool = false
    var cameraDeviceID: String?
    var keystrokes: KeystrokeCaptureMode = .off
    var hideDesktopIcons: Bool = false
    var destinationDirectory: URL = ProjectLibrary.defaultDirectory

    init(source: CaptureSource, fps: Int = 60, recordMicrophone: Bool = true, microphoneDeviceID: String? = nil, recordSystemAudio: Bool = true, recordCamera: Bool = false, cameraDeviceID: String? = nil, keystrokes: KeystrokeCaptureMode = .off, hideDesktopIcons: Bool = false, destinationDirectory: URL = ProjectLibrary.defaultDirectory) {
        self.source = source
        self.fps = fps
        self.recordMicrophone = recordMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.recordSystemAudio = recordSystemAudio
        self.recordCamera = recordCamera
        self.cameraDeviceID = cameraDeviceID
        self.keystrokes = keystrokes
        self.hideDesktopIcons = hideDesktopIcons
        self.destinationDirectory = destinationDirectory
    }

    /// Display-only recording, as v1 configured it.
    init(display: CaptureDisplay, fps: Int = 60, recordMicrophone: Bool = true, microphoneDeviceID: String? = nil, recordSystemAudio: Bool = true, destinationDirectory: URL = ProjectLibrary.defaultDirectory) {
        self.init(source: .display(display), fps: fps, recordMicrophone: recordMicrophone, microphoneDeviceID: microphoneDeviceID, recordSystemAudio: recordSystemAudio, destinationDirectory: destinationDirectory)
    }

    var display: CaptureDisplay { source.display }
}

struct RecordingStatistics: Sendable {
    var duration: Double
    var appendedFrames: Int
    var droppedFrames: Int
    var skippedIdleFrames: Int
    var pixelWidth: Int
    var pixelHeight: Int
    /// Frames written to `camera.mov`; 0 when the camera was off or recorded nothing.
    var cameraFrames: Int = 0
    /// Why the camera track is missing or starts late although camera recording was on. Nil when the camera
    /// was off or recorded normally.
    var cameraWarning: String? = nil
}

/// Orchestrates one recording: screen + system audio (ScreenCaptureKit), microphone and camera (AVFoundation)
/// and the event track, all aligned on one clock, written into a fresh `.ketto` bundle. Pausing stops the
/// clock: samples and events that arrive during a pause are dropped, and everything after it is retimed so
/// the recording is one continuous file.
@Observable @MainActor
final class RecordingSession {
    enum State: Equatable {
        case idle, starting, recording, stopping, finished, failed
    }

    let configuration: RecordingConfiguration
    let bundle: RecordingBundle
    let clock = RecordingClock()
    private(set) var state: State = .idle
    private(set) var isPaused = false
    private(set) var statistics: RecordingStatistics?
    @ObservationIgnored private var engine: ScreenCaptureEngine?
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var microphoneWriter: AlignedAudioWriter?
    @ObservationIgnored private var camera: CameraCapture?
    @ObservationIgnored private var eventRecorder: EventRecorder
    @ObservationIgnored var onUnexpectedStop: (@MainActor (Error?) -> Void)?
    /// The camera's capture session while it runs, for the floating camera bubble's live picture. Set by
    /// `prepare()` or `start()`, cleared when the camera stops.
    private(set) var cameraPreviewSession: AVCaptureSession?
    /// Where the floating camera bubble sat over the captured area; set by the app right before `stop()`, and
    /// where the new project's camera overlay starts out.
    @ObservationIgnored var cameraPlacement: CameraPlacement?

    init(configuration: RecordingConfiguration) {
        self.configuration = configuration
        self.bundle = RecordingBundle(url: ProjectLibrary.newBundleURL(in: configuration.destinationDirectory))
        self.eventRecorder = EventRecorder(source: configuration.source, keystrokes: configuration.keystrokes)
    }

    /// Recording time so far, pauses excluded.
    var elapsed: TimeInterval {
        clock.elapsedRecordingTime()
    }

    /// Warms the camera up ahead of `start()`: the app runs this during the countdown, so the camera's start-up
    /// (typically a second or two) is over by the first screen frame and the camera track begins with the
    /// recording. Frames captured before the recording clock has a base are dropped. Asks for camera access if
    /// that has not happened yet, and throws when it is refused. Does nothing when the camera is off.
    func prepare() async throws {
        guard state == .idle, configuration.recordCamera, camera == nil else { return }
        guard await CapturePermissions.requestCamera() else { throw CaptureError.cameraDenied }
        guard state == .idle, camera == nil else { return }
        let camera = try CameraCapture(deviceID: configuration.cameraDeviceID, url: bundle.cameraURL, clock: clock)
        self.camera = camera
        cameraPreviewSession = camera.captureSession
        camera.start()
    }

    /// Releases a camera warmed up by `prepare()` when the recording never starts (the countdown was cancelled).
    func cancelPreparation() async {
        guard state == .idle, let camera else { return }
        self.camera = nil
        cameraPreviewSession = nil
        _ = await camera.stop()
    }

    func start() async throws {
        guard state == .idle else { return }
        state = .starting
        do {
            guard CapturePermissions.screenRecordingGranted else { throw CaptureError.screenRecordingDenied }
            if configuration.recordMicrophone {
                guard await CapturePermissions.requestMicrophone() else { throw CaptureError.microphoneDenied }
            }
            if configuration.recordCamera, camera == nil {
                guard await CapturePermissions.requestCamera() else { throw CaptureError.cameraDenied }
            }
            try RecordingBundle.create(at: bundle.url)

            let engineConfiguration = ScreenCaptureConfiguration(
                source: configuration.source,
                fps: configuration.fps,
                captureSystemAudio: configuration.recordSystemAudio,
                hideDesktopIcons: configuration.hideDesktopIcons,
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
                eventRecorder.updateSourceScale(Double(pixelSize.width) / max(configuration.source.frame.width, 1))
            }

            if configuration.recordMicrophone {
                let writer = AlignedAudioWriter(url: bundle.micURL, clock: clock)
                microphoneWriter = writer
                let microphone = try MicrophoneCapture(deviceID: configuration.microphoneDeviceID, writer: writer)
                self.microphone = microphone
                microphone.start()
            }
            if configuration.recordCamera, camera == nil {
                // Not warmed up by `prepare()`: start it now and accept that the track begins a little late.
                let camera = try CameraCapture(deviceID: configuration.cameraDeviceID, url: bundle.cameraURL, clock: clock)
                self.camera = camera
                cameraPreviewSession = camera.captureSession
                camera.start()
            }

            eventRecorder.start()
            state = .recording
        } catch {
            state = .failed
            await teardownAfterFailure()
            throw error
        }
    }

    /// Stops the clock. Nothing is written until `resume()`.
    func pause() {
        guard state == .recording, !isPaused else { return }
        clock.pause()
        isPaused = true
    }

    func resume() {
        guard state == .recording, isPaused else { return }
        clock.resume()
        isPaused = false
    }

    func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    /// Stops capture, finalises media, derives the event track and auto-zooms, and returns the bundle.
    func stop() async throws -> RecordingBundle {
        guard state == .recording else { return bundle }
        state = .stopping
        eventRecorder.stop()
        let hostNow = RecordingClock.now()
        let epochNow = Date().timeIntervalSince1970
        if isPaused {
            clock.resume(at: hostNow)
            isPaused = false
        }

        try await engine?.stop()
        await microphone?.stop()
        microphone = nil
        let cameraOutcome = await camera?.stop()
        camera = nil
        cameraPreviewSession = nil

        guard let engine, let videoWriter = engine.videoWriter, let base = clock.base, videoWriter.appendedFrames > 0 else {
            state = .failed
            throw CaptureError.noFramesCaptured
        }
        let duration = max(videoWriter.duration, clock.elapsedRecordingTime(at: hostNow))
        let pixelSize = engine.capturedPixelSize
        let events = eventRecorder.makeDocument(
            clock: clock,
            duration: duration,
            recordingStartEpoch: epochNow - (hostNow - base),
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height
        )
        try bundle.write(events: events)

        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        edit.camera.enabled = bundle.hasCameraTrack
        if bundle.hasCameraTrack {
            // The floating bubble showed a mirror image while recording; the video starts out looking the same.
            edit.camera.mirrored = true
            if let cameraPlacement {
                let layout = CanvasLayout.compute(canvas: edit.canvas, style: edit.style, sourceAspect: Double(pixelSize.width) / Double(max(pixelSize.height, 1)))
                edit.camera = cameraPlacement.overlay(from: edit.camera, layout: layout)
            }
        }
        try bundle.write(edit: edit)

        statistics = RecordingStatistics(
            duration: duration,
            appendedFrames: videoWriter.appendedFrames,
            droppedFrames: videoWriter.droppedFrames,
            skippedIdleFrames: videoWriter.skippedIdleFrames,
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height,
            cameraFrames: cameraOutcome?.frames ?? 0,
            cameraWarning: configuration.recordCamera ? Self.cameraWarning(for: cameraOutcome) : nil
        )
        await Self.writeThumbnail(for: bundle, at: min(1.0, duration / 2))
        state = .finished
        self.engine = nil
        return bundle
    }

    /// A camera track that starts later than this into the recording is worth telling the user about.
    static let cameraLateStartTolerance = 0.5

    /// Explains a missing or late camera track to the user, given how the camera capture ended. Nil when the
    /// camera recorded normally.
    nonisolated static func cameraWarning(for outcome: CameraCapture.Outcome?) -> String? {
        guard let outcome else {
            return "The camera was never started, so this project has no camera track."
        }
        if outcome.frames > 0 {
            if let start = outcome.firstFrameTime, start > cameraLateStartTolerance {
                return String(format: "The camera took %.1f s to start, so the camera bubble appears that far into the recording.", start)
            }
            return nil
        }
        if let error = outcome.error {
            return "The camera track could not be saved (\(error)), so this project has no camera track."
        }
        if outcome.receivedFrames == 0 {
            return "The camera delivered no frames, so this project has no camera track. Check that no other app is using the camera and that Ketto is allowed under System Settings → Privacy & Security → Camera."
        }
        return "The camera only delivered frames before the screen recording began, so this project has no camera track."
    }

    private func teardownAfterFailure() async {
        eventRecorder.stop()
        try? await engine?.stop()
        await microphone?.stop()
        _ = await camera?.stop()
        engine = nil
        microphone = nil
        camera = nil
        cameraPreviewSession = nil
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
