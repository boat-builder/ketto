import SwiftUI
import AppKit
@preconcurrency import AVFoundation

/// The floating camera bubble: a borderless, always-on-top panel that shows the camera the way the video will
/// show it — a mirrored circle with a white border and a shadow, the overlay's defaults — from the moment the
/// camera is switched on in the recorder, through the countdown and the whole recording. Ketto's own windows
/// are never captured and clicks on them are never recorded, so it can sit anywhere on the recorded display;
/// drag it wherever it is least in the way. Where it sits when the recording stops is where the camera bubble
/// starts out in the edit (`CameraPlacement`).
///
/// Before a recording the bubble shows its own preview session; a recording's `CameraCapture` needs the device
/// to itself, so `releaseCamera()` stops the preview right before the countdown and `attach(_:)` swaps in the
/// recording's session once it is warm.
@Observable @MainActor
final class CameraBubbleController {
    /// The session the bubble shows right now: the preview before a recording, the recording's camera during
    /// one, nil while the camera changes hands (the bubble shows a placeholder).
    private(set) var session: AVCaptureSession?
    /// Bumped whenever `session` changes, so the preview view re-applies its mirroring to the new connection.
    private(set) var revision = 0
    private(set) var isShowing = false

    private let preview = CameraPreviewSource()
    @ObservationIgnored private var panel: CameraBubblePanel?
    @ObservationIgnored private var display: CaptureDisplay?
    @ObservationIgnored private var sizeFraction = CameraBubbleController.defaultSizeFraction
    @ObservationIgnored private var recordingSession: AVCaptureSession?
    @ObservationIgnored private var moveObserver: NSObjectProtocol?

    /// Bubble height as a fraction of the display height. On a 16:9 canvas with the default padding this
    /// becomes the overlay's default `size` of about a quarter of the frame.
    static let defaultSizeFraction = 0.28
    static let sizeRange = 0.12...0.5
    /// Where the bubble first appears, normalised in the display (y down): the overlay's default corner.
    private static let defaultCenter = SIMD2(0.86, 0.82)
    private static let centerXKey = "cameraBubbleCenterX"
    private static let centerYKey = "cameraBubbleCenterY"

