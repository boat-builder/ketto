import SwiftUI
import AppKit

/// The floating record HUD: the countdown, then the red dot, elapsed time, Pause and Stop. It sits where the
/// capture bar was, at the bottom centre of the recorded display. It never appears in the capture because
/// `ScreenCaptureEngine` excludes every window of this process, and clicks on it are dropped by `EventRecorder`.
@MainActor
final class RecordHUDPanel: NSPanel {
    static let size = NSSize(width: 420, height: 84)

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
        setFrameOrigin(NSPoint(x: target.midX - Self.size.width / 2, y: target.minY + 40))
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saving…")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Opening the project in the editor")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            case .idle, .editing:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .frame(width: RecordHUDPanel.size.width - 20, height: RecordHUDPanel.size.height - 20)
        .glassSurface(Capsule(), material: .regularMaterial)
        .padding(10)
    }

    private func countdown(_ remaining: Int) -> some View {
        HStack(spacing: 14) {
            Text("\(max(remaining, 1))")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Starting…")
                    .font(.system(size: 13, weight: .semibold))
                Text("Switch to what you want to record")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.cancelCountdown()
            } label: {
                HStack(spacing: 6) {
                    Text("Cancel")
                    Text("esc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(PillButtonStyle())
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

/// The coral dot, the clock (recording time, pauses excluded), Pause / Resume and Stop.
private struct RecordingControls: View {
    let model: AppModel
    let session: RecordingSession

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.isPaused ? Color.secondary : KettoTheme.record)
                .frame(width: 12, height: 12)
                .shadow(color: session.isPaused ? .clear : KettoTheme.record.opacity(0.6), radius: 4)
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(RecordHUDView.timecode(session.elapsed))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(session.isPaused ? Color.secondary : Color.primary)
            }
            if session.isPaused {
                Text("Paused")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                session.togglePause()
            } label: {
                if session.isPaused {
                    Label("Resume", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                } else {
                    Image(systemName: "pause.fill")
                        .frame(width: 14)
                }
            }
            .buttonStyle(PillButtonStyle())
            .help(session.isPaused ? "Resume recording (⇧⌘P)" : "Pause recording (⇧⌘P)")
            Button {
                model.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RecordButtonStyle(height: 28))
            .keyboardShortcut(.escape, modifiers: [])
            .help("Stop and open the recording in the editor (⇧⌘R)")
        }
    }
}
