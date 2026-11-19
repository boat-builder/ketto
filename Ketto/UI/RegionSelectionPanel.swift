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
        view.onFinish = { [weak self, weak view] rect in
            guard let self, let view else { return }
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

    /// Ultramarine, as `KettoTheme.accent`: the selection's dashed outline, its handles and its size label.
    private static let accent = NSColor(hex: 0x343CED)

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x1D1D1D, alpha: 0.18).setFill()
        if let selection {
            let path = NSBezierPath(rect: bounds)
            path.appendRect(selection)
            path.windingRule = .evenOdd
            path.fill()
            NSColor.white.withAlphaComponent(0.12).setFill()
            selection.fill(using: .sourceOver)

            // A 1pt dashed outline with four small square handles at the corners.
            Self.accent.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.stroke()
            for corner in [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
                           CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)] {
                let handle = NSBezierPath(roundedRect: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2)
                NSColor.white.setFill()
                handle.fill()
                handle.lineWidth = 1
                Self.accent.setStroke()
                handle.stroke()
            }

            // The size, on an accent pill inside the bottom-right corner (or just outside it if the selection
            // is too small to hold it).
            let label = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            let pill = CGSize(width: size.width + 16, height: size.height + 6)
            let fitsInside = selection.width > pill.width + 16 && selection.height > pill.height + 16
            let origin = fitsInside
                ? CGPoint(x: selection.maxX - pill.width - 8, y: selection.maxY - pill.height - 8)
                : CGPoint(x: min(selection.maxX - pill.width, bounds.maxX - pill.width - 4), y: min(selection.maxY + 8, bounds.maxY - pill.height - 4))
            let background = NSBezierPath(roundedRect: CGRect(origin: origin, size: pill), xRadius: pill.height / 2, yRadius: pill.height / 2)
            Self.accent.setFill()
            background.fill()
            label.draw(at: CGPoint(x: origin.x + 8, y: origin.y + 3), withAttributes: attributes)
        } else {
            bounds.fill()
            let hint = "Drag to select the area to record. Press Esc to cancel." as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor(hex: 0x1D1D1D),
            ]
            let size = hint.size(withAttributes: attributes)
            let pill = CGRect(x: bounds.midX - size.width / 2 - 18, y: bounds.midY - size.height / 2 - 10, width: size.width + 36, height: size.height + 20)
            let background = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            NSColor(hex: 0xFBFBFA, alpha: 0.94).setFill()
            background.fill()
            hint.draw(at: CGPoint(x: pill.minX + 18, y: pill.minY + 10), withAttributes: attributes)
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
