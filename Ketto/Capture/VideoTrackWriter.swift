import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Writes captured screen frames to `screen.mov` (HEVC, hardware encoded through VideoToolbox).
/// `append` must be called from a single serial queue; the writer session starts on the first complete frame,
/// which also establishes the shared recording clock.
final class VideoTrackWriter: @unchecked Sendable {
    let url: URL
    let width: Int
    let height: Int
    let fps: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let clock: RecordingClock

    private(set) var firstPresentationTime: CMTime?
    private(set) var lastPresentationTime: CMTime?
    private(set) var appendedFrames = 0
    private(set) var droppedFrames = 0
    private(set) var skippedIdleFrames = 0
    private var failed = false

    init(url: URL, width: Int, height: Int, fps: Int, clock: RecordingClock) throws {
        self.url = url
        self.width = width
        self.height = height
        self.fps = fps
        self.clock = clock
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        let settings = Self.outputSettings(width: width, height: height, fps: fps)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writerSetupFailed("Cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
    }

    static func outputSettings(width: Int, height: Int, fps: Int) -> [String: Any] {
        let pixelsPerSecond = Double(width * height) * Double(fps)
        let bitrate = Int(min(max(pixelsPerSecond * 0.10, 6_000_000), 90_000_000))
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// Frame status reported by ScreenCaptureKit for a sample buffer.
    static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// Appends a screen sample buffer from ScreenCaptureKit. Returns false if the frame was dropped. Frames
    /// captured during a pause are dropped, and frames after a pause are retimed so the movie stays continuous.
    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard !failed, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return false }
        if let status = Self.frameStatus(of: sampleBuffer), status != .complete, status != .started {
            skippedIdleFrames += 1
            return false
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return false }
        if firstPresentationTime == nil {
            clock.establish(pts.seconds)
            writer.startSession(atSourceTime: pts)
            firstPresentationTime = pts
        }
        guard let first = firstPresentationTime, let recordingTime = clock.recordingTime(forHost: pts.seconds) else { return false }
        let retimed = recordingTime == pts.seconds - first.seconds ? pts : CMTime(seconds: first.seconds + recordingTime, preferredTimescale: pts.timescale)
        if let last = lastPresentationTime, retimed <= last { return false }
        guard writer.status == .writing else {
            failed = true
            return false
        }
        guard input.isReadyForMoreMediaData else {
            droppedFrames += 1
            return false
        }
        let buffer: CMSampleBuffer
        if retimed == pts {
            buffer = sampleBuffer
        } else if let copy = Self.retimed(sampleBuffer, to: retimed) {
            buffer = copy
        } else {
            droppedFrames += 1
            return false
        }
        if input.append(buffer) {
            appendedFrames += 1
            lastPresentationTime = retimed
            return true
        }
        droppedFrames += 1
        if writer.status == .failed { failed = true }
        return false
    }

    /// A copy of `sampleBuffer` presented at `time` (the pixel data is shared, not copied).
    static func retimed(_ sampleBuffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }

    var error: Error? { writer.error }

    /// Recorded duration in seconds (first frame to last frame).
    var duration: Double {
        guard let first = firstPresentationTime, let last = lastPresentationTime else { return 0 }
        return (last - first).seconds
    }

    func finish() async throws {
        if writer.status == .writing {
            input.markAsFinished()
            await writer.finishWriting()
        }
        if writer.status == .failed, let error = writer.error { throw error }
    }
}

enum CaptureError: Error, LocalizedError {
    case screenRecordingDenied
    case microphoneDenied
    case cameraDenied
    case displayNotFound
    case windowNotFound
    case writerSetupFailed(String)
    case noFramesCaptured
    case streamStopped(Error?)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied: return "Screen Recording permission is required. Enable Ketto in System Settings → Privacy & Security → Screen Recording."
        case .microphoneDenied: return "Microphone permission was denied. Enable Ketto in System Settings → Privacy & Security → Microphone, or turn off microphone recording."
        case .cameraDenied: return "Camera permission was denied. Enable Ketto in System Settings → Privacy & Security → Camera, or turn off camera recording."
        case .displayNotFound: return "The selected display is no longer available."
        case .windowNotFound: return "The selected window is no longer open."
        case .writerSetupFailed(let reason): return "Could not start the recording: \(reason)"
        case .noFramesCaptured: return "No frames were captured."
        case .streamStopped(let error): return "The capture stream stopped: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}
