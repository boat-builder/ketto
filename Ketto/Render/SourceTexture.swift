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
    /// IOSurface-backed buffers are wrapped without a copy; anything else goes through a shared staging texture.
    @discardableResult
    func upload(_ pixelBuffer: CVPixelBuffer, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let level0: MTLTexture
        let cvTexture: CVMetalTexture?
        if let (wrapped, wrappedTexture) = wrap(pixelBuffer) {
            level0 = wrapped
            cvTexture = wrappedTexture
        } else if let staged = stage(pixelBuffer) {
            level0 = staged
            cvTexture = nil
        } else {
            return nil
        }
        let width = level0.width, height = level0.height
        if texture == nil || texture!.width != width || texture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
            texture?.label = "Ketto source"
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

    /// Fallback for BGRA buffers that are not IOSurface-backed: copies the rows into a shared staging texture.
    private func stage(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        if stagingTexture == nil || stagingTexture!.width != width || stagingTexture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            stagingTexture = device.makeTexture(descriptor: descriptor)
            stagingTexture?.label = "Ketto staging"
        }
        guard let staging = stagingTexture else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        staging.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
        return staging
    }

    private var stagingTexture: MTLTexture?
}
