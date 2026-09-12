import Foundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// A small picture of a window for the picker. `CGImage` is immutable, so handing it to the main actor is safe.
struct WindowThumbnail: @unchecked Sendable {
    let image: CGImage
}

/// Renders thumbnails of the windows the picker lists, through ScreenCaptureKit's one-shot screenshot API, so
/// the picker shows what each window looks like rather than only its title.
enum WindowThumbnailer {
    /// Thumbnails `width` pixels wide for every window in `windows` that still exists. Missing entries are
    /// windows that went away or could not be captured; the picker falls back to the app icon for those.
    static func thumbnails(for windows: [CaptureWindow], width: Int = 320) async -> [CGWindowID: WindowThumbnail] {
        guard !windows.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return [:]
        }
        let wanted = Set(windows.map(\.id))
        var result: [CGWindowID: WindowThumbnail] = [:]
        for window in content.windows where wanted.contains(window.windowID) {
            guard !Task.isCancelled else { break }
            let frame = window.frame
            guard frame.width >= 1, frame.height >= 1 else { continue }
            let scale = Double(width) / Double(frame.width)
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = max(Int((Double(frame.height) * scale).rounded()), 1)
            configuration.showsCursor = false
            configuration.scalesToFit = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                result[window.windowID] = WindowThumbnail(image: image)
            }
        }
        return result
    }
}
