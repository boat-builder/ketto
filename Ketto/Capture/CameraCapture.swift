import Foundation
@preconcurrency import AVFoundation
import CoreMedia

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
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let url: URL
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let clock: RecordingClock
    private let queue = DispatchQueue(label: "cc.ketto.capture.camera", qos: .userInitiated)

    // Touched only on `queue`.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var lastTime: CMTime?
    private var failed = false
    private(set) var appendedFrames = 0
    private(set) var error: Error?

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
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.writerSetupFailed("Cannot use the selected camera") }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.writerSetupFailed("Cannot add camera output") }
        session.addOutput(output)
        session.commitConfiguration()
        try? FileManager.default.removeItem(at: url)
    }

    func start() {
        queue.async { [session] in
            session.startRunning()
        }
    }

    /// Stops the camera and finalises the file. Returns false when no frame was written (the file is removed).
    @discardableResult
    func stop() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                session.stopRunning()
                guard let writer, writer.status == .writing, appendedFrames > 0 else {
                    if let writer, writer.status == .writing { writer.cancelWriting() }
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: false)
                    return
                }
                input?.markAsFinished()
                writer.finishWriting { [self] in
                    continuation.resume(returning: self.finishedSuccessfully())
                }
            }
        }
    }

    /// Read after `finishWriting` completed, when nothing touches the writer any more.
    private func finishedSuccessfully() -> Bool {
        writer?.status == .completed
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !failed, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let sourceClock = session.synchronizationClock, CFEqual(sourceClock, CMClockGetHostTimeClock()) == false {
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
                appendedFrames += 1
                lastTime = time
            } else if writer.status == .failed {
                failed = true
                error = writer.error
            }
        } catch {
            failed = true
            self.error = error
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
