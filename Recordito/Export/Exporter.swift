import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import os

struct ExportProgress: Equatable, Sendable {
    var framesRendered: Int
    var totalFrames: Int
    /// Wall-clock seconds since the export started.
    var elapsed: TimeInterval

    static let zero = ExportProgress(framesRendered: 0, totalFrames: 0, elapsed: 0)

    var fraction: Double {
        guard totalFrames > 0 else { return 0 }
        return min(1, Double(framesRendered) / Double(totalFrames))
    }
}

enum ExportError: Error, LocalizedError {
    case noVideoTrack
    case readerSetupFailed
    case readerFailed(Error?)
    case writerSetupFailed
    case writerFailed(Error?)
    case pixelBufferPoolUnavailable
    case renderSetupFailed(Error)
    case renderFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The project has no screen recording to export."
        case .readerSetupFailed: return "The screen recording could not be opened for reading."
        case .readerFailed(let error): return "Decoding the recording failed: \(error?.localizedDescription ?? "unknown error")"
        case .writerSetupFailed: return "The output file could not be created."
        case .writerFailed(let error): return "Writing the video failed: \(error?.localizedDescription ?? "unknown error")"
        case .pixelBufferPoolUnavailable: return "No output buffers were available for rendering."
        case .renderSetupFailed(let error): return "The renderer could not start: \(error.localizedDescription)"
        case .renderFailed: return "Rendering a frame failed."
        case .cancelled: return "The export was cancelled."
        }
    }
}

/// Renders a project to an MP4: decoded `screen.mov` frames go through the same `FrameRenderer` as the preview,
/// straight into the writer's pixel-buffer pool; `mic.caf` and `system.caf` are mixed to one AAC track at
/// export time only. All work after setup happens on one serial queue.
final class Exporter: @unchecked Sendable {
    let bundle: RecordingBundle
    let events: EventsDocument
    let edit: EditDocument
    let settings: ExportSettings
    /// Where the finished file is written. Callers typically pass a temporary location and hand the result to a
    /// `PublishDestination`.
    let outputURL: URL

    private let queue = DispatchQueue(label: "app.recordito.export", qos: .userInitiated)
    private let cancelRequested = OSAllocatedUnfairLock(initialState: false)

