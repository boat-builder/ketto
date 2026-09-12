import SwiftUI

@main
struct KettoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Ketto") {
            ContentView(model: appDelegate.model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1220, height: 760)
        .commands {
            AppCommands(model: appDelegate.model, updates: appDelegate.updates)
        }
        // Settings... (Cmd-,) holds the sharing backend: setup, the connection, and the list of shared videos.
        Settings {
            SharingSettingsView(share: appDelegate.share)
        }
    }
}

/// Ketto menu: Check for Updates…. File menu: New Recording (⌘N), Open Project… (⌘O),
/// Export… (⌘E).
struct AppCommands: Commands {
    let model: AppModel
    let updates: UpdateController

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
    }
}
