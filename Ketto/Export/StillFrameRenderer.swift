import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Metal

/// Renders a single frame of the edit at canvas resolution — the same `(sources, edit, t) -> frame` function
/// the preview and the exporter use, fed from `AVAssetImageGenerator` instead of a player or a reader.
enum StillFrameRenderer {
    enum StillError: Error, LocalizedError {
        case noFrame

        var errorDescription: String? { "The recording has no frame at that time." }
    }

    /// The frame shown at output time `outputTime`.
    static func render(composer: FrameComposer, bundle: RecordingBundle, outputTime: Double) async throws -> BGRAImage {
        let sourceTime = composer.sourceTime(forOutput: outputTime)
        let screen = try await image(from: bundle.screenURL, at: sourceTime)
        var camera: CGImage?
        if composer.cameraAvailable, composer.edit.camera.enabled, bundle.hasCameraTrack {
            camera = try? await image(from: bundle.cameraURL, at: sourceTime)
        }
        let state = composer.state(at: outputTime)
        let renderer = try FrameRenderer()
        let uploader = SourceTextureUploader(device: renderer.device)
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
        guard let screenImage = BGRAImage(cgImage: screen), let screenBuffer = screenImage.makePixelBuffer(),
              let sourceTexture = uploader.upload(screenBuffer, commandBuffer: commandBuffer) else { throw RenderError.textureCreationFailed }
        var cameraTexture: MTLTexture?
        let cameraUploader = SourceTextureUploader(device: renderer.device)
        if let camera, let cameraImage = BGRAImage(cgImage: camera), let cameraBuffer = cameraImage.makePixelBuffer() {
            cameraTexture = cameraUploader.upload(cameraBuffer, commandBuffer: commandBuffer)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let target = try renderer.makeReadableTarget(width: composer.edit.canvas.width, height: composer.edit.canvas.height)
        try renderer.render(state: state, source: sourceTexture, camera: cameraTexture, into: target)
        return BGRAImage(texture: target)
    }

    private static func image(from url: URL, at seconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            return try await generator.image(at: time).image
        } catch {
            // Past the last frame (the event track can outlast the video by a few milliseconds): take the last one.
            let duration = try await asset.load(.duration)
            let last = duration - CMTime(value: 1, timescale: 60)
            guard last.seconds >= 0, last.seconds < seconds else { throw StillError.noFrame }
            return try await generator.image(at: last).image
        }
    }
}
