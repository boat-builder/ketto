import SwiftUI

/// Ketto has no window of its own at launch: the floating capture bar and the app window are AppKit panels and
/// windows owned by `AppModel`, so the one SwiftUI scene is the menu bar item, which is also where the app lives
/// while the bar is closed. The main menu's commands hang off the same scene.
@main
struct KettoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: appDelegate.model, updates: appDelegate.updates)
        } label: {
            StatusItemLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            AppCommands(model: appDelegate.model, updates: appDelegate.updates)
        }
    }
}

/// The menu bar item: the Ketto mark, or the recording clock while a capture runs.
struct StatusItemLabel: View {
    let model: AppModel

    var body: some View {
        if let session = model.recordingSession {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("\(Image(systemName: session.isPaused ? "pause.circle.fill" : "record.circle.fill")) \(shortTimecode(session.elapsed))")
                    .monospacedDigit()
            }
        } else if model.isRecording {
            Text("\(Image(systemName: "record.circle")) …")
        } else {
            Image(nsImage: KettoMark.statusItemImage)
        }
    }
}

/// The status item's menu: the same actions as the bar plus the recent projects.
struct StatusMenu: View {
    let model: AppModel
    let updates: UpdateController

    var body: some View {
        switch model.phase {
        case .recording(let session):
            Button("Stop Recording") { model.stopRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button(session.isPaused ? "Resume Recording" : "Pause Recording") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        case .countdown:
            Button("Cancel Countdown") { model.cancelCountdown() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        case .finishing:
            Text("Saving the recording…")
        case .idle, .editing:
            Button("New Recording") { model.record() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Show Capture Bar") { model.showCaptureBar() }
                .keyboardShortcut("k", modifiers: [.command, .option])
        }
        Divider()
        Section("Recent") {
            if model.recentProjects.isEmpty {
                Text("No recordings yet")
            }
            ForEach(model.recentProjects.prefix(3), id: \.url) { bundle in
                Button(bundle.name) { model.openProject(bundle: bundle) }
                    .disabled(model.isRecording)
            }
        }
        Divider()
        Button("Library…") { model.showLibrary() }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.isRecording)
        Button("Settings…") { model.showSettings() }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(model.isRecording)
        Divider()
        if updates.isConfigured {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheck)
        }
        Button("Quit Ketto") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

/// Ketto menu: Check for Updates…, Settings… (⌘,). File menu: New Recording (⇧⌘R), Show Capture Bar (⌥⌘K),
/// Open Project… (⌘O), Library (⌘L), Export… (⌘E). Edit menu: Undo / Redo, Delete, Split Clip (⌘B), Add Zoom
/// (⌘K), Add Blur Mask (⇧⌘M), Copy Frame (⇧⌘C). Timeline menu: Zoom In / Zoom Out / Fit.
///
/// ⇧⌘R, ⇧⌘P and ⌥⌘K are also system-wide hot keys (`HotKeyCenter`); those swallow the key before the menu
/// sees it, so the equivalents here document the shortcut rather than compete with it.
struct AppCommands: Commands {
    let model: AppModel
    let updates: UpdateController

    private var session: ProjectSession? { model.currentProject }

    var body: some Commands {
        // Directly under "About Ketto", where macOS apps put these.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.isConfigured || updates.isDeferred)
            Divider()
            Button("Settings…") { model.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(model.isRecording)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { model.record() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isRecording)
            Button("Show Capture Bar") { model.showCaptureBar() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(model.isRecording)
            Button("Open Project…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.isRecording)
            Button("Library") { model.showLibrary() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.isRecording)
            Divider()
            Button("Export…") { model.requestExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!model.isEditing)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { session?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(session?.canUndo ?? false))
            Button("Redo") { session?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(session?.canRedo ?? false))
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete") { session?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(session?.selection == nil)
            Button("Split Clip at Playhead") { session?.splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(session == nil)
            Button("Add Zoom at Playhead") { session?.addZoomAtPlayhead() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(session == nil)
            Button("Add Blur Mask at Playhead") { session?.addMask(kind: .blur) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(session == nil)
            Divider()
            Button("Copy Frame") { model.copyCurrentFrame() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(session == nil)
        }
        CommandMenu("Timeline") {
            Button("Zoom In") { session?.zoomTimeline(by: 1.5) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom Out") { session?.zoomTimeline(by: 1 / 1.5) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(session == nil)
            Button("Fit to Window") { session?.timelinePixelsPerSecond = 0 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(session == nil)
        }
    }
}