    // Set up in `prepare()` before any queue work starts, then touched only on `queue`.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoReader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var audioReader: AVAssetReader?
    private var audioOutput: AVAssetReaderAudioMixOutput?
    private var renderer: FrameRenderer?
    private var uploader: SourceTextureUploader?
    private var composer: FrameComposer?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (ExportProgress) -> Void)?
    private var pendingSample: CMSampleBuffer?
    private var heldFrame: CVPixelBuffer?
    private var sourceExhausted = false
    private var nextFrameIndex = 0
    private(set) var totalFrames = 0
    private(set) var duration: Double = 0
    private var videoFinished = false
    private var audioFinished = false
    private var finished = false
    private var startedAt = CFAbsoluteTimeGetCurrent()

    init(bundle: RecordingBundle, events: EventsDocument, edit: EditDocument, settings: ExportSettings, outputURL: URL) {
        self.bundle = bundle
        self.events = events
        self.edit = edit
        self.settings = settings
        self.outputURL = outputURL
    }

    var isCancelled: Bool { cancelRequested.withLock { $0 } }

    /// Stops the export as soon as the current frame finishes. `run` then throws `ExportError.cancelled`.
    /// Cancelling before `run` makes `run` fail immediately.
    func cancel() {
        cancelRequested.withLock { $0 = true }
        queue.async { [weak self] in
            // Only a run that is in flight (continuation set by `run`) can be failed here; `begin` handles the
            // case where cancellation arrived first.
            guard let self, self.continuation != nil, !self.finished else { return }
            self.fail(ExportError.cancelled)
        }
    }

    /// Runs the export and returns `outputURL`. Progress is reported from the export queue.
    func run(progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> URL {
        try await prepare()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                queue.async { [self] in
                    self.continuation = continuation
                    self.progressHandler = progress
                    self.begin()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    // MARK: - Setup

    private func prepare() async throws {
        let screenAsset = AVURLAsset(url: bundle.screenURL)
        let videoTracks = try await screenAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw ExportError.noVideoTrack }
        let assetDuration = try await screenAsset.load(.duration).seconds
        let duration = max(events.duration, assetDuration.isFinite ? assetDuration : 0)
        self.duration = duration
        totalFrames = max(1, Int((duration * Double(settings.fps)).rounded(.up)))
        let durationTime = CMTime(seconds: duration, preferredTimescale: CMTimeScale(ExportSettings.audioSampleRate))

        // Video: decode to BGRA. Decoder output is IOSurface-backed on macOS and uploads without a copy;
        // `SourceTextureUploader` stages anything that is not.
        let videoReader = try AVAssetReader(asset: screenAsset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard videoReader.canAdd(videoOutput) else { throw ExportError.readerSetupFailed }
        videoReader.add(videoOutput)

        // Audio: both tracks into one composition, mixed by the reader. Nothing on disk is touched.
        let composition = AVMutableComposition()
        var audioTracks: [AVAssetTrack] = []
        for url in [bundle.micURL, bundle.systemAudioURL] where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let audioDuration = try await asset.load(.duration)
            let length = CMTimeMinimum(audioDuration, durationTime)
            guard length.seconds > 0,
                  let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
            audioTracks.append(compositionTrack)
        }
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let reader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: ExportSettings.audioDecodeSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ExportError.readerSetupFailed }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: .zero, duration: durationTime)
            audioReader = reader
            audioOutput = output
        }

        // Writer: H.264 High + AAC in an MP4 with the movie header at the front.
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(videoInput) else { throw ExportError.writerSetupFailed }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: ExportSettings.audioOutputSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.writerSetupFailed }
            writer.add(input)
            audioInput = input
        }

        let renderer: FrameRenderer
        do {
            renderer = try FrameRenderer()
        } catch {
            throw ExportError.renderSetupFailed(error)
        }

        self.videoReader = videoReader
        self.videoOutput = videoOutput
        self.audioReader = audioReader
        self.audioOutput = audioOutput
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.renderer = renderer
        self.uploader = SourceTextureUploader(device: renderer.device)
        self.composer = FrameComposer(edit: edit, events: events, source: SourceInfo(display: events.display))
    }

    // MARK: - Queue work

    private func begin() {
        guard !finished else { return }
        if isCancelled {
            fail(ExportError.cancelled)
            return
        }
        guard let writer, let videoInput, let videoReader else {
            fail(ExportError.writerSetupFailed)
            return
        }
        startedAt = CFAbsoluteTimeGetCurrent()
        guard writer.startWriting() else {
            fail(ExportError.writerFailed(writer.error))
            return
        }
        writer.startSession(atSourceTime: .zero)
        guard videoReader.startReading() else {
            fail(ExportError.readerFailed(videoReader.error))
            return
        }
        if let audioReader, !audioReader.startReading() {
            fail(ExportError.readerFailed(audioReader.error))
            return
        }
        videoInput.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.pumpVideo()
        }
        audioInput?.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.pumpAudio()
        }
    }

    private func pumpVideo() {
        guard !finished, let videoInput, let adaptor else { return }
        while videoInput.isReadyForMoreMediaData {
            if finished { return }
            if isCancelled {
                fail(ExportError.cancelled)
                return
            }
            if nextFrameIndex >= totalFrames {
                videoInput.markAsFinished()
                videoFinished = true
                reportProgress()
                finishIfComplete()
                return
            }
            do {
                try renderFrame(index: nextFrameIndex, adaptor: adaptor)
            } catch {
                fail(error)
                return
            }
            nextFrameIndex += 1
            if nextFrameIndex % 6 == 0 { reportProgress() }
        }
    }

    private func pumpAudio() {
        guard !finished, let audioInput, let audioOutput, let audioReader else { return }
        while audioInput.isReadyForMoreMediaData {
            if finished { return }
            if isCancelled {
                fail(ExportError.cancelled)
                return
            }
            if let sample = audioOutput.copyNextSampleBuffer() {
                guard audioInput.append(sample) else {
                    fail(ExportError.writerFailed(writer?.error))
                    return
                }
            } else {
                if audioReader.status == .failed {
                    fail(ExportError.readerFailed(audioReader.error))
                    return
                }
                audioInput.markAsFinished()
                audioFinished = true
                finishIfComplete()
                return
            }
        }
    }

    /// Renders output frame `index` (time `index / fps`) into a pooled pixel buffer and appends it.
    private func renderFrame(index: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor) throws {
        guard let renderer, let uploader, let composer else { throw ExportError.renderFailed }
        let fps = Double(settings.fps)
        let t = Double(index) / fps
        let (sourceFrame, changed) = try sourceFrame(at: t)

        guard let pool = adaptor.pixelBufferPool else { throw ExportError.pixelBufferPoolUnavailable }
        var created: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        guard status == kCVReturnSuccess, let target = created else { throw ExportError.pixelBufferPoolUnavailable }
        guard let (targetTexture, cvTexture) = uploader.wrap(target),
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { throw ExportError.renderFailed }

        if changed, let sourceFrame {
            uploader.upload(sourceFrame, commandBuffer: commandBuffer)
        }
        let state = composer.state(at: t, fps: fps)
        renderer.encode(state: state, source: uploader.texture, into: targetTexture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(cvTexture) {}
        guard commandBuffer.status == .completed else { throw ExportError.renderFailed }

        let presentationTime = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.fps))
        guard adaptor.append(target, withPresentationTime: presentationTime) else {
            throw ExportError.writerFailed(writer?.error)
        }
    }

    /// The decoded source frame to show at `t`: the latest frame whose presentation time is at or before `t`
    /// (gaps in the recording hold the previous frame). `changed` is true when a different frame than last time
    /// is returned, so the caller only uploads when necessary.
    private func sourceFrame(at t: Double) throws -> (frame: CVPixelBuffer?, changed: Bool) {
        guard let videoOutput, let videoReader else { return (heldFrame, false) }
        var changed = false
        while !sourceExhausted {
            if pendingSample == nil {
                if let next = videoOutput.copyNextSampleBuffer() {
                    pendingSample = next
                } else {
                    if videoReader.status == .failed { throw ExportError.readerFailed(videoReader.error) }
                    sourceExhausted = true
                    break
                }
            }
            guard let sample = pendingSample else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if heldFrame == nil || pts <= t + 1e-4 {
                if let image = CMSampleBufferGetImageBuffer(sample) {
                    heldFrame = image
                    changed = true
                }
                pendingSample = nil
            } else {
                break
            }
        }
        return (heldFrame, changed)
    }

    private func finishIfComplete() {
        guard !finished, videoFinished, audioFinished || audioInput == nil, let writer else { return }
        finished = true
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async { self.complete() }
        }
    }

    private func complete() {
        guard let writer, let continuation else { return }
        self.continuation = nil
        if writer.status == .completed {
            reportProgress()
            continuation.resume(returning: outputURL)
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            continuation.resume(throwing: ExportError.writerFailed(writer.error))
        }
        tearDown()
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        videoReader?.cancelReading()
        audioReader?.cancelReading()
        if let writer, writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: outputURL)
        continuation?.resume(throwing: error)
        continuation = nil
        tearDown()
    }

    private func reportProgress() {
        let progress = ExportProgress(
            framesRendered: min(nextFrameIndex, totalFrames),
            totalFrames: totalFrames,
            elapsed: CFAbsoluteTimeGetCurrent() - startedAt
        )
        progressHandler?(progress)
    }

    private func tearDown() {
        pendingSample = nil
        heldFrame = nil
        videoOutput = nil
        videoReader = nil
        audioOutput = nil
        audioReader = nil
        adaptor = nil
        videoInput = nil
        audioInput = nil
        writer = nil
        composer = nil
        uploader = nil
        renderer = nil
        progressHandler = nil
    }
}
