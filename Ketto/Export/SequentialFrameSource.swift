import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

/// Decodes a movie's frames in order and answers "which frame is on screen at time `t`" for a non-decreasing
/// sequence of times: the latest frame whose presentation time is at or before `t` (gaps in the recording hold
/// the previous frame). Both `screen.mov` and `camera.mov` go through one of these during an export; the
/// edited timeline visits the recording in order, so a forward-only reader is all that is needed.
final class SequentialFrameSource {
    let url: URL
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pendingSample: CMSampleBuffer?
    private var heldFrame: CVPixelBuffer?
    private var exhausted = false
    private(set) var started = false

    /// Sets the reader up (track loading is asynchronous); decoding starts with `start()`.
    init(url: URL) async throws {
        self.url = url
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        // Decode to BGRA. Decoder output is IOSurface-backed on macOS and uploads without a copy;
        // `SourceTextureUploader` stages anything that is not.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.readerSetupFailed }
        reader.add(output)
        self.reader = reader
        self.output = output
    }

    func start() throws {
        guard !started else { return }
        started = true
        guard reader.startReading() else { throw ExportError.readerFailed(reader.error) }
    }

    /// The frame to show at `t`. `changed` is true when a different frame than last time is returned, so the
    /// caller only uploads when necessary.
    func frame(at t: Double) throws -> (frame: CVPixelBuffer?, changed: Bool) {
        var changed = false
        while !exhausted {
            if pendingSample == nil {
                if let next = output.copyNextSampleBuffer() {
                    pendingSample = next
                } else {
                    if reader.status == .failed { throw ExportError.readerFailed(reader.error) }
                    exhausted = true
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

    func cancel() {
        if reader.status == .reading { reader.cancelReading() }
        pendingSample = nil
        heldFrame = nil
    }
}
