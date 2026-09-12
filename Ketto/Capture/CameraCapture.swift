import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import os

struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool

    static func available() -> [CameraDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID
        return session.devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID) }
    }
}

/// Records the webcam to `camera.mov` (H.264, 720p at most) as a separate track in recording time: frame
/// timestamps are converted to the host clock and mapped through the shared `RecordingClock`, so the camera
/// lines up with the screen and the audio, frames captured during a pause are dropped, and the file starts at
/// recording time zero whatever the camera's warm-up took.
///
/// The capture session can be started ahead of the recording (`RecordingSession.prepare()` does so during the
/// countdown) so the camera has warmed up by the first screen frame: frames that arrive before the clock has a
/// base are simply dropped, and the track begins with the recording instead of a second or two in.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// What a capture ended with. `frames` is the number written to `camera.mov` (0 means the file was removed);
    /// `receivedFrames` counts everything the device delivered, warm-up included, so a camera that never produced
    /// a picture can be told apart from a writer failure. `firstFrameTime` is the recording time of the first
    /// frame in the file.
    struct Outcome: Equatable, Sendable {
        var frames: Int
        var receivedFrames: Int
        var firstFrameTime: Double?
        /// A description of what went wrong, when something did.
        var error: String?
    }

    let url: URL
    /// The capture session, so a live preview (`CameraPreviewView`) can show what is being recorded.
    let captureSession = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let clock: RecordingClock
    /// `startRunning()` and `stopRunning()` block until the session has actually started or stopped, so they run
    /// on their own queue rather than on the one that delivers frames.
    private let sessionQueue = DispatchQueue(label: "cc.ketto.capture.camera.session", qos: .userInitiated)
    /// Delivers frames and owns the writer.
    private let queue = DispatchQueue(label: "cc.ketto.capture.camera", qos: .userInitiated)
    private let runtimeError = OSAllocatedUnfairLock<String?>(initialState: nil)
    private var runtimeErrorObserver: NSObjectProtocol?

    // Touched only on `queue`.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var stopped = false
    private var lastTime: CMTime?
    private var firstFrameTime: Double?
    private var failed = false
    private var appendedFrames = 0
    private var receivedFrames = 0
    private var writeError: Error?

    private static let timescale: CMTimeScale = 600

    init(deviceID: String?, url: URL, clock: RecordingClock) throws {
        self.url = url
        self.clock = clock
        super.init()
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .video)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let device else { throw CaptureError.writerSetupFailed("No camera is available") }
        captureSession.beginConfiguration()
        if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else { throw CaptureError.writerSetupFailed("Cannot use the selected camera") }
        captureSession.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard captureSession.canAddOutput(output) else { throw CaptureError.writerSetupFailed("Cannot add camera output") }
        captureSession.addOutput(output)
        captureSession.commitConfiguration()
        try? FileManager.default.removeItem(at: url)
        // A camera that is unplugged or claimed by another process mid-recording stops the session with an
        // error rather than an exception; remember it so the outcome can say what happened.
        runtimeErrorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: captureSession, queue: nil) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "the camera stopped unexpectedly"
            self?.runtimeError.withLock { $0 = $0 ?? message }
        }
    }

    deinit {
        if let runtimeErrorObserver { NotificationCenter.default.removeObserver(runtimeErrorObserver) }
    }

    /// Starts the camera. Safe to call before the recording clock exists: frames are dropped until it does.
    func start() {
        sessionQueue.async { [captureSession] in
            if !captureSession.isRunning { captureSession.startRunning() }
        }
    }

    /// Stops the camera and finalises the file. When no frame was written the file is removed and `frames` is 0.
    func stop() async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            sessionQueue.async { [self] in
                if captureSession.isRunning { captureSession.stopRunning() }
                // Frames already queued for delivery are handled first; the queue is serial.
                queue.async { [self] in
                    finish(continuation)
                }
            }
        }
    }

    /// On `queue`, once the session has stopped: closes the file, or removes it when nothing was written.
    private func finish(_ continuation: CheckedContinuation<Outcome, Never>) {
        stopped = true
        let received = receivedFrames
        let error = writeError?.localizedDescription ?? runtimeError.withLock { $0 }
        guard let writer, let input, writer.status == .writing, appendedFrames > 0 else {
            if let writer, writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            continuation.resume(returning: Outcome(frames: 0, receivedFrames: received, firstFrameTime: nil, error: error))
            return
        }
        input.markAsFinished()
        let frames = appendedFrames
        let firstFrame = self.firstFrameTime
        let fileURL = self.url
        writer.finishWriting {
            if writer.status == .completed {
                continuation.resume(returning: Outcome(frames: frames, receivedFrames: received, firstFrameTime: firstFrame, error: nil))
            } else {
                try? FileManager.default.removeItem(at: fileURL)
                continuation.resume(returning: Outcome(frames: 0, receivedFrames: received, firstFrameTime: nil, error: writer.error?.localizedDescription ?? error))
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, !failed, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        receivedFrames += 1
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let sourceClock = captureSession.synchronizationClock, CFEqual(sourceClock, CMClockGetHostTimeClock()) == false {
            pts = CMSyncConvertTime(pts, from: sourceClock, to: CMClockGetHostTimeClock())
        }
        guard let recordingTime = clock.recordingTime(forHost: pts.seconds), recordingTime >= 0 else { return }
        let time = CMTime(seconds: recordingTime, preferredTimescale: Self.timescale)
        if let last = lastTime, time <= last { return }
        do {
            if writer == nil {
                try setUpWriter(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
            }
            guard let writer, let input, writer.status == .writing else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: .zero)
                sessionStarted = true
            }
            guard input.isReadyForMoreMediaData, let retimed = VideoTrackWriter.retimed(sampleBuffer, to: time) else { return }
            if input.append(retimed) {
                if appendedFrames == 0 { firstFrameTime = recordingTime }
                appendedFrames += 1
                lastTime = time
            } else if writer.status == .failed {
                failed = true
                writeError = writer.error
            }
        } catch {
            failed = true
            writeError = error
        }
    }

    private func setUpWriter(width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let pixelsPerSecond = Double(width * height) * 30
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(min(max(pixelsPerSecond * 0.12, 1_500_000), 12_000_000)),
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: 30,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writerSetupFailed("Cannot add camera video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "camera startWriting failed")
        }
        self.writer = writer
        self.input = input
    }
}