    /// Shows the bubble on `display` with the live picture from `deviceID` (the default camera when nil), or
    /// moves an already visible bubble there. `sizeFraction` is the bubble height relative to the display.
    func show(on display: CaptureDisplay, deviceID: String?, sizeFraction: Double) {
        self.display = display
        self.sizeFraction = min(max(sizeFraction, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        if recordingSession == nil {
            if preview.start(deviceID: deviceID) {
                if session !== preview.session {
                    session = preview.session
                    revision += 1
                }
            } else {
                session = nil
            }
        }
        let panel = self.panel ?? makePanel()
        layout(panel, on: display)
        if !isShowing {
            panel.orderFrontRegardless()
            isShowing = true
        }
    }

    /// Shows the bubble on `display` without opening the camera: for a recording started while the capture bar
    /// was closed, the recording's own session arrives through `attach(_:)` once it is warm, and the bubble shows
    /// its placeholder until then.
    func showAwaitingRecording(on display: CaptureDisplay, sizeFraction: Double) {
        self.display = display
        self.sizeFraction = min(max(sizeFraction, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        let panel = self.panel ?? makePanel()
        layout(panel, on: display)
        if !isShowing {
            panel.orderFrontRegardless()
            isShowing = true
        }
    }

    /// Hides the bubble and releases the camera.
    func hide() {
        panel?.orderOut(nil)
        isShowing = false
        session = nil
        Task { await preview.stop() }
    }

    /// Stops the preview so a recording's own capture session can take the camera. The bubble stays where it
    /// is, showing a placeholder until `attach(_:)`.
    func releaseCamera() async {
        if session === preview.session { session = nil }
        await preview.stop()
    }

    /// Shows the recording's camera instead of the preview.
    func attach(_ capture: AVCaptureSession) {
        recordingSession = capture
        session = capture
        revision += 1
    }

    /// The recording's camera is gone (the recording stopped or never started).
    func detachRecording() {
        recordingSession = nil
        if session !== preview.session { session = nil }
    }

    /// Where the bubble sits relative to `area` (points, Core Graphics coordinates — a `CaptureSource.frame`),
    /// or nil when it is not showing.
    func placement(in area: CGRect) -> CameraPlacement? {
        guard isShowing, let panel, area.width > 0, area.height > 0 else { return nil }
        let frame = panel.frame
        let center = DisplayEnumerator.cgPoint(fromCocoa: CGPoint(x: frame.midX, y: frame.midY))
        let bubbleHeight = max(frame.height - 2 * CameraBubbleView.shadowPadding, 1)
        return CameraPlacement(
            center: SIMD2(Double((center.x - area.minX) / area.width), Double((center.y - area.minY) / area.height)),
            height: Double(bubbleHeight / area.height)
        )
    }

    // MARK: - Panel

    private func makePanel() -> CameraBubblePanel {
        let panel = CameraBubblePanel(controller: self)
        self.panel = panel
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        }
        return panel
    }

    /// Sizes the panel for the display. A bubble that is already showing stays where the user put it (even on
    /// another display, out of the recording's way); one coming up is placed where it was last left, clamped
    /// onto the display.
    private func layout(_ panel: CameraBubblePanel, on display: CaptureDisplay) {
        let frame = display.frame
        let bubble: CGFloat = max(48, CGFloat(sizeFraction) * frame.height)
        let total: CGFloat = bubble + 2 * CameraBubbleView.shadowPadding
        let center: CGPoint
        if isShowing {
            center = DisplayEnumerator.cgPoint(fromCocoa: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
        } else {
            let normalised = Self.rememberedCenter()
            var placed = CGPoint(x: frame.minX + CGFloat(normalised.x) * frame.width, y: frame.minY + CGFloat(normalised.y) * frame.height)
            placed.x = min(max(placed.x, frame.minX + bubble / 2), max(frame.maxX - bubble / 2, frame.minX + bubble / 2))
            placed.y = min(max(placed.y, frame.minY + bubble / 2), max(frame.maxY - bubble / 2, frame.minY + bubble / 2))
            center = placed
        }
        let cocoa = DisplayEnumerator.cocoaPoint(fromCG: center)
        panel.setFrame(NSRect(x: cocoa.x - total / 2, y: cocoa.y - total / 2, width: total, height: total), display: true)
    }

    private func rememberPosition() {
        guard let panel, let display, display.frame.width > 0, display.frame.height > 0 else { return }
        let frame = panel.frame
        let center = DisplayEnumerator.cgPoint(fromCocoa: CGPoint(x: frame.midX, y: frame.midY))
        let defaults = UserDefaults.standard
        defaults.set(Double((center.x - display.frame.minX) / display.frame.width), forKey: Self.centerXKey)
        defaults.set(Double((center.y - display.frame.minY) / display.frame.height), forKey: Self.centerYKey)
    }

    private static func rememberedCenter() -> SIMD2<Double> {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: centerXKey) != nil, defaults.object(forKey: centerYKey) != nil else { return defaultCenter }
        let x = defaults.double(forKey: centerXKey), y = defaults.double(forKey: centerYKey)
        guard x.isFinite, y.isFinite else { return defaultCenter }
        return SIMD2(min(max(x, 0), 1), min(max(y, 0), 1))
    }
}

/// The bubble's window: borderless, transparent, floating over everything, on every Space, movable by dragging
/// anywhere on it, and never activating Ketto (the user is working in another app while it shows).
@MainActor
final class CameraBubblePanel: NSPanel {
    init(controller: CameraBubbleController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        let dragView = BubbleDragView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        let hosting = NSHostingView(rootView: CameraBubbleView(controller: controller))
        hosting.frame = dragView.bounds
        hosting.autoresizingMask = [.width, .height]
        dragView.addSubview(hosting)
        contentView = dragView
    }
}

/// The bubble has nothing to click, so every mouse-down on it is the start of a drag that moves the window.
/// Hit-testing stops here: the hosting view underneath only draws.
private final class BubbleDragView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

/// The bubble itself: the mirrored camera in a circle with the overlay's default border and shadow, or a
/// placeholder while the camera changes hands.
struct CameraBubbleView: View {
    let controller: CameraBubbleController

    /// Room around the circle for its shadow; the panel is this much larger than the bubble on every side.
    static let shadowPadding: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            if let session = controller.session {
                CameraPreviewView(session: session, revision: controller.revision, circular: true)
            } else {
                Image(systemName: "video.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: 4))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
        .padding(Self.shadowPadding)
    }
}
