import SwiftUI

@main
struct RecorditoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Recordito") {
            ContentView(model: appDelegate.model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1220, height: 760)
        .commands {
            AppCommands(model: appDelegate.model, updates: appDelegate.updates)
        }
    }
}

/// Recordito menu: Check for Updates…. File menu: New Recording (⌘N), Open Project… (⌘O),
/// Export… (⌘E).
struct AppCommands: Commands {
    let model: AppModel
    let updates: UpdateController

    var body: some Commands {
        // Directly under "About Recordito", where macOS apps put this.
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
