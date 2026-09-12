import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

/// Application state: recorder setup → countdown → recording → editor. Owns the record HUD and decides which
/// windows are visible in each phase. Everything here runs on the main actor.
@Observable @MainActor
final class AppModel {
    enum Phase {
        case setup
        case countdown(Int)
        case recording(RecordingSession)
        /// The stream has stopped; media is being finalised and the project opened.
        case finishing
        case editing(ProjectSession)
    }

    private(set) var phase: Phase = .setup
    var errorMessage: String?
    var isExportSheetPresented = false
    /// Statistics of the most recent recording, shown in the editor's status line.
    private(set) var lastRecordingStatistics: RecordingStatistics?
    /// Bumped whenever the project library may have changed so the setup view refreshes its list.
    private(set) var libraryRevision = 0

    /// Set by `AppDelegate` at launch. Sparkle is held off for as long as the app's windows are
    /// hidden for a capture; see `hideMainWindows()`. Observed rather than ignored because the
    /// recorder draws the update badge from it, and the assignment can land after the first render.
    var updates: UpdateController?

    @ObservationIgnored private var hud: RecordHUDPanel?
    @ObservationIgnored private var hiddenWindows: [NSWindow] = []
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var terminateAfterStop = false

    init() {}

    // MARK: - Derived state

    var isRecording: Bool {
        switch phase {
        case .countdown, .recording, .finishing: return true
        case .setup, .editing: return false
        }
    }

    var isEditing: Bool {
        if case .editing = phase { return true }
        return false
    }

    var currentProject: ProjectSession? {
        if case .editing(let session) = phase { return session }
        return nil
    }

    var recordingSession: RecordingSession? {
        if case .recording(let session) = phase { return session }
        return nil
    }

    /// Binding target for the error alert.
    var isShowingError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    // MARK: - Recording

    /// Hides the main window, shows the HUD, counts 3-2-1 and starts the session.
    func startRecording(configuration: RecordingConfiguration) {
        guard case .setup = phase else { return }
        guard CapturePermissions.screenRecordingGranted else {
            errorMessage = CaptureError.screenRecordingDenied.localizedDescription
            return
        }
        let session = RecordingSession(configuration: configuration)
        session.onUnexpectedStop = { [weak self] error in
            self?.handleUnexpectedStop(error)
        }
        hideMainWindows()
        presentHUD(for: configuration.display)
        phase = .countdown(3)
        countdownTask = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: 3, through: 1, by: -1) {
                self.phase = .countdown(remaining)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    self.abortRecording(message: nil)
                    return
                }
            }
            guard !Task.isCancelled else {
                self.abortRecording(message: nil)
                return
            }
            do {
                try await session.start()
                self.phase = .recording(session)
            } catch {
                self.abortRecording(message: error.localizedDescription)
            }
        }
    }

    /// Cancels a countdown before capture starts.
    func cancelCountdown() {
        guard case .countdown = phase else { return }
        countdownTask?.cancel()
        countdownTask = nil
    }

    private func abortRecording(message: String?) {
        countdownTask = nil
        dismissHUD()
        showMainWindows()
        phase = .setup
        if let message { errorMessage = message }
        finishTerminationIfRequested()
    }

    /// Stops capture, finalises the bundle and opens it in the editor.
    func stopRecording() {
        guard case .recording(let session) = phase else { return }
        phase = .finishing
        Task { [weak self] in
            guard let self else { return }
            do {
                let bundle = try await session.stop()
                self.lastRecordingStatistics = session.statistics
                self.libraryRevision += 1
                self.dismissHUD()
                self.showMainWindows()
                self.openProject(bundle: bundle)
            } catch {
                self.dismissHUD()
                self.showMainWindows()
                self.phase = .setup
                self.errorMessage = error.localizedDescription
            }
            self.finishTerminationIfRequested()
        }
    }

    private func handleUnexpectedStop(_ error: Error?) {
        guard case .recording = phase else { return }
        let detail = error.map { ": \($0.localizedDescription)" } ?? "."
        errorMessage = "The screen capture stopped unexpectedly\(detail) Ketto saved what was captured."
        stopRecording()
    }

    // MARK: - Projects

    func openProject(bundle: RecordingBundle) {
        do {
            let session = try ProjectSession(bundle: bundle)
            closeCurrentProject()
            phase = .editing(session)
        } catch {
            if case .finishing = phase { phase = .setup }
            errorMessage = "Could not open \(bundle.name): \(error.localizedDescription)"
        }
    }

    func openProject(at url: URL) {
        guard !isRecording else {
            errorMessage = "Finish the current recording before opening a project."
            return
        }
        do {
            openProject(bundle: try RecordingBundle.open(url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentOpenPanel() {
        guard !isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Ketto Project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.kettoProject]
        panel.directoryURL = ProjectLibrary.defaultDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    private func closeCurrentProject() {
        isExportSheetPresented = false
        if case .editing(let session) = phase {
            session.close()
        }
    }

    /// Leaves the editor and shows the recorder again.
    func returnToRecorder() {
        guard !isRecording else { return }
        closeCurrentProject()
        phase = .setup
        libraryRevision += 1
    }

    func requestExport() {
        guard isEditing else { return }
        isExportSheetPresented = true
    }

    /// Renders the frame under the playhead at canvas resolution and puts it on the clipboard as an image.
    func copyCurrentFrame() {
        guard let session = currentProject else { return }
        let composer = session.composer
        let bundle = session.bundle
        let time = session.player.currentTime
        Task { [weak self] in
            do {
                let image = try await StillFrameRenderer.render(composer: composer, bundle: bundle, outputTime: time)
                guard let cgImage = image.cgImage() else { throw RenderError.textureCreationFailed }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([NSImage(cgImage: cgImage, size: NSSize(width: image.width, height: image.height))])
            } catch {
                self?.errorMessage = "Could not copy the frame: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Termination

    /// Quitting mid-recording stops the capture first so the bundle is finalised.
    func handleTerminationRequest() -> NSApplication.TerminateReply {
        switch phase {
        case .recording:
            terminateAfterStop = true
            stopRecording()
            return .terminateLater
        case .finishing:
            terminateAfterStop = true
            return .terminateLater
        case .countdown:
            terminateAfterStop = true
            cancelCountdown()
            return .terminateLater
        case .editing(let session):
            session.close()
            return .terminateNow
        case .setup:
            return .terminateNow
        }
    }

    private func finishTerminationIfRequested() {
        guard terminateAfterStop else { return }
        terminateAfterStop = false
        if case .editing(let session) = phase { session.close() }
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - Windows

    private func hideMainWindows() {
        updates?.setDeferred(true)
        hiddenWindows = NSApplication.shared.windows.filter { $0.isVisible && !($0 is RecordHUDPanel) }
        for window in hiddenWindows {
            window.orderOut(nil)
        }
    }

    private func showMainWindows() {
        updates?.setDeferred(false)
        let windows = hiddenWindows
        hiddenWindows = []
        for window in windows {
            window.makeKeyAndOrderFront(nil)
        }
        if windows.isEmpty, let window = NSApplication.shared.windows.first(where: { !($0 is RecordHUDPanel) && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate()
    }

    private func presentHUD(for display: CaptureDisplay) {
        dismissHUD()
        let panel = RecordHUDPanel(model: self, display: display)
        hud = panel
        panel.orderFrontRegardless()
    }

    private func dismissHUD() {
        guard let hud else { return }
        hud.orderOut(nil)
        hud.close()
        self.hud = nil
    }
}
