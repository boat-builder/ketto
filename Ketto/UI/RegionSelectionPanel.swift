import AppKit

/// A full-display, see-through panel on which the user drags out the rectangle to record. The result is in
/// points, Core Graphics coordinates (the space `CaptureSource.region` uses). Escape cancels.
@MainActor
final class RegionSelectionPanel: NSPanel {
    private let completion: (CGRect?) -> Void
    private var finished = false

    init(display: CaptureDisplay, initial: CGRect?, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }
        let frame = screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: frame.size))
        view.initialSelection = initial.map { view.convert(fromCG: $0, windowFrame: frame) }
        view.onFinish = { [weak self] rect in
            guard let self else { return }
            self.finish(rect.map { view.convertToCG($0, windowFrame: self.frame) })
        }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }

    private func finish(_ rect: CGRect?) {
        guard !finished else { return }
        finished = true
        orderOut(nil)
        close()
        completion(rect)
    }

    /// Shows the panel and calls `completion` once with the chosen rectangle, or nil when cancelled.
    static func present(on display: CaptureDisplay, initial: CGRect?, completion: @escaping (CGRect?) -> Void) -> RegionSelectionPanel {
        let panel = RegionSelectionPanel(display: display, initial: initial, completion: completion)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return panel
    }
}

/// The rubber-band view inside `RegionSelectionPanel`. Flipped, so its coordinates read like CG coordinates
/// within the window; conversion to global CG space only adds the window's origin.
@MainActor
final class RegionSelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    var initialSelection: CGRect? {
        didSet { selection = initialSelection; needsDisplay = true }
    }

    private var selection: CGRect?
    private var dragStart: CGPoint?
    private static let minimumSide: CGFloat = 32

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        if let selection {
            let path = NSBezierPath(rect: bounds)
            path.appendRect(selection)
            path.windingRule = .evenOdd
            path.fill()
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            let label = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            let origin = CGPoint(x: selection.minX, y: max(4, selection.minY - size.height - 6))
            let background = NSBezierPath(roundedRect: CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 4), xRadius: 4, yRadius: 4)
            NSColor.black.withAlphaComponent(0.7).setFill()
            background.fill()
            label.draw(at: CGPoint(x: origin.x + 6, y: origin.y + 2), withAttributes: attributes)
        } else {
            bounds.fill()
            let hint = "Drag to select the area to record. Press Esc to cancel." as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = hint.size(withAttributes: attributes)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        selection = CGRect(x: min(start.x, clamped.x), y: min(start.y, clamped.y), width: abs(clamped.x - start.x), height: abs(clamped.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        guard let selection, selection.width >= Self.minimumSide, selection.height >= Self.minimumSide else {
            self.selection = initialSelection
            needsDisplay = true
            return
        }
        onFinish?(selection.integral)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onFinish?(nil)
        case 36, 76: // Return: keep the current (initial) selection
            if let selection, selection.width >= Self.minimumSide, selection.height >= Self.minimumSide {
                onFinish?(selection.integral)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// View coordinates (flipped, window-relative points) → global Core Graphics points.
    func convertToCG(_ rect: CGRect, windowFrame: NSRect) -> CGRect {
        // The window frame is in Cocoa screen coordinates; its top edge in CG space is mainHeight - maxY.
        let mainHeight = NSScreen.screens.first?.frame.height ?? windowFrame.maxY
        let top = mainHeight - windowFrame.maxY
        return CGRect(x: windowFrame.minX + rect.minX, y: top + rect.minY, width: rect.width, height: rect.height)
    }

    func convert(fromCG rect: CGRect, windowFrame: NSRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? windowFrame.maxY
        let top = mainHeight - windowFrame.maxY
        return CGRect(x: rect.minX - windowFrame.minX, y: rect.minY - top, width: rect.width, height: rect.height)
    }
}
