import SwiftUI
import AppKit

/// The editor: its own toolbar, the Metal preview on a dark stage, the transport and the timeline on the left,
/// the tabbed inspector on the right.
struct EditorView: View {
    @Bindable var model: AppModel
    let session: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model, session: session)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    PreviewPane(session: session)
                    Divider()
                    TransportBar(session: session)
                    Divider()
                    EditorTimelineView(session: session)
                    if let statistics = model.lastRecordingStatistics, statistics.droppedFrames > 0 {
                        Divider()
                        Text("\(statistics.droppedFrames) frames were dropped during capture.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(6)
                    }
                }
                .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                InspectorView(session: session)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.isExportSheetPresented) {
            ExportSheet(session: session, share: model.share, intent: model.exportIntent) {
                model.showSettings(.sharing)
            }
        }
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
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("Library")
                }
            }
            .buttonStyle(PillButtonStyle())
            .help("Back to the library (⌘L). The project is saved.")

            Spacer(minLength: 8)

            VStack(spacing: 1) {
                Text(session.bundle.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(session.saveError == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            .frame(maxWidth: 420)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                Button {
                    session.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(IconButtonStyle())
                .hoverHighlight()
                .disabled(!session.canUndo)
                .help("Undo (⌘Z)")
                Button {
                    session.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(IconButtonStyle())
                .hoverHighlight()
                .disabled(!session.canRedo)
                .help("Redo (⇧⌘Z)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.bundle.url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(IconButtonStyle())
                .hoverHighlight()
                .help("Show the project in the Finder")
            }

            Button {
                model.requestExport(.export)
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PillButtonStyle())
            .help("Save a video or a GIF, or copy it to the clipboard (⌘E)")

            Button {
                model.requestExport(.share)
            } label: {
                Label("Share Link", systemImage: "link")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(ProminentPillButtonStyle())
            .help(shareHelp)
        }
        .padding(.leading, 84) // The traffic lights.
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(.bar)
    }

    private var subtitle: String {
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

/// The live preview, kept at the canvas aspect ratio, on a dark stage, with the direct-manipulation overlay on top.
struct PreviewPane: View {
    let session: ProjectSession

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(width: max(geo.size.width - 56, 10), height: max(geo.size.height - 56, 10))
            let fitted = Self.fit(aspect: session.edit.canvas.aspectRatio, in: available)
            ZStack {
                KettoTheme.stage
                ZStack(alignment: .topLeading) {
                    MetalPreviewView(session: session)
                        .frame(width: fitted.width, height: fitted.height)
                    PreviewOverlayView(session: session, size: fitted)
                }
                .frame(width: fitted.width, height: fitted.height)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                if let error = session.player.loadError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                }
                if session.isEditingCrop {
                    VStack {
                        HStack {
                            Text("Drag the rectangle to crop the recording")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(.black.opacity(0.5), in: Capsule())
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
        .environment(\.colorScheme, .dark)
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

/// Play/pause, frame stepping, scrubber and timecodes. Space toggles playback; arrow keys step one frame.
struct TransportBar: View {
    let session: ProjectSession

    private var player: PreviewPlayer { session.player }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                player.step(by: -1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(IconButtonStyle())
            .hoverHighlight()
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Previous frame (←)")
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 32, cornerRadius: 16))
            .hoverHighlight(cornerRadius: 16)
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            Button {
                player.step(by: 1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(IconButtonStyle())
            .hoverHighlight()
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Next frame (→)")
            Text(Self.timecode(player.currentTime))
                .monospacedDigit()
                .font(.system(size: 12, weight: .medium))
                .frame(width: 66, alignment: .trailing)
                .padding(.leading, 8)
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.001),
                onEditingChanged: { editing in
                    if editing {
                        player.beginScrubbing()
                    } else {
                        player.endScrubbing()
                    }
                }
            )
            Text(Self.timecode(player.duration))
                .monospacedDigit()
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// `mm:ss.f`
    static func timecode(_ seconds: Double) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(clamped) / 60
        let secs = clamped - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, secs)
    }
}
