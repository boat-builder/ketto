import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AppKit

struct ScreenCaptureConfiguration: Sendable {
    var source: CaptureSource
    var fps: Int = 60
    var captureSystemAudio: Bool = true
    /// Leave the Finder's desktop icons out of the capture (the wallpaper stays). Display and region modes only.
    var hideDesktopIcons: Bool = false
    var screenURL: URL
    var systemAudioURL: URL?

    var display: CaptureDisplay { source.display }
}

/// Owns the `SCStream`. Frames go straight to the HEVC writer, system audio to its own CAF track.
/// The cursor is NOT captured (`showsCursor = false`): it is composited from the event track at render time.
final class ScreenCaptureEngine: @unchecked Sendable {
    let configuration: ScreenCaptureConfiguration
    let clock: RecordingClock
    private(set) var videoWriter: VideoTrackWriter?
    private(set) var systemAudioWriter: AlignedAudioWriter?
    private(set) var capturedPixelSize: (width: Int, height: Int) = (0, 0)
    private var stream: SCStream?
    private var output: StreamOutput?
    private let videoQueue = DispatchQueue(label: "cc.ketto.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "cc.ketto.capture.audio", qos: .userInitiated)
    private let stopHandler: @Sendable (Error?) -> Void

    init(configuration: ScreenCaptureConfiguration, clock: RecordingClock, onStop: @escaping @Sendable (Error?) -> Void) {
        self.configuration = configuration
        self.clock = clock
        self.stopHandler = onStop
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == configuration.display.id }) else {
            throw CaptureError.displayNotFound
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let streamConfiguration = SCStreamConfiguration()
        let filter: SCContentFilter
        let scale: Double
        let width: Int
        let height: Int

        switch configuration.source {
        case .window(let window):
            guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else { throw CaptureError.windowNotFound }
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            scale = Double(filter.pointPixelScale)
            let size = CaptureSource.pixelSize(points: scWindow.frame.size, scale: scale)
            width = size.width
            height = size.height
        case .display, .region:
            // Ketto's own windows (the record HUD) never appear in the capture; with `hideDesktopIcons` the
            // Finder's icon layer goes too, leaving the wallpaper.
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            if configuration.hideDesktopIcons {
                let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
                let desktopIcons = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == iconLevel }
                filter = SCContentFilter(display: display, excludingWindows: ownWindows + desktopIcons)
            } else if let ownApp = content.applications.first(where: { $0.processID == ownPID }) {
                filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
            } else {
                filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            }
            scale = Double(filter.pointPixelScale)
            if case .region(let captureDisplay, let rect) = configuration.source {
                let region = CaptureSource.clamp(rect, to: captureDisplay.frame)
                streamConfiguration.sourceRect = CGRect(
                    x: region.minX - captureDisplay.frame.minX, y: region.minY - captureDisplay.frame.minY,
                    width: region.width, height: region.height
                )
                let size = CaptureSource.pixelSize(points: region.size, scale: scale)
                width = size.width
                height = size.height
            } else {
                width = Int((Double(display.width) * scale).rounded())
                height = Int((Double(display.height) * scale).rounded())
            }
        }
        capturedPixelSize = (width, height)

        streamConfiguration.width = width
        streamConfiguration.height = height
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1)))
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.colorSpaceName = CGColorSpace.sRGB
        streamConfiguration.showsCursor = false
        streamConfiguration.queueDepth = 8
        streamConfiguration.captureResolution = .best
        streamConfiguration.backgroundColor = CGColor.black
        streamConfiguration.capturesAudio = configuration.captureSystemAudio
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
        streamConfiguration.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) {
            streamConfiguration.showMouseClicks = false
        }

        let videoWriter = try VideoTrackWriter(url: configuration.screenURL, width: width, height: height, fps: configuration.fps, clock: clock)
        self.videoWriter = videoWriter
        var audioWriter: AlignedAudioWriter?
        if configuration.captureSystemAudio, let url = configuration.systemAudioURL {
            audioWriter = AlignedAudioWriter(url: url, clock: clock)
            systemAudioWriter = audioWriter
        }

        let output = StreamOutput(videoWriter: videoWriter, audioWriter: audioWriter, onStop: stopHandler)
        self.output = output
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoQueue)
        if configuration.captureSystemAudio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    /// Stops the stream and finalises the media files.
    func stop() async throws {
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                // A stream that already stopped (for example from the system's menu bar control) reports an error here.
            }
        }
        stream = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            videoQueue.async { [videoWriter] in
                Task {
                    do {
                        try await videoWriter?.finish()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioQueue.async { [systemAudioWriter] in
                systemAudioWriter?.finish()
                continuation.resume()
            }
        }
    }

    final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        private let videoWriter: VideoTrackWriter
        private let audioWriter: AlignedAudioWriter?
        private let onStop: @Sendable (Error?) -> Void

        init(videoWriter: VideoTrackWriter, audioWriter: AlignedAudioWriter?, onStop: @escaping @Sendable (Error?) -> Void) {
            self.videoWriter = videoWriter
            self.audioWriter = audioWriter
            self.onStop = onStop
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard sampleBuffer.isValid else { return }
            switch type {
            case .screen:
                videoWriter.append(sampleBuffer)
            case .audio:
                audioWriter?.append(sampleBuffer)
            default:
                break
            }
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            onStop(error)
        }
    }
}
