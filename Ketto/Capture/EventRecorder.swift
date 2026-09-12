import Foundation
import AppKit
import CoreGraphics

/// Records the event track: cursor position and type, clicks, and the focused window, using global `NSEvent`
/// monitors and the window server. No Accessibility permission is involved.
/// Timestamps are raw host-clock seconds; `makeDocument` rebases them onto the recording clock.
@MainActor
final class EventRecorder {
    private struct RawCursor { var t: Double; var position: SIMD2<Double>; var type: CursorType }
    private struct RawClick { var t: Double; var position: SIMD2<Double>; var button: MouseButton; var phase: ClickPhase }
    private struct RawFocus { var t: Double; var bundleId: String; var frame: CGRect? }

    let display: CaptureDisplay
    private(set) var sourceScale: Double
    private var cursorSamples: [RawCursor] = []
    private var clicks: [RawClick] = []
    private var focusEvents: [RawFocus] = []
    private var monitors: [Any] = []
    private var cursorTimer: Timer?
    private var focusTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private let cursorDetector = CursorTypeDetector()
    private var lastCursorType: CursorType = .arrow
    private var lastMoveTime: Double = 0
    private var isRunning = false

    init(display: CaptureDisplay) {
        self.display = display
        self.sourceScale = display.scale
    }

    /// Updates the pixel scale once the capture engine knows the exact captured size.
    func updateSourceScale(_ scale: Double) {
        sourceScale = scale
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        cursorSamples.reserveCapacity(20_000)
        let now = RecordingClock.now()
        lastCursorType = cursorDetector.current()
        cursorSamples.append(RawCursor(t: now, position: sourcePosition(fromCocoa: NSEvent.mouseLocation), type: lastCursorType))
        recordFocus(time: now, force: true)

        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]

        let moveHandler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handleMove(timestamp: event.timestamp) }
        }
        let clickHandler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handleClick(event) }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: moveHandler) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clickMask, handler: clickHandler) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { event in moveHandler(event); return event }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clickMask, handler: { event in clickHandler(event); return event }) { monitors.append(monitor) }

        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCursorType() }
        }
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordFocus(time: RecordingClock.now(), force: false) }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordFocus(time: RecordingClock.now(), force: true) }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        cursorTimer?.invalidate()
        focusTimer?.invalidate()
        cursorTimer = nil
        focusTimer = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        let now = RecordingClock.now()
        cursorSamples.append(RawCursor(t: now, position: sourcePosition(fromCocoa: NSEvent.mouseLocation), type: lastCursorType))
    }

    // MARK: - Coordinate conversion

    /// Converts an AppKit screen point to source pixels of the recorded display (origin top-left).
    func sourcePosition(fromCocoa point: CGPoint) -> SIMD2<Double> {
        let cg = DisplayEnumerator.cgPoint(fromCocoa: point)
        return SIMD2((cg.x - display.frame.minX) * sourceScale, (cg.y - display.frame.minY) * sourceScale)
    }

    private func sourceRect(fromCG rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX - display.frame.minX) * sourceScale,
            y: (rect.minY - display.frame.minY) * sourceScale,
            width: rect.width * sourceScale,
            height: rect.height * sourceScale
        )
    }

    // MARK: - Handlers

    private func handleMove(timestamp: Double) {
        guard isRunning, timestamp - lastMoveTime >= 0.004 else { return }
        lastMoveTime = timestamp
        cursorSamples.append(RawCursor(t: timestamp, position: sourcePosition(fromCocoa: NSEvent.mouseLocation), type: lastCursorType))
    }

    private func handleClick(_ event: NSEvent) {
        guard isRunning else { return }
        let location = NSEvent.mouseLocation
        // Ignore clicks on Ketto's own windows (the HUD's stop button, for example).
        if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(location) }) { return }
        let button: MouseButton
        let phase: ClickPhase
        switch event.type {
        case .leftMouseDown: button = .left; phase = .down
        case .leftMouseUp: button = .left; phase = .up
        case .rightMouseDown: button = .right; phase = .down
        case .rightMouseUp: button = .right; phase = .up
        case .otherMouseDown: button = .other; phase = .down
        case .otherMouseUp: button = .other; phase = .up
        default: return
        }
        let position = sourcePosition(fromCocoa: location)
        clicks.append(RawClick(t: event.timestamp, position: position, button: button, phase: phase))
        cursorSamples.append(RawCursor(t: event.timestamp, position: position, type: lastCursorType))
        if phase == .down { recordFocus(time: event.timestamp + 0.001, force: false) }
    }

    private func pollCursorType() {
        guard isRunning else { return }
        let type = cursorDetector.current()
        if type != lastCursorType {
            lastCursorType = type
            cursorSamples.append(RawCursor(t: RecordingClock.now(), position: sourcePosition(fromCocoa: NSEvent.mouseLocation), type: type))
        }
    }

    private func recordFocus(time: Double, force: Bool) {
        guard isRunning || force else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleId = app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
        let frame = Self.frontWindowFrame(pid: app.processIdentifier).map(sourceRect(fromCG:))
        if let last = focusEvents.last, last.bundleId == bundleId, Self.approximatelyEqual(last.frame, frame) { return }
        focusEvents.append(RawFocus(t: time, bundleId: bundleId, frame: frame))
    }

    private static func approximatelyEqual(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
        default: return false
        }
    }

    /// Frame (CG coordinates, points) of the frontmost normal-level window owned by `pid`.
    static func frontWindowFrame(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  w > 50, h > 50 else { continue }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    // MARK: - Output

    /// Builds `events.json` content relative to `timeBase` (host seconds of the first frame).
    func makeDocument(timeBase: Double, duration: Double, recordingStartEpoch: Double, pixelWidth: Int, pixelHeight: Int) -> EventsDocument {
        let width = Double(pixelWidth), height = Double(pixelHeight)
        func inRange(_ t: Double) -> Bool { t >= -0.05 && t <= duration + 0.05 }
        var cursor: [CursorSample] = []
        cursor.reserveCapacity(cursorSamples.count)
        var previous: RawCursor?
        for sample in cursorSamples {
            let t = sample.t - timeBase
            guard inRange(t) else { continue }
            if let prev = previous, prev.type == sample.type, simd_length(prev.position - sample.position) < 0.5, sample.t - prev.t < 0.5 { continue }
            cursor.append(CursorSample(t: max(0, t), x: sample.position.x, y: sample.position.y, type: sample.type))
            previous = sample
        }
        let clickEvents = clicks.compactMap { click -> ClickEvent? in
            let t = click.t - timeBase
            guard inRange(t), click.position.x >= 0, click.position.y >= 0, click.position.x <= width, click.position.y <= height else { return nil }
            return ClickEvent(t: max(0, t), x: click.position.x, y: click.position.y, button: click.button, phase: click.phase)
        }
        let focus = focusEvents.map { FocusEvent(t: max(0, $0.t - timeBase), bundleId: $0.bundleId, frame: $0.frame) }
        return EventsDocument(
            recordingStart: recordingStartEpoch,
            duration: duration,
            display: DisplayInfo(id: display.id, width: pixelWidth, height: pixelHeight, scale: sourceScale),
            cursor: cursor,
            clicks: clickEvents,
            keys: [],
            focus: focus
        )
    }
}
