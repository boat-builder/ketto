import Foundation
import Metal
import CoreVideo
@testable import Recordito

/// Deterministic stand-ins for captured media so the renderer and export pipeline can be tested headlessly.
enum SyntheticSource {
    /// A BGRA test pattern: coloured tiles, a diagonal gradient, a "window" with a title bar and text-like bars.
    static func patternImage(width: Int, height: Int, frameIndex: Int = 0) -> BGRAImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let tile = ((x / 40) + (y / 40)) % 2
                var r = tile == 0 ? 235 : 210
                var g = tile == 0 ? 238 : 214
                var b = tile == 0 ? 243 : 222
                // Diagonal gradient band
                let band = (x + y + frameIndex * 3) % 160
                if band < 20 { r = 250; g = 200 + band; b = 120 }
                // Window
                let wx0 = width / 6, wy0 = height / 6, wx1 = width * 5 / 6, wy1 = height * 5 / 6
                if x >= wx0, x < wx1, y >= wy0, y < wy1 {
                    r = 252; g = 252; b = 254
                    if y < wy0 + 22 { r = 224; g = 226; b = 232 }
                    if y == wy0 || y == wy1 - 1 || x == wx0 || x == wx1 - 1 { r = 120; g = 124; b = 135 }
                    // Text-like bars
                    let line = (y - wy0 - 40)
                    if line >= 0, line % 18 < 8, x > wx0 + 30, x < wx1 - 30, (x / 30) % 4 != 3 {
                        r = 40; g = 44; b = 52
                    }
                    // A button
                    if x >= wx0 + 60, x < wx0 + 180, y >= wy1 - 70, y < wy1 - 30 { r = 30; g = 110; b = 240 }
                }
                bytes[i] = UInt8(b)
                bytes[i + 1] = UInt8(g)
                bytes[i + 2] = UInt8(r)
                bytes[i + 3] = 255
            }
        }
        return BGRAImage(width: width, height: height, bytes: bytes)
    }

    static func texture(device: MTLDevice, image: BGRAImage) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        image.bytes.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: buffer.baseAddress!, bytesPerRow: image.width * 4)
        }
        return texture
    }

    static func pixelBuffer(image: BGRAImage) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let stride = CVPixelBufferGetBytesPerRow(pb)
        image.bytes.withUnsafeBytes { src in
            for row in 0..<image.height {
                base.advanced(by: row * stride).copyMemory(from: src.baseAddress!.advanced(by: row * image.width * 4), byteCount: image.width * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Events for a 640×400 @1x source: two click clusters and a cursor path.
    static func events(duration: Double = 8) -> EventsDocument {
        var cursor: [CursorSample] = []
        let waypoints: [(Double, SIMD2<Double>)] = [(0, SIMD2(60, 60)), (1.5, SIMD2(200, 150)), (3.5, SIMD2(215, 160)), (5.0, SIMD2(450, 300)), (7.0, SIMD2(455, 305))]
        for i in 1..<waypoints.count {
            let (t0, p0) = waypoints[i - 1]
            let (t1, p1) = waypoints[i]
            let steps = Int((t1 - t0) * 60)
            for s in 0...steps {
                let u = Double(s) / Double(steps)
                let p = p0 + (p1 - p0) * u
                cursor.append(CursorSample(t: t0 + (t1 - t0) * u, x: p.x, y: p.y, type: s > steps / 2 && i == 3 ? .pointingHand : .arrow))
            }
        }
        let clicks = [
            ClickEvent(t: 1.7, x: 200, y: 150, phase: .down), ClickEvent(t: 1.8, x: 200, y: 150, phase: .up),
            ClickEvent(t: 3.6, x: 215, y: 160, phase: .down), ClickEvent(t: 3.7, x: 215, y: 160, phase: .up),
            ClickEvent(t: 5.2, x: 450, y: 300, phase: .down), ClickEvent(t: 5.3, x: 450, y: 300, phase: .up),
        ]
        let display = DisplayInfo(id: 7, width: 640, height: 400, scale: 1)
        return EventsDocument(recordingStart: 1_700_000_000, duration: duration, display: display, cursor: cursor, clicks: clicks, keys: [], focus: [FocusEvent(t: 0, bundleId: "com.example.synthetic", frame: CGRect(x: 106, y: 66, width: 427, height: 267))])
    }
}
