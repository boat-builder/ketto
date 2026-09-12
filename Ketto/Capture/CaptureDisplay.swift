import Foundation
import AppKit
import CoreGraphics

/// A display that can be recorded. `frame` is in points using Core Graphics coordinates (origin at the
/// top-left of the main display, y down), which is what ScreenCaptureKit and the window server use.
struct CaptureDisplay: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
    let isMain: Bool

    var pointSize: CGSize { frame.size }
}

enum DisplayEnumerator {
    /// Enumerates displays through AppKit so the picker works before Screen Recording access is granted.
    @MainActor
    static func displays() -> [CaptureDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(id)
            let scale = Double(screen.backingScaleFactor)
            return CaptureDisplay(
                id: id,
                name: screen.localizedName,
                frame: bounds,
                pixelWidth: Int((bounds.width * CGFloat(scale)).rounded()),
                pixelHeight: Int((bounds.height * CGFloat(scale)).rounded()),
                scale: scale,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
    }

    /// Converts a point in AppKit screen coordinates (origin bottom-left of the main display) to
    /// Core Graphics coordinates (origin top-left of the main display).
    @MainActor
    static func cgPoint(fromCocoa point: CGPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: mainHeight - point.y)
    }

    /// The inverse of `cgPoint(fromCocoa:)`: Core Graphics screen coordinates to AppKit's.
    @MainActor
    static func cocoaPoint(fromCG point: CGPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: mainHeight - point.y)
    }
}
