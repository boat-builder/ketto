import Foundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// A window that can be recorded. `frame` is in points, Core Graphics coordinates (origin at the top-left of
/// the main display, y down) — the same space as `CaptureDisplay.frame`.
struct CaptureWindow: Identifiable, Hashable, Sendable {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let bundleIdentifier: String?
    let frame: CGRect
    /// The display the window (mostly) sits on.
    let display: CaptureDisplay

    var displayName: String {
        title.isEmpty ? applicationName : "\(applicationName) — \(title)"
    }
}

/// What a recording captures: a whole display, one window, or a rectangle of a display.
enum CaptureSource: Hashable, Sendable {
    case display(CaptureDisplay)
    case window(CaptureWindow)
    /// `rect` is in points, Core Graphics coordinates, and lies within the display.
    case region(CaptureDisplay, CGRect)

    /// The display the capture happens on; the record HUD is placed on it.
    var display: CaptureDisplay {
        switch self {
        case .display(let display): return display
        case .window(let window): return window.display
        case .region(let display, _): return display
        }
    }

    /// The captured area in points, Core Graphics coordinates. Event coordinates are relative to its origin.
    var frame: CGRect {
        switch self {
        case .display(let display): return display.frame
        case .window(let window): return window.frame
        case .region(let display, let rect): return Self.clamp(rect, to: display.frame)
        }
    }

    var scale: Double { display.scale }

    /// Expected pixel size of the capture (even numbers, which every encoder accepts).
    var pixelSize: (width: Int, height: Int) {
        Self.pixelSize(points: frame.size, scale: scale)
    }

    var description: String {
        switch self {
        case .display(let display): return display.name
        case .window(let window): return window.displayName
        case .region(_, let rect): return "Region \(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) pt"
        }
    }

    static func pixelSize(points: CGSize, scale: Double) -> (width: Int, height: Int) {
        let width = max(2, Int((points.width * CGFloat(scale)).rounded()) & ~1)
        let height = max(2, Int((points.height * CGFloat(scale)).rounded()) & ~1)
        return (width, height)
    }

    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var r = rect.standardized.intersection(bounds)
        if r.isNull || r.width < 2 || r.height < 2 {
            r = CGRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32).intersection(bounds)
        }
        return r
    }

    /// The display a rectangle mostly lies on.
    static func display(for rect: CGRect, among displays: [CaptureDisplay]) -> CaptureDisplay? {
        var best: (display: CaptureDisplay, area: CGFloat)?
        for display in displays {
            let overlap = display.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if best == nil || area > best!.area { best = (display, area) }
        }
        return best?.display
    }
}

/// Lists windows that can be recorded. Uses ScreenCaptureKit, so it needs Screen Recording access.
enum WindowEnumerator {
    static func windows(displays: [CaptureDisplay]) async throws -> [CaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [CaptureWindow] = []
        for window in content.windows {
            guard window.isOnScreen, window.windowLayer == 0, window.frame.width >= 100, window.frame.height >= 60,
                  let application = window.owningApplication, application.processID != ownPID else { continue }
            let title = window.title ?? ""
            let applicationName = application.applicationName
            guard !(title.isEmpty && applicationName.isEmpty) else { continue }
            guard let display = CaptureSource.display(for: window.frame, among: displays) else { continue }
            result.append(CaptureWindow(
                id: window.windowID,
                title: title,
                applicationName: applicationName.isEmpty ? (application.bundleIdentifier) : applicationName,
                bundleIdentifier: application.bundleIdentifier.isEmpty ? nil : application.bundleIdentifier,
                frame: window.frame,
                display: display
            ))
        }
        return result
    }
}
