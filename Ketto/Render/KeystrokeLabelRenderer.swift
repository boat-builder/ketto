import Foundation
import CoreGraphics
import CoreText
import Metal

/// Rasterises keystroke labels ("⌘⇧S") into premultiplied BGRA textures: white text on a dark pill, drawn
/// with Core Text so it works off the main thread (the exporter renders on its own queue). Textures are
/// cached by text and pixel size; a label is drawn once per size and reused for every frame it is visible.
final class KeystrokeLabelRenderer: @unchecked Sendable {
    struct Label {
        let texture: MTLTexture
        /// Size of the pill in pixels, at the requested pixel font size.
        var size: CGSize { CGSize(width: texture.width, height: texture.height) }
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var cache: [String: (label: Label, used: UInt64)] = [:]
    private var counter: UInt64 = 0
    private static let capacity = 24

    init(device: MTLDevice) {
        self.device = device
    }

    /// The label texture for `text` at `fontPixelSize` pixels, or nil if it cannot be rasterised.
    func label(text: String, fontPixelSize: Double) -> Label? {
        let px = max(6, min(fontPixelSize.rounded(), 512))
        let key = "\(Int(px))|\(text)"
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        if let entry = cache[key] {
            cache[key] = (entry.label, counter)
            return entry.label
        }
        guard let label = rasterise(text: text, fontSize: px) else { return nil }
        if cache.count >= Self.capacity, let oldest = cache.min(by: { $0.value.used < $1.value.used }) {
            cache.removeValue(forKey: oldest.key)
        }
        cache[key] = (label, counter)
        return label
    }

    private func rasterise(text: String, fontSize: Double) -> Label? {
        let baseFont = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let font = CTFontCreateCopyWithSymbolicTraits(baseFont, fontSize, nil, .boldTrait, .boldTrait) ?? baseFont
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let paddingX = fontSize * 0.75
        let paddingY = fontSize * 0.32
        let width = max(2, Int((textWidth + 2 * paddingX).rounded(.up)))
        let height = max(2, Int((ascent + descent + 2 * paddingY).rounded(.up)))
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo
            ) else { return false }
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(true)
            let pill = CGPath(roundedRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), cornerWidth: CGFloat(height) / 2, cornerHeight: CGFloat(height) / 2, transform: nil)
            context.addPath(pill)
            context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 0.78))
            context.fillPath()
            context.addPath(pill)
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
            context.setLineWidth(max(1, fontSize * 0.05))
            context.strokePath()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: paddingX, y: paddingY + descent)
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Ketto keystroke label"
        bytes.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: buffer.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return Label(texture: texture)
    }
}
