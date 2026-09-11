import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// Opening a `.recordito` package from the Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == RecordingBundle.pathExtension }) else { return }
        model.openProject(at: url)
    }

    /// The main window is hidden while recording; that must not quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.isRecording
    }

    /// Clicking the Dock icon while recording must not bring the hidden main window back into the capture.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !model.isRecording
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.handleTerminationRequest()
    }
}
