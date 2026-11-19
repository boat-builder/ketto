import SwiftUI
import AppKit

/// The floating record HUD: the countdown, then the red dot, elapsed time, Pause and Stop. It sits where the
/// capture bar was, at the bottom centre of the recorded display, and keeps the size of whatever it shows. It
/// never appears in the capture because `ScreenCaptureEngine` excludes every window of this process, and
/// clicks on it are dropped by `EventRecorder`.
@MainActor
final class RecordHUDPanel: NSPanel {
    private var lastSize = NSSize(width: 260, height: 72)

    init(model: AppModel, display: CaptureDisplay) {
        let initialSize = lastSize
        super.init(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        let root = RecordHUDView(model: model) { [weak self] size in
            self?.fit(to: size)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: initialSize)
        contentView = hosting
        position(on: display)
    }

    private func position(on display: CaptureDisplay) {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        } ?? NSScreen.main
        guard let target = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: target.midX - frame.width / 2, y: target.minY + 40))
    }

    /// Keeps the panel the size of its content, anchored at its bottom centre.
    private func fit(to size: CGSize) {
        guard size.width > 1, size.height > 1, size != lastSize else { return }
        lastSize = size
        let current = frame
        let origin = NSPoint(x: current.midX - size.width / 2, y: current.minY)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

struct RecordHUDView: View {
    let model: AppModel
    var onSizeChange: (CGSize) -> Void = { _ in }

    var body: some View {
        content
            .padding(14) // Room for the shadow inside the transparent panel.
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                onSizeChange(size)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .countdown(let remaining):
            countdown(remaining)
        case .recording(let session):
            RecordingControls(model: model, session: session)
        case .finishing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KettoTheme.ink)
                Text("Opening the editor")
                    .font(.system(size: 13))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            .padding(.leading, 14)
            .padding(.trailing, 18)
            .frame(height: 44)
            .glassSurface(Capsule(), material: .regularMaterial)
        case .idle, .editing:
            EmptyView()
        }
    }

    private func countdown(_ remaining: Int) -> some View {
        VStack(spacing: 8) {
            if remaining > 0 {
                Text("\(remaining)")
                    .font(.system(size: 64, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(KettoTheme.ink)
                    .frame(height: 64)
                    .contentTransition(.numericText(countsDown: true))
            } else {
                // Countdown switched off: capture is starting right now.
                ProgressView()
                    .controlSize(.regular)
                    .frame(height: 64)
            }
            Text("Switch to what you want to record")
                .font(.system(size: 12))
                .foregroundStyle(KettoTheme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.cancelCountdown()
            } label: {
                HStack(spacing: 8) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(KettoTheme.ink)
                    Text("esc")
                        .font(.system(size: 11))
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(KettoTheme.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(KettoTheme.ink.opacity(0.18), lineWidth: 0.5))
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(height: 28)
                .background(KettoTheme.ink.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 18)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(width: 196)
        .glassSurface(cornerRadius: 22, material: .regularMaterial)
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        shortTimecode(seconds)
    }
}

/// The red dot, the clock (recording time, pauses excluded), Pause / Resume and Stop.
private struct RecordingControls: View {
    let model: AppModel
    let session: RecordingSession

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if session.isPaused {
                    Circle().strokeBorder(KettoTheme.secondaryInk, lineWidth: KettoTheme.line)
                } else {
                    Circle().fill(KettoTheme.record)
                }
            }
            .frame(width: 8, height: 8)
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(RecordHUDView.timecode(session.elapsed))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(KettoTheme.ink)
            }
            if session.isPaused {
                Text("Paused")
                    .font(.system(size: 13))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            Button {
                session.togglePause()
            } label: {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.ink)
                    .frame(width: 32, height: 32)
                    .background(KettoTheme.ink.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help(session.isPaused ? "Resume recording (⇧⌘P)" : "Pause recording (⇧⌘P)")
            .accessibilityLabel(session.isPaused ? "Resume recording" : "Pause recording")
            Button {
                model.stopRecording()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                    Text("Stop")
                }
            }
            .buttonStyle(RecordButtonStyle(height: 32))
            .keyboardShortcut(.escape, modifiers: [])
            .help("Stop and open the recording in the editor (⇧⌘R)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 44)
        .glassSurface(Capsule(), material: .regularMaterial)
    }
}
