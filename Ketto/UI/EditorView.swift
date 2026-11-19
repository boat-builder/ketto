import SwiftUI
import AppKit

/// The editor: its own toolbar, the Metal preview on the warm stage with the transport under it, the timeline
/// below, and the tabbed inspector on the right.
struct EditorView: View {
    @Bindable var model: AppModel
    let session: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model, session: session)
            Hairline()
            HSplitView {
                VStack(spacing: 0) {
                    PreviewPane(session: session)
                    TransportBar(session: session)
                        .background(KettoTheme.stage)
                    Hairline()
                    EditorTimelineView(session: session)
                        .background(KettoTheme.canvas)
                    if let statistics = model.lastRecordingStatistics, model.lastRecordedBundle == session.bundle {
                        if statistics.droppedFrames > 0 {
                            captureWarning("\(statistics.droppedFrames) frames were dropped during capture.")
                        }
                        if let warning = statistics.cameraWarning {
                            captureWarning(warning)
                        }
                    }
                }
                .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                InspectorView(session: session)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
            }
        }
        .background(KettoTheme.canvas)
        .tint(KettoTheme.accent)
        .sheet(isPresented: $model.isExportSheetPresented) {
            ExportSheet(session: session, share: model.share, intent: model.exportIntent) {
                model.showSettings(.sharing)
            }
        }
    }

    private func captureWarning(_ text: String) -> some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 7) {
                StatusDot(color: KettoTheme.warning)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.secondaryInk)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .background(KettoTheme.canvas)
    }
}

/// Back to the library, the project's name and state, undo and redo, and the two ways out: Export and Share.
private struct EditorToolbar: View {
    let model: AppModel
    let session: ProjectSession

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.closeProject()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .regular))
                    Text("Library")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(KettoTheme.secondaryInk)
                .padding(.leading, 6)
                .padding(.trailing, 10)
                .frame(height: 30)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 15)
            .help("Back to the library (⌘L). The project is saved.")

            Hairline(axis: .vertical)
                .frame(height: 18)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.bundle.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KettoTheme.ink)
                    .lineLimit(1)
                Text(saveState)
                    .font(.system(size: 12))
                    .foregroundStyle(session.saveError == nil ? KettoTheme.secondaryInk : KettoTheme.warning)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .frame(maxWidth: 460, alignment: .leading)
            .help(details)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                toolbarIcon("arrow.uturn.backward", help: "Undo (⌘Z)") { session.undo() }
                    .disabled(!session.canUndo)
                toolbarIcon("arrow.uturn.forward", help: "Redo (⇧⌘Z)") { session.redo() }
                    .disabled(!session.canRedo)
                toolbarIcon("folder", help: "Show the project in the Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.bundle.url])
                }
            }

            Button("Export…") {
                model.requestExport(.export)
            }
            .buttonStyle(PillButtonStyle())
            .help("Save a video or a GIF, or copy it to the clipboard (⌘E)")

            Button {
                model.requestExport(.share)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .regular))
                    Text("Share Link")
                }
            }
            .buttonStyle(ProminentPillButtonStyle())
            .help(shareHelp)
        }
        .padding(.leading, 84) // The traffic lights.
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(KettoTheme.canvas)
    }

    private func toolbarIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(KettoTheme.secondaryInk)
        }
        .buttonStyle(IconButtonStyle(size: 30, cornerRadius: 15))
        .hoverHighlight(cornerRadius: 15)
        .help(help)
    }

    private var saveState: String {
        if let error = session.saveError {
            return "Couldn’t save: \(error)"
        }
        return "Saved"
    }

    private var details: String {
        var parts = [shortTimecode(session.duration), "\(session.source.width) × \(session.source.height)"]
        if let error = session.saveError {
            parts.append("Couldn’t save: \(error)")
        } else {
            parts.append("Saved automatically")
        }
        return parts.joined(separator: " · ")
    }

    private var shareHelp: String {
        if let connection = model.share?.connection {
            return "Render as MP4, upload to \(connection.displayName) and copy a link that works for about three days"
        }
        return "Set up sharing to get a link that works for about three days"
    }
}

/// The live preview, kept at the canvas aspect ratio, on the warm stage, with the direct-manipulation overlay on top.
struct PreviewPane: View {
    let session: ProjectSession

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(width: max(geo.size.width - 64, 10), height: max(geo.size.height - 40, 10))
            let fitted = Self.fit(aspect: session.edit.canvas.aspectRatio, in: available)
            ZStack {
                KettoTheme.stage
                ZStack(alignment: .topLeading) {
                    MetalPreviewView(session: session)
                        .frame(width: fitted.width, height: fitted.height)
                    PreviewOverlayView(session: session, size: fitted)
                }
                .frame(width: fitted.width, height: fitted.height)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.12), radius: 20, y: 12)
                if let error = session.player.loadError {
                    HStack(spacing: 8) {
                        StatusDot(color: KettoTheme.warning)
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(KettoTheme.ink)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .card(cornerRadius: 10)
                }
                if session.isEditingCrop {
                    VStack {
                        HStack {
                            Text("Drag the rectangle to crop the recording")
                                .font(.system(size: 12))
                                .foregroundStyle(KettoTheme.ink)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(KettoTheme.canvas, in: Capsule())
                                .overlay(Capsule().strokeBorder(KettoTheme.hairline, lineWidth: KettoTheme.line))
                            Spacer()
                            Button("Done Cropping") { session.endCropEditing() }
                                .buttonStyle(ProminentPillButtonStyle())
                        }
                        .padding(12)
                        Spacer()
                    }
                }
            }
        }
    }

    static func fit(aspect: Double, in available: CGSize) -> CGSize {
        let aspect = max(aspect, 0.01)
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        return CGSize(width: max(width, 1), height: max(height, 1))
    }
}

/// The time on the left, frame stepping around the ink Play button in the middle, the canvas on the right.
/// Space toggles playback; arrow keys step one frame. Scrubbing happens on the timeline's ruler.
struct TransportBar: View {
    let session: ProjectSession

    private var player: PreviewPlayer { session.player }

    var body: some View {
        HStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.timecode(player.currentTime))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(KettoTheme.ink)
                Text("/ \(Self.timecode(player.duration))")
                    .font(.system(size: 13))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button {
                    player.step(by: -1)
                } label: {
                    Image(systemName: "backward.frame.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
                .buttonStyle(IconButtonStyle(size: 30, cornerRadius: 15))
                .hoverHighlight(cornerRadius: 15)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous frame (←)")
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(KettoTheme.onInk)
                        .frame(width: 36, height: 36)
                        .background(KettoTheme.ink, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button {
                    player.step(by: 1)
                } label: {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
                .buttonStyle(IconButtonStyle(size: 30, cornerRadius: 15))
                .hoverHighlight(cornerRadius: 15)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next frame (→)")
            }

            Text("\(session.edit.canvas.aspect) · \(session.edit.canvas.width) × \(session.edit.canvas.height)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(KettoTheme.secondaryInk)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 52)
    }

    /// `mm:ss.f`
    static func timecode(_ seconds: Double) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(clamped) / 60
        let secs = clamped - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, secs)
    }
}
