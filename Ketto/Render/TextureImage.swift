import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import Metal
import UniformTypeIdentifiers

/// BGRA pixel data with helpers to convert to and from PNG. Used by golden-frame tests and thumbnails.
struct BGRAImage: Equatable, Sendable {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    var bytesPerRow: Int { width * 4 }

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Reads back a shared/managed BGRA8 texture.
    init(texture: MTLTexture) {
        width = texture.width
        height = texture.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
    }

    /// Reads back a BGRA pixel buffer.
    init?(pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let source = base.advanced(by: row * stride)
            bytes.withUnsafeMutableBytes { buffer in
                buffer.baseAddress!.advanced(by: row * width * 4).copyMemory(from: source, byteCount: width * 4)
            }
        }
    }

    init?(pngData: Data) {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(cgImage: image)
    }

    init?(cgImage image: CGImage) {
        width = image.width
        height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    func cgImage() -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func pngData() -> Data? {
        guard let image = cgImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A Metal-compatible, IOSurface-backed BGRA pixel buffer holding this image, for upload through
    /// `SourceTextureUploader`.
    func makePixelBuffer() -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        bytes.withUnsafeBytes { source in
            for row in 0..<height {
                base.advanced(by: row * stride).copyMemory(from: source.baseAddress!.advanced(by: row * bytesPerRow), byteCount: bytesPerRow)
            }
        }
        return buffer
    }

    /// Nearest-neighbour downscale used for thumbnails.
    func downscaled(toWidth targetWidth: Int) -> BGRAImage {
        guard targetWidth < width, targetWidth > 0 else { return self }
        let targetHeight = max(1, height * targetWidth / width)
        var out = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        for y in 0..<targetHeight {
            let sy = y * height / targetHeight
            for x in 0..<targetWidth {
                let sx = x * width / targetWidth
                let s = (sy * width + sx) * 4
                let d = (y * targetWidth + x) * 4
                out[d] = bytes[s]; out[d + 1] = bytes[s + 1]; out[d + 2] = bytes[s + 2]; out[d + 3] = bytes[s + 3]
            }
        }
        return BGRAImage(width: targetWidth, height: targetHeight, bytes: out)
    }

    struct Difference: Sendable {
        var meanAbsolute: Double
        var maxAbsolute: Int
        var fractionOverThreshold: Double
    }

    /// Per-channel (RGB only) comparison statistics.
    func difference(to other: BGRAImage, threshold: Int = 8) -> Difference? {
        guard width == other.width, height == other.height else { return nil }
        var total = 0
        var maxDiff = 0
        var over = 0
        let pixels = width * height
        for i in 0..<pixels {
            var pixelMax = 0
            for c in 0..<3 {
                let d = abs(Int(bytes[i * 4 + c]) - Int(other.bytes[i * 4 + c]))
                total += d
                pixelMax = max(pixelMax, d)
            }
            maxDiff = max(maxDiff, pixelMax)
            if pixelMax > threshold { over += 1 }
        }
        return Difference(meanAbsolute: Double(total) / Double(pixels * 3), maxAbsolute: maxDiff, fractionOverThreshold: Double(over) / Double(pixels))
    }
}
