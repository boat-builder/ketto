import Foundation
import AppKit

/// Identifies which system cursor is currently shown by comparing a small rasterisation of
/// `NSCursor.currentSystem` against rasterisations of the known cursors. No permissions required.
@MainActor
final class CursorTypeDetector {
    private struct Signature {
        let type: CursorType
        let size: CGSize
        let pixels: [UInt8]
    }

    private static let sampleSize = 24
    private var signatures: [Signature] = []
    private var lastType: CursorType = .arrow
    private var lastImageIdentity: ObjectIdentifier?

    init() {
        let known: [(NSCursor, CursorType)] = [
            (.arrow, .arrow), (.iBeam, .iBeam), (.pointingHand, .pointingHand), (.crosshair, .crosshair),
            (.resizeLeftRight, .resizeLeftRight), (.resizeUpDown, .resizeUpDown),
            (.openHand, .openHand), (.closedHand, .closedHand), (.operationNotAllowed, .notAllowed),
            (.resizeLeft, .resizeLeftRight), (.resizeRight, .resizeLeftRight), (.resizeUp, .resizeUpDown), (.resizeDown, .resizeUpDown),
            (.iBeamCursorForVerticalLayout, .iBeam), (.contextualMenu, .arrow), (.dragCopy, .arrow), (.dragLink, .arrow), (.disappearingItem, .arrow),
        ]
        signatures = known.compactMap { cursor, type in
            guard let pixels = Self.rasterise(cursor.image) else { return nil }
            return Signature(type: type, size: cursor.image.size, pixels: pixels)
        }
    }

    /// The cursor type currently shown on screen (best match; `.arrow` when unknown).
    func current() -> CursorType {
        guard let cursor = NSCursor.currentSystem else { return lastType }
        let identity = ObjectIdentifier(cursor.image)
        if identity == lastImageIdentity { return lastType }
        lastImageIdentity = identity
        guard let pixels = Self.rasterise(cursor.image) else { return lastType }
        var best: (type: CursorType, score: Int)?
        for signature in signatures {
            var score = 0
            for i in stride(from: 3, to: pixels.count, by: 4) { // alpha channel only: shape match
                score += abs(Int(pixels[i]) - Int(signature.pixels[i]))
            }
            let sizePenalty = Int(abs(signature.size.width - cursor.image.size.width) + abs(signature.size.height - cursor.image.size.height)) * 50
            score += sizePenalty
            if best == nil || score < best!.score { best = (signature.type, score) }
        }
        let threshold = Self.sampleSize * Self.sampleSize * 40
        if let best, best.score < threshold {
            lastType = best.type
        } else {
            lastType = .arrow
        }
        return lastType
    }

    private static func rasterise(_ image: NSImage) -> [UInt8]? {
        let size = sampleSize
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: CGRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return ok ? bytes : nil
    }
}
