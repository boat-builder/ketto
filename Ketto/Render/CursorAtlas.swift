import Foundation
import CoreGraphics
import Metal

/// Rasterises high-resolution cursor glyphs (vector paths, 8 px per design point) into one atlas texture,
/// so scaled-up cursors stay crisp instead of being blown-up 32 px system bitmaps.
final class CursorAtlas: @unchecked Sendable {
    static let cellSize = 256
    static let columns = 4
    static let pixelsPerPoint = CGFloat(cellSize) / CGFloat(CursorGlyphs.designSize)

    let texture: MTLTexture
    let rows: Int

    init(device: MTLDevice) throws {
        let types = CursorGlyphs.atlasOrder
        let rows = (types.count + Self.columns - 1) / Self.columns
        self.rows = rows
        let width = Self.columns * Self.cellSize
        let height = rows * Self.cellSize
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo
            ) else { throw RenderError.contextCreationFailed }
            // Flip so that drawing happens in a y-down coordinate system whose row 0 is the top of the texture.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.interpolationQuality = .high
            for (index, type) in types.enumerated() {
                let column = index % Self.columns
                let row = index / Self.columns
                context.saveGState()
                context.translateBy(x: CGFloat(column * Self.cellSize), y: CGFloat(row * Self.cellSize))
                context.scaleBy(x: Self.pixelsPerPoint, y: Self.pixelsPerPoint)
                CursorGlyphDrawing.draw(type, in: context)
                context.restoreGState()
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.textureCreationFailed }
        bytes.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: buffer.baseAddress!, bytesPerRow: bytesPerRow)
        }
        self.texture = texture
    }

    /// Normalised uv rect of the glyph cell for `type`.
    func uvRect(for type: CursorType) -> SIMD4<Float> {
        let index = CursorGlyphs.atlasIndex(for: type)
        let column = index % Self.columns
        let row = index / Self.columns
        let w = Float(Self.cellSize) / Float(texture.width)
        let h = Float(Self.cellSize) / Float(texture.height)
        return SIMD4(Float(column) * w, Float(row) * h, w, h)
    }
}

/// Vector definitions of each glyph in a 32×32 point design box (y down).
enum CursorGlyphDrawing {
    static func draw(_ type: CursorType, in context: CGContext) {
        switch type {
        case .arrow: drawArrow(in: context)
        case .iBeam: drawIBeam(in: context)
        case .pointingHand: drawPointingHand(in: context)
        case .crosshair: drawCrosshair(in: context)
        case .resizeLeftRight: drawResize(in: context, vertical: false)
        case .resizeUpDown: drawResize(in: context, vertical: true)
        case .openHand: drawOpenHand(in: context)
        case .closedHand: drawClosedHand(in: context)
        case .notAllowed: drawNotAllowed(in: context)
        }
    }

    private static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Outlined shape: a wide stroke in `outline` underneath a fill in `fill`.
    private static func fillWithOutline(_ path: CGPath, in context: CGContext, fill: CGColor, outline: CGColor, width: CGFloat) {
        context.saveGState()
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.setLineWidth(width * 2)
        context.setStrokeColor(outline)
        context.strokePath()
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.restoreGState()
    }

