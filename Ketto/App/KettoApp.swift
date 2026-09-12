import SwiftUI

@main
struct KettoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Ketto") {
            ContentView(model: appDelegate.model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 840)
        .commands {
            AppCommands(model: appDelegate.model, updates: appDelegate.updates)
        }
        // Settings... (Cmd-,) holds the sharing backend: setup, the connection, and the list of shared videos.
        Settings {
            SharingSettingsView(share: appDelegate.share)
        }
    }
}

/// Ketto menu: Check for Updates…. File menu: New Recording (⌘N), Open Project… (⌘O), Export… (⌘E).
/// Edit menu: Undo / Redo, Delete, Split Clip (⌘B), Add Zoom (⌘K), Add Blur Mask (⇧⌘M), Copy Frame (⇧⌘C).
/// Timeline menu: Zoom In / Zoom Out / Fit.
struct AppCommands: Commands {
    let model: AppModel
    let updates: UpdateController

    private var session: ProjectSession? { model.currentProject }

    var body: some Commands {
        // Directly under "About Ketto", where macOS apps put this.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.isConfigured || updates.isDeferred)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { model.returnToRecorder() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isRecording)
            Button("Open Project…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
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
