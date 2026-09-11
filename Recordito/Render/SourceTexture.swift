import Foundation
import CoreVideo
import Metal

/// Uploads decoded BGRA frames (`CVPixelBuffer`) into a private, mipmapped Metal texture so minification
/// during zoom-out stays crisp. Shared by the preview and the exporter so both sample identical data.
final class SourceTextureUploader: @unchecked Sendable {
    let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private(set) var texture: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    /// Wraps a BGRA pixel buffer as a Metal texture without copying.
    func wrap(_ pixelBuffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }

    /// Copies `pixelBuffer` into the mipmapped source texture. The blit and mipmap generation are encoded on
    /// `commandBuffer`; the returned texture is valid once that buffer completes.
    @discardableResult
    func upload(_ pixelBuffer: CVPixelBuffer, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let (level0, cvTexture) = wrap(pixelBuffer) else { return nil }
        let width = level0.width, height = level0.height
        if texture == nil || texture!.width != width || texture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
            texture?.label = "Recordito source"
        }
        guard let target = texture, let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: level0, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if target.mipmapLevelCount > 1 { blit.generateMipmaps(for: target) }
        blit.endEncoding()
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(cvTexture) {} }
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
        return target
    }
}
