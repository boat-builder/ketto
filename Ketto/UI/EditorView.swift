import SwiftUI
import AppKit

/// The editor: Metal preview, transport and timeline on the left, the inspector on the right.
struct EditorView: View {
    @Bindable var model: AppModel
    let session: ProjectSession

    var body: some View {
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
                .frame(minWidth: 290, idealWidth: 330, maxWidth: 440)
        }
        .navigationTitle(session.bundle.name)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.returnToRecorder()
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                }
                .help("Back to the recorder (⌘N)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    session.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!session.canUndo)
                .help("Undo (⌘Z)")
                Button {
                    session.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!session.canRedo)
                .help("Redo (⇧⌘Z)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.bundle.url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Reveal the project bundle in the Finder")
                Button {
                    model.requestExport()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Export the video (⌘E)")
            }
        }
        .sheet(isPresented: $model.isExportSheetPresented) {
            ExportSheet(session: session)
        }
    }
}

/// The live preview, kept at the canvas aspect ratio, with the direct-manipulation overlay on top.
struct PreviewPane: View {
    let session: ProjectSession

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(width: max(geo.size.width - 40, 10), height: max(geo.size.height - 40, 10))
            let fitted = Self.fit(aspect: session.edit.canvas.aspectRatio, in: available)
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                ZStack(alignment: .topLeading) {
                    MetalPreviewView(session: session)
                        .frame(width: fitted.width, height: fitted.height)
                    PreviewOverlayView(session: session, size: fitted)
                }
                .frame(width: fitted.width, height: fitted.height)
                if let error = session.player.loadError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                } else if let saveError = session.saveError {
                    VStack {
                        Spacer()
                        Text("Could not save edit.json: \(saveError)")
                            .font(.caption)
                            .padding(8)
                            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
                if session.isEditingCrop {
                    VStack {
                        HStack {
                            Spacer()
                            Button("Done Cropping") { session.endCropEditing() }
                                .buttonStyle(.borderedProminent)
                                .padding(12)
                        }
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

/// Play/pause, scrubber and timecodes. Space toggles playback; arrow keys step one frame.
struct TransportBar: View {
    let session: ProjectSession

    private var player: PreviewPlayer { session.player }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            Button {
                player.step(by: -1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Previous frame (←)")
            Button {
                player.step(by: 1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Next frame (→)")
            Text(Self.timecode(player.currentTime))
                .monospacedDigit()
                .font(.callout)
                .frame(width: 70, alignment: .trailing)
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
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// `mm:ss.f`
    static func timecode(_ seconds: Double) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(clamped) / 60
        let secs = clamped - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, secs)
    }
}
