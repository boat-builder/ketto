import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Writes an animated GIF frame by frame through ImageIO, which quantises each frame to 256 colours.
final class GIFWriter {
    let url: URL
    let frameDelay: Double
    private let destination: CGImageDestination
    private(set) var frameCount = 0

    /// - Parameters:
    ///   - expectedFrames: how many frames will be added; ImageIO preallocates for them.
    ///   - fps: frame rate; GIF delays are in hundredths of a second, so 15 fps becomes 70 ms per frame.
    ///   - loop: whether the GIF loops forever.
    init(url: URL, expectedFrames: Int, fps: Int, loop: Bool) throws {
        self.url = url
        self.frameDelay = (100 / Double(max(fps, 1))).rounded() / 100
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, max(expectedFrames, 1), nil) else {
            throw ExportError.writerSetupFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop ? 0 : 1] as [CFString: Any],
        ]
        CGImageDestinationSetProperties(destination, properties as CFDictionary)
        self.destination = destination
    }

    func add(_ image: CGImage) {
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        frameCount += 1
    }

    /// Writes the file. Returns false when ImageIO could not finalise it.
    func finish() -> Bool {
        CGImageDestinationFinalize(destination)
    }
}
