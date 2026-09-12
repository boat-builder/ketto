import Foundation
import AppKit
import CoreGraphics

/// Records the event track: cursor position and type, clicks, the focused window and — when the user opted in
/// — keystrokes, using global `NSEvent` monitors and the window server. Mouse events need no permission;
/// key events only arrive while the app is trusted for Accessibility (see `CapturePermissions`).
/// Timestamps are raw host-clock seconds; `makeDocument` maps them onto recording time through the clock.
@MainActor
final class EventRecorder {
    private struct RawCursor { var t: Double; var position: SIMD2<Double>; var type: CursorType }
    private struct RawClick { var t: Double; var position: SIMD2<Double>; var button: MouseButton; var phase: ClickPhase }
    private struct RawFocus { var t: Double; var bundleId: String; var frame: CGRect? }

    let source: CaptureSource
    let keystrokes: KeystrokeCaptureMode
    private(set) var sourceScale: Double
    /// Top-left of the captured area in Core Graphics points; follows the window in window mode.
    private(set) var sourceOrigin: CGPoint
    private var cursorSamples: [RawCursor] = []
    private var clicks: [RawClick] = []
    private var keys: [KeyEvent] = []
    private var focusEvents: [RawFocus] = []
    private var monitors: [Any] = []
    private var cursorTimer: Timer?
    private var focusTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private let cursorDetector = CursorTypeDetector()
    private var lastCursorType: CursorType = .arrow
    private var lastMoveTime: Double = 0
    private var isRunning = false

    var display: CaptureDisplay { source.display }

    init(source: CaptureSource, keystrokes: KeystrokeCaptureMode = .off) {
        self.source = source
        self.keystrokes = keystrokes
        self.sourceScale = source.scale
        self.sourceOrigin = source.frame.origin
    }

    convenience init(display: CaptureDisplay) {
        self.init(source: .display(display))
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
        if keystrokes != .off {
            let keyHandler: (NSEvent) -> Void = { [weak self] event in
                MainActor.assumeIsolated { self?.handleKey(event) }
            }
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) { monitors.append(monitor) }
        }

        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCursorType() }
        }
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshWindowFrame()
                self.recordFocus(time: RecordingClock.now(), force: false)
            }
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

    /// Converts an AppKit screen point to source pixels of the captured area (origin top-left).
    func sourcePosition(fromCocoa point: CGPoint) -> SIMD2<Double> {
        let cg = DisplayEnumerator.cgPoint(fromCocoa: point)
        return SIMD2((cg.x - sourceOrigin.x) * sourceScale, (cg.y - sourceOrigin.y) * sourceScale)
    }

    private func sourceRect(fromCG rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX - sourceOrigin.x) * sourceScale,
            y: (rect.minY - sourceOrigin.y) * sourceScale,
            width: rect.width * sourceScale,
            height: rect.height * sourceScale
        )
    }

    /// In window mode the captured window may move; keep the origin on it.
    private func refreshWindowFrame() {
        guard case .window(let window) = source,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], window.id) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"] else { return }
        sourceOrigin = CGPoint(x: x, y: y)
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

    private func handleKey(_ event: NSEvent) {
        guard isRunning, !event.isARepeat else { return }
        let flags = KeystrokeMapping.Modifiers(rawValue: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        if let key = KeystrokeMapping.keyEvent(t: event.timestamp, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, flags: flags, mode: keystrokes) {
            keys.append(key)
        }
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

    /// Builds `events.json` content in recording time. Events that fall inside a pause are dropped.
    func makeDocument(clock: RecordingClock, duration: Double, recordingStartEpoch: Double, pixelWidth: Int, pixelHeight: Int) -> EventsDocument {
        let width = Double(pixelWidth), height = Double(pixelHeight)
        func recordingTime(_ hostTime: Double) -> Double? {
            guard let t = clock.recordingTime(forHost: hostTime), t >= -0.05, t <= duration + 0.05 else { return nil }
            return max(0, t)
        }
        var cursor: [CursorSample] = []
        cursor.reserveCapacity(cursorSamples.count)
        var previous: RawCursor?
        for sample in cursorSamples {
            guard let t = recordingTime(sample.t) else { continue }
            if let prev = previous, prev.type == sample.type, simd_length(prev.position - sample.position) < 0.5, sample.t - prev.t < 0.5 { continue }
            cursor.append(CursorSample(t: t, x: sample.position.x, y: sample.position.y, type: sample.type))
            previous = sample
        }
        let clickEvents = clicks.compactMap { click -> ClickEvent? in
            guard let t = recordingTime(click.t), click.position.x >= 0, click.position.y >= 0, click.position.x <= width, click.position.y <= height else { return nil }
            return ClickEvent(t: t, x: click.position.x, y: click.position.y, button: click.button, phase: click.phase)
        }
        let keyEvents = keys.compactMap { key -> KeyEvent? in
            guard let t = recordingTime(key.t) else { return nil }
            return KeyEvent(t: t, chars: key.chars, modifiers: key.modifiers)
        }
        let focus = focusEvents.compactMap { event -> FocusEvent? in
            var time = clock.recordingTime(forHost: event.t)
            // The first focus record is taken before the first frame arrives; it describes time zero.
            if time == nil, let base = clock.base, event.t <= base { time = 0 }
            guard let t = time else { return nil }
            return FocusEvent(t: max(0, min(t, duration)), bundleId: event.bundleId, frame: event.frame)
        }
        return EventsDocument(
            recordingStart: recordingStartEpoch,
            duration: duration,
            display: DisplayInfo(id: display.id, width: pixelWidth, height: pixelHeight, scale: sourceScale),
            cursor: cursor,
            clicks: clickEvents,
            keys: keyEvents,
            focus: focus
        )
    }
}