    private static func strokeWithOutline(_ path: CGPath, in context: CGContext, stroke: CGColor, outline: CGColor, width: CGFloat, outlineWidth: CGFloat) {
        context.saveGState()
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.setLineWidth(width + outlineWidth * 2)
        context.setStrokeColor(outline)
        context.strokePath()
        context.addPath(path)
        context.setLineWidth(width)
        context.setStrokeColor(stroke)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawArrow(in context: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 3, y: 2))
        path.addLine(to: CGPoint(x: 3, y: 23.5))
        path.addLine(to: CGPoint(x: 8.6, y: 18.4))
        path.addLine(to: CGPoint(x: 12.4, y: 26.6))
        path.addLine(to: CGPoint(x: 16.4, y: 24.8))
        path.addLine(to: CGPoint(x: 12.7, y: 16.7))
        path.addLine(to: CGPoint(x: 20, y: 16.7))
        path.closeSubpath()
        fillWithOutline(path, in: context, fill: black, outline: white, width: 1.1)
    }

    private static func drawIBeam(in context: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 12, y: 5)); path.addLine(to: CGPoint(x: 20, y: 5))
        path.move(to: CGPoint(x: 12, y: 27)); path.addLine(to: CGPoint(x: 20, y: 27))
        path.move(to: CGPoint(x: 16, y: 5)); path.addLine(to: CGPoint(x: 16, y: 27))
        strokeWithOutline(path, in: context, stroke: black, outline: white, width: 1.6, outlineWidth: 1.0)
    }

    private static func drawPointingHand(in context: CGContext) {
        let path = CGMutablePath()
        // Palm
        path.addRoundedRect(in: CGRect(x: 8, y: 13, width: 16, height: 14), cornerWidth: 4, cornerHeight: 4)
        // Index finger
        path.addRoundedRect(in: CGRect(x: 10.5, y: 3, width: 4.5, height: 15), cornerWidth: 2.2, cornerHeight: 2.2)
        // Middle, ring, little fingers folded over the palm
        path.addRoundedRect(in: CGRect(x: 15.5, y: 10, width: 3.6, height: 6), cornerWidth: 1.8, cornerHeight: 1.8)
        path.addRoundedRect(in: CGRect(x: 19.3, y: 11, width: 3.4, height: 6), cornerWidth: 1.7, cornerHeight: 1.7)
        path.addRoundedRect(in: CGRect(x: 22.6, y: 12.5, width: 3.0, height: 5), cornerWidth: 1.5, cornerHeight: 1.5)
        // Thumb
        path.addRoundedRect(in: CGRect(x: 5.5, y: 15, width: 4, height: 8), cornerWidth: 2, cornerHeight: 2)
        fillWithOutline(path, in: context, fill: white, outline: black, width: 1.0)
    }

    private static func drawCrosshair(in context: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 16, y: 4)); path.addLine(to: CGPoint(x: 16, y: 13))
        path.move(to: CGPoint(x: 16, y: 19)); path.addLine(to: CGPoint(x: 16, y: 28))
        path.move(to: CGPoint(x: 4, y: 16)); path.addLine(to: CGPoint(x: 13, y: 16))
        path.move(to: CGPoint(x: 19, y: 16)); path.addLine(to: CGPoint(x: 28, y: 16))
        path.addEllipse(in: CGRect(x: 15, y: 15, width: 2, height: 2))
        strokeWithOutline(path, in: context, stroke: black, outline: white, width: 1.6, outlineWidth: 1.0)
    }

    private static func drawResize(in context: CGContext, vertical: Bool) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4, y: 16))
        path.addLine(to: CGPoint(x: 10, y: 10.5))
        path.addLine(to: CGPoint(x: 10, y: 14))
        path.addLine(to: CGPoint(x: 22, y: 14))
        path.addLine(to: CGPoint(x: 22, y: 10.5))
        path.addLine(to: CGPoint(x: 28, y: 16))
        path.addLine(to: CGPoint(x: 22, y: 21.5))
        path.addLine(to: CGPoint(x: 22, y: 18))
        path.addLine(to: CGPoint(x: 10, y: 18))
        path.addLine(to: CGPoint(x: 10, y: 21.5))
        path.closeSubpath()
        var transform = CGAffineTransform.identity
        if vertical {
            transform = CGAffineTransform(translationX: 16, y: 16).rotated(by: .pi / 2).translatedBy(x: -16, y: -16)
        }
        let finalPath = path.copy(using: &transform) ?? path
        fillWithOutline(finalPath, in: context, fill: black, outline: white, width: 1.0)
    }

    private static func drawOpenHand(in context: CGContext) {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 8, y: 14, width: 17, height: 13), cornerWidth: 5, cornerHeight: 5)
        let fingers: [(CGFloat, CGFloat, CGFloat)] = [(9, 8, 10), (13, 5, 12), (17.3, 5.5, 12), (21.5, 8, 10)]
        for (x, y, h) in fingers {
            path.addRoundedRect(in: CGRect(x: x, y: y, width: 3.6, height: h), cornerWidth: 1.8, cornerHeight: 1.8)
        }
        path.addRoundedRect(in: CGRect(x: 4, y: 15, width: 5, height: 8), cornerWidth: 2.5, cornerHeight: 2.5)
        fillWithOutline(path, in: context, fill: white, outline: black, width: 1.0)
    }

    private static func drawClosedHand(in context: CGContext) {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 7, y: 13, width: 18, height: 13), cornerWidth: 5, cornerHeight: 5)
        for x: CGFloat in [8.5, 12.5, 16.5, 20.5] {
            path.addRoundedRect(in: CGRect(x: x, y: 10, width: 3.6, height: 6), cornerWidth: 1.8, cornerHeight: 1.8)
        }
        fillWithOutline(path, in: context, fill: white, outline: black, width: 1.0)
    }

    private static func drawNotAllowed(in context: CGContext) {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 6, y: 6, width: 20, height: 20))
        path.move(to: CGPoint(x: 9.5, y: 9.5))
        path.addLine(to: CGPoint(x: 22.5, y: 22.5))
        strokeWithOutline(path, in: context, stroke: black, outline: white, width: 3, outlineWidth: 1)
    }
}
