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

/// Renders a project to a movie or a GIF. Every output frame maps through the edited timeline to a recording
/// time; the screen and camera frames for that time come from forward-only readers, go through the same
/// `FrameRenderer` as the preview, and land in the writer's pixel-buffer pool (movies) or in a readable
/// texture handed to ImageIO (GIF). Audio is read from the same composition the player uses, mixed with the
/// document's volumes, and encoded to AAC. All work after setup happens on one serial queue.
final class Exporter: @unchecked Sendable {
    let bundle: RecordingBundle
    let events: EventsDocument
    let edit: EditDocument
    let settings: ExportSettings
    /// Where the finished file is written. Callers typically pass a temporary location and hand the result to a
    /// `PublishDestination`.
    let outputURL: URL
    /// The processed voice track to use instead of `mic.caf`, when noise removal or normalisation produced one.
    let voiceURL: URL?

    private let queue = DispatchQueue(label: "cc.ketto.export", qos: .userInitiated)
    private let cancelRequested = OSAllocatedUnfairLock(initialState: false)

    // Set up in `prepare()` before any queue work starts, then touched only on `queue`.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioReader: AVAssetReader?
    private var audioOutput: AVAssetReaderAudioMixOutput?
    private var screenSource: SequentialFrameSource?
    private var cameraSource: SequentialFrameSource?
    private var gif: GIFWriter?
    private var gifTarget: MTLTexture?
    private var renderer: FrameRenderer?
    private var uploader: SourceTextureUploader?
    private var cameraUploader: SourceTextureUploader?
    private var composer: FrameComposer?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (ExportProgress) -> Void)?
    private var nextFrameIndex = 0
    private(set) var totalFrames = 0
    private(set) var duration: Double = 0
    private var videoFinished = false
    private var audioFinished = false
    private var finished = false
    private var startedAt = CFAbsoluteTimeGetCurrent()

    init(bundle: RecordingBundle, events: EventsDocument, edit: EditDocument, settings: ExportSettings, outputURL: URL, voiceURL: URL? = nil) {
        self.bundle = bundle
        self.events = events
        self.edit = edit
        self.settings = settings
        self.outputURL = outputURL
        self.voiceURL = voiceURL
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
        let assetDuration = try await screenAsset.load(.duration).seconds
        let hasCamera = bundle.hasCameraTrack && edit.camera.enabled
        // The composer lays the edited timeline over the recording; every output frame maps to a source time.
        let composer = FrameComposer(edit: edit, events: events, source: SourceInfo(display: events.display), cameraAvailable: hasCamera, sourceDuration: assetDuration.isFinite ? assetDuration : 0)
        let duration = composer.duration
        self.duration = duration
        totalFrames = max(1, Int((duration * Double(settings.fps)).rounded(.up)))
        let durationTime = CMTime(seconds: duration, preferredTimescale: CMTimeScale(ExportSettings.audioSampleRate))

        let screenSource = try await SequentialFrameSource(url: bundle.screenURL)
        var cameraSource: SequentialFrameSource?
        if hasCamera {
            cameraSource = try? await SequentialFrameSource(url: bundle.cameraURL)
        }

        let renderer: FrameRenderer
        do {
            renderer = try FrameRenderer()
        } catch {
            throw ExportError.renderSetupFailed(error)
        }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let fileType = settings.container.fileType {
            // Audio: both tracks laid on the edited timeline in one composition (the same one the player uses),
            // mixed by the reader with the document's volumes. Nothing on disk is touched.
            let media = try await CompositionBuilder.screenMedia(for: PlaybackSource(bundle: bundle, timeline: composer.timeline, audio: edit.audio, micURL: voiceURL))
            let audioTracks = media.composition.tracks(withMediaType: .audio)
            var audioReader: AVAssetReader?
            var audioOutput: AVAssetReaderAudioMixOutput?
            if !audioTracks.isEmpty {
                let reader = try AVAssetReader(asset: media.composition)
                let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: ExportSettings.audioDecodeSettings)
                output.audioMix = media.audioMix
                output.audioTimePitchAlgorithm = .spectral
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw ExportError.readerSetupFailed }
                reader.add(output)
                reader.timeRange = CMTimeRange(start: .zero, duration: durationTime)
                audioReader = reader
                audioOutput = output
            }

            // Writer: the chosen codec plus AAC, with the movie header at the front.
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
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
            self.audioReader = audioReader
            self.audioOutput = audioOutput
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
        } else {
            gif = try GIFWriter(url: outputURL, expectedFrames: totalFrames, fps: settings.fps, loop: settings.loop)
            gifTarget = try renderer.makeReadableTarget(width: settings.width, height: settings.height)
        }

        self.screenSource = screenSource
        self.cameraSource = cameraSource
        self.renderer = renderer
        self.uploader = SourceTextureUploader(device: renderer.device)
        self.cameraUploader = cameraSource == nil ? nil : SourceTextureUploader(device: renderer.device)
        self.composer = composer
    }

    // MARK: - Queue work

    private func begin() {
        guard !finished else { return }
        if isCancelled {
            fail(ExportError.cancelled)
            return
        }
        guard let screenSource else {
            fail(ExportError.readerSetupFailed)
            return
        }
        startedAt = CFAbsoluteTimeGetCurrent()
        do {
            try screenSource.start()
            try cameraSource?.start()
        } catch {
            fail(error)
            return
        }
        if gif != nil {
            pumpGIF()
            return
        }
        guard let writer, let videoInput else {
            fail(ExportError.writerSetupFailed)
            return
        }
        guard writer.startWriting() else {
            fail(ExportError.writerFailed(writer.error))
            return
        }
        writer.startSession(atSourceTime: .zero)
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
                try renderMovieFrame(index: nextFrameIndex, adaptor: adaptor)
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

    /// Renders every frame into the GIF, one after the other, checking for cancellation between frames.
    private func pumpGIF() {
        guard let gif, let gifTarget else { return }
        while nextFrameIndex < totalFrames {
            if isCancelled {
                fail(ExportError.cancelled)
                return
            }
            do {
                try renderFrame(index: nextFrameIndex, into: gifTarget)
                guard let image = BGRAImage(texture: gifTarget).cgImage() else { throw ExportError.renderFailed }
                gif.add(image)
            } catch {
                fail(error)
                return
            }
            nextFrameIndex += 1
            if nextFrameIndex % 6 == 0 { reportProgress() }
        }
        finished = true
        guard let continuation else { return }
        self.continuation = nil
        if gif.finish() {
            reportProgress()
            continuation.resume(returning: outputURL)
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            continuation.resume(throwing: ExportError.writerFailed(nil))
        }
        tearDown()
    }

    /// Renders output frame `index` (time `index / fps`) into a pooled pixel buffer and appends it.
    private func renderMovieFrame(index: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor) throws {
        guard let uploader else { throw ExportError.renderFailed }
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.pixelBufferPoolUnavailable }
        var created: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        guard status == kCVReturnSuccess, let target = created else { throw ExportError.pixelBufferPoolUnavailable }
        guard let (targetTexture, cvTexture) = uploader.wrap(target) else { throw ExportError.renderFailed }
        try renderFrame(index: index, into: targetTexture)
        withExtendedLifetime(cvTexture) {}
        let presentationTime = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.fps))
        guard adaptor.append(target, withPresentationTime: presentationTime) else {
            throw ExportError.writerFailed(writer?.error)
        }
    }

    /// Composes output frame `index` into `target`: the screen and camera frames for the recording time the
    /// edited timeline maps it to, then the renderer. Clips are in recording order, so the readers only ever
    /// move forwards.
    private func renderFrame(index: Int, into target: MTLTexture) throws {
        guard let renderer, let uploader, let composer, let screenSource else { throw ExportError.renderFailed }
        let fps = Double(settings.fps)
        let t = Double(index) / fps
        let sourceTime = composer.sourceTime(forOutput: t)
        let (screenFrame, screenChanged) = try screenSource.frame(at: sourceTime)
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { throw ExportError.renderFailed }
        if screenChanged, let screenFrame {
            uploader.upload(screenFrame, commandBuffer: commandBuffer)
        }
        var cameraTexture: MTLTexture?
        if let cameraSource, let cameraUploader {
            let (cameraFrame, cameraChanged) = try cameraSource.frame(at: sourceTime)
            if cameraChanged, let cameraFrame {
                cameraUploader.upload(cameraFrame, commandBuffer: commandBuffer)
            }
            cameraTexture = cameraUploader.texture
        }
        let state = composer.state(at: t, fps: fps)
        renderer.encode(state: state, source: uploader.texture, camera: cameraTexture, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw ExportError.renderFailed }
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
        screenSource?.cancel()
        cameraSource?.cancel()
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
        screenSource = nil
        cameraSource = nil
        audioOutput = nil
        audioReader = nil
        adaptor = nil
        videoInput = nil
        audioInput = nil
        writer = nil
        gif = nil
        gifTarget = nil
        composer = nil
        uploader = nil
        cameraUploader = nil
        renderer = nil
        progressHandler = nil
    }
}
