import SwiftUI
import AppKit

/// The floating record HUD: countdown digits, then a red dot, elapsed time, Pause and Stop. It sits at the
/// bottom centre of the recorded display. It never appears in the capture because `ScreenCaptureEngine`
/// excludes every window of this process, and clicks on it are dropped by `EventRecorder`.
@MainActor
final class RecordHUDPanel: NSPanel {
    static let size = NSSize(width: 360, height: 76)

    init(model: AppModel, display: CaptureDisplay) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
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
        let hosting = NSHostingView(rootView: RecordHUDView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        contentView = hosting
        position(on: display)
    }

    private func position(on display: CaptureDisplay) {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        } ?? NSScreen.main
        guard let target = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: target.midX - Self.size.width / 2, y: target.minY + 36))
    }
}

struct RecordHUDView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            switch model.phase {
            case .countdown(let remaining):
                countdown(remaining)
            case .recording(let session):
                RecordingControls(model: model, session: session)
            case .finishing:
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.headline)
                Spacer()
            case .setup, .editing:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .frame(width: RecordHUDPanel.size.width, height: RecordHUDPanel.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private func countdown(_ remaining: Int) -> some View {
        HStack(spacing: 14) {
            Text("\(remaining)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Starting…")
                    .font(.headline)
                Text("Switch to what you want to record")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { model.cancelCountdown() }
                .keyboardShortcut(.cancelAction)
        }
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// The red dot, the clock (recording time, pauses excluded), Pause / Resume and Stop.
private struct RecordingControls: View {
    let model: AppModel
    let session: RecordingSession

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(session.isPaused ? Color.secondary : Color.red)
                .frame(width: 14, height: 14)
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(RecordHUDView.timecode(session.elapsed))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            if session.isPaused {
                Text("Paused")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                session.togglePause()
            } label: {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 16)
            }
            .help(session.isPaused ? "Resume recording" : "Pause recording")
            Button {
                model.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.escape, modifiers: [])
        }
    }
}
