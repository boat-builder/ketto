import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updates = UpdateController()
    let share = ShareBackend()

    /// Sparkle is started here rather than in `init` so the updater never runs before the app has
    /// finished launching. `AppModel` gets a reference so a recording can hold it off — an update
    /// window opening mid-capture would be recorded. The bar (or only the menu bar item) appears last.
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.updates = updates
        model.share = share
        updates.start()
        model.launch()
    }

    /// Opening a `.ketto` package from the Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == RecordingBundle.pathExtension }) else { return }
        model.openProject(at: url)
    }

    /// Ketto lives in the menu bar once its windows are closed; closing the last one never quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon brings the bar or the app window back — never during a capture, when both are
    /// hidden on purpose so they stay out of the video.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.handleReopen()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.handleTerminationRequest()
    }
}
