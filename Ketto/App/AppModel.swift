import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

/// The pages of the app window. Library and Shared Links are the top of the sidebar; the rest are Settings.
enum AppPage: String, CaseIterable, Identifiable, Hashable {
    case library, sharedLinks, recording, sharing, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .sharedLinks: return "Shared Links"
        case .recording: return "Recording"
        case .sharing: return "Sharing"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "film.stack"
        case .sharedLinks: return "link"
        case .recording: return "record.circle"
        case .sharing: return "icloud.and.arrow.up"
        case .updates: return "arrow.down.circle"
        }
    }

    var isSettings: Bool {
        switch self {
        case .library, .sharedLinks: return false
        case .recording, .sharing, .updates: return true
        }
    }
}

/// Application state and the surfaces it owns: the floating capture bar, the record HUD and the app window.
/// Ketto launches as the bar (or, when that is switched off, as the menu bar item alone); the app window holds
/// the library, the settings and the editor. Everything here runs on the main actor.
@Observable @MainActor
final class AppModel {
    enum Phase {
        /// Nothing is being captured or edited: the bar, the menu bar item, or the library.
        case idle
        case countdown(Int)
        case recording(RecordingSession)
        /// The stream has stopped; media is being finalised and the project opened.
        case finishing
        case editing(ProjectSession)
    }

    private(set) var phase: Phase = .idle
    var errorMessage: String?
    var isExportSheetPresented = false
    /// What the export sheet opens for: a file, or a share link. Set by whichever button asked for it.
    var exportIntent: ExportIntent = .export
    /// The page the app window shows while no project is open.
    var page: AppPage = .library
    /// Statistics of the most recent recording, shown in the editor's status line.
    private(set) var lastRecordingStatistics: RecordingStatistics?
    /// The bundle `lastRecordingStatistics` describe, so the editor only shows them for that project.
    private(set) var lastRecordedBundle: RecordingBundle?
    /// The floating camera bubble. The bar shows it while the camera is switched on; it stays through the
    /// countdown and the recording, showing the camera as it is being recorded.
    let cameraBubble = CameraBubbleController()
    /// Bumped whenever the project library may have changed so its views refresh.
    private(set) var libraryRevision = 0
    /// The projects in the storage folder, newest first. The menu bar item shows the first three.
    private(set) var recentProjects: [RecordingBundle] = []

    /// What the next recording captures. Shared by the bar and Settings › Recording.
    let settings = CaptureSettings()

    /// Set by `AppDelegate` at launch. Sparkle is held off for as long as the app's windows are hidden for a
    /// capture; see `hideSurfacesForCapture()`. Observed rather than ignored because the settings page draws the
    /// update state from it, and the assignment can land after the first render.
    var updates: UpdateController?

    /// Set by `AppDelegate` at launch, like `updates`: the export sheet and Shared Links read it.
    var share: ShareBackend?

    @ObservationIgnored private var bar: CaptureBarPanel?
    @ObservationIgnored private var hud: RecordHUDPanel?
    @ObservationIgnored private var mainWindow: MainWindowController?
    @ObservationIgnored private var regionPanel: RegionSelectionPanel?
    @ObservationIgnored private var hiddenWindows: [NSWindow] = []
    @ObservationIgnored private var barWasVisibleBeforeCapture = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var terminateAfterStop = false
    @ObservationIgnored private let hotKeys = HotKeyCenter()

    init() {}

    // MARK: - Derived state

    var isRecording: Bool {
        switch phase {
        case .countdown, .recording, .finishing: return true
        case .idle, .editing: return false
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

    // MARK: - Launch

    /// Called once the app has finished launching: installs the shortcuts and shows the bar, unless the user
    /// chose to start in the menu bar.
    func launch() {
        hotKeys.onAction = { [weak self] action in
            self?.perform(action)
        }
        hotKeys.install()
        refreshLibrary()
        if settings.showsBarAtLaunch {
            showCaptureBar()
        }
    }

    private func perform(_ action: HotKeyCenter.Action) {
        switch action {
        case .toggleRecording: toggleRecording()
        case .togglePause: togglePause()
        case .showCaptureBar: showCaptureBar()
        }
    }

    /// The Dock icon was clicked: bring back whatever the user was doing.
    func handleReopen() {
        guard !isRecording else { return }
        if isEditing || (mainWindow?.window?.isVisible ?? false) {
            showMainWindow()
        } else {
            showCaptureBar()
        }
    }

    // MARK: - Capture bar

    var isCaptureBarVisible: Bool {
        bar?.isVisible ?? false
    }

    func showCaptureBar() {
        guard !isRecording else { return }
        settings.refreshAll()
        if bar == nil {
            bar = CaptureBarPanel(model: self)
        }
        bar?.show()
        syncCameraBubble()
    }

    func hideCaptureBar() {
        bar?.hide()
        syncCameraBubble()
    }

    /// Keeps the floating camera bubble in step with the bar: shown on the display that will be recorded, from
    /// the chosen camera, at the chosen size, whenever the bar is up with the camera on and usable; hidden
    /// otherwise. Asks for camera access the first time the camera is switched on. During a capture the bubble
    /// belongs to the recording and is left alone.
    func syncCameraBubble() {
        guard !isRecording else { return }
        guard isCaptureBarVisible, settings.recordCamera else {
            cameraBubble.hide()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if self.settings.cameraStatus == .notDetermined {
                _ = await CapturePermissions.requestCamera()
                self.settings.refreshPermissions()
                self.settings.refreshDevices()
            }
            guard !self.isRecording, self.isCaptureBarVisible, self.settings.recordCamera else { return }
            if self.settings.cameraStatus == .authorized, !self.settings.cameras.isEmpty,
               let display = self.settings.source?.display ?? self.settings.selectedDisplay {
                self.cameraBubble.show(on: display, deviceID: self.settings.selectedCamera?.id, sizeFraction: self.settings.cameraBubbleSize)
            } else {
                self.cameraBubble.hide()
            }
        }
    }

    func toggleCaptureBar() {
        if isCaptureBarVisible { hideCaptureBar() } else { showCaptureBar() }
    }

    /// Region mode: drag out the rectangle on the chosen display.
    func selectRegion() {
        guard let display = settings.selectedDisplay, regionPanel == nil else { return }
        regionPanel = RegionSelectionPanel.present(on: display, initial: settings.region) { [weak self] rect in
            guard let self else { return }
            if let rect { self.settings.region = rect }
            self.regionPanel = nil
            if let bar = self.bar, bar.isVisible { bar.show() }
        }
    }

    // MARK: - App window

    func showMainWindow() {
        if mainWindow == nil {
            mainWindow = MainWindowController(model: self)
        }
        mainWindow?.show()
    }

    func showMainWindow(page: AppPage) {
        self.page = page
        showMainWindow()
    }

    /// The gear on the bar and ⌘L: the library, in front.
    func showLibrary() {
        if !isEditing { page = .library }
        showMainWindow()
    }

    /// ⌘, and the menu bar item: the first settings page, or the sharing page when asked for.
    func showSettings(_ page: AppPage = .recording) {
        guard !isEditing else {
            // Settings are pages of the app window; leaving the editor to reach them would lose nothing, but the
            // project stays open and the page appears when the editor is closed.
            self.page = page
            closeProject()
            showMainWindow()
            return
        }
        showMainWindow(page: page)
    }

    // MARK: - Recording

    /// Record, with whatever the bar and the settings say. Asks for Screen Recording access first if needed,
    /// and brings the bar back when the choice is incomplete (no window picked, no region drawn).
    func record() {
        guard !isRecording else { return }
        settings.refreshPermissions()
        guard settings.screenRecordingGranted else {
            settings.requestScreenRecording()
            return
        }
        guard let configuration = settings.makeConfiguration() else {
            showCaptureBar()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // The bubble's preview lets go of the camera so the recording's own capture session can take it; the
            // bubble comes back with the live recording during the countdown.
            await self.cameraBubble.releaseCamera()
            self.startRecording(configuration: configuration)
        }
    }

    /// ⇧⌘R: starts a recording, cancels a countdown, or stops the recording in progress.
    func toggleRecording() {
        switch phase {
        case .idle, .editing:
            record()
        case .countdown:
            cancelCountdown()
        case .recording:
            stopRecording()
        case .finishing:
            break
        }
    }

    /// ⇧⌘P: pauses or resumes the recording in progress.
    func togglePause() {
        recordingSession?.togglePause()
    }

    /// Hides the bar and the app window, shows the HUD, counts down and starts the session.
    func startRecording(configuration: RecordingConfiguration) {
        switch phase {
        case .idle, .editing: break
        case .countdown, .recording, .finishing: return
        }
        guard CapturePermissions.screenRecordingGranted else {
            errorMessage = CaptureError.screenRecordingDenied.localizedDescription
            return
        }
        closeProject()
        let session = RecordingSession(configuration: configuration)
        session.onUnexpectedStop = { [weak self] error in
            self?.handleUnexpectedStop(error)
        }
        hideSurfacesForCapture()
        presentHUD(for: configuration.display)
        if configuration.recordCamera, !cameraBubble.isShowing {
            // Recording from the menu bar or a hot key with the bar closed: the bubble comes up for the recording.
            cameraBubble.showAwaitingRecording(on: configuration.display, sizeFraction: settings.cameraBubbleSize)
        }
        let seconds = settings.countdownSeconds
        phase = .countdown(max(seconds, 0))
        countdownTask = Task { [weak self] in
            guard let self else { return }
            // The camera warms up during the countdown, so its track starts with the first screen frame; the
            // bubble shows the recording's own camera as soon as it runs.
            let bubble = self.cameraBubble
            let preparation = Task {
                try await session.prepare()
                if let capture = session.cameraPreviewSession { bubble.attach(capture) }
            }
            if seconds > 0 {
                for remaining in stride(from: seconds, through: 1, by: -1) {
                    self.phase = .countdown(remaining)
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        await self.abandonCountdown(session, preparation: preparation)
                        return
                    }
                }
            }
            guard !Task.isCancelled else {
                await self.abandonCountdown(session, preparation: preparation)
                return
            }
            do {
                try await preparation.value
                try await session.start()
                self.phase = .recording(session)
            } catch {
                await session.cancelPreparation()
                self.cameraBubble.detachRecording()
                self.abortRecording(message: error.localizedDescription)
            }
        }
    }

    /// The countdown was cancelled: let the camera warm-up finish, then release it and go back to the bar.
    private func abandonCountdown(_ session: RecordingSession, preparation: Task<Void, Error>) async {
        _ = await preparation.result
        await session.cancelPreparation()
        cameraBubble.detachRecording()
        abortRecording(message: nil)
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
        phase = .idle
        restoreSurfacesAfterCapture(showBar: barWasVisibleBeforeCapture)
        if let message { errorMessage = message }
        finishTerminationIfRequested()
    }

    /// Stops capture, finalises the bundle and opens it in the editor.
    func stopRecording() {
        guard case .recording(let session) = phase else { return }
        // Where the bubble was left is where the camera overlay starts out in the edit.
        session.cameraPlacement = cameraBubble.placement(in: session.configuration.source.frame)
        phase = .finishing
        Task { [weak self] in
            guard let self else { return }
            do {
                let bundle = try await session.stop()
                self.cameraBubble.detachRecording()
                self.lastRecordingStatistics = session.statistics
                self.lastRecordedBundle = bundle
                self.dismissHUD()
                self.restoreSurfacesAfterCapture(showBar: false)
                self.refreshLibrary()
                self.openProject(bundle: bundle)
            } catch {
                self.cameraBubble.detachRecording()
                self.dismissHUD()
                self.phase = .idle
                self.restoreSurfacesAfterCapture(showBar: self.barWasVisibleBeforeCapture)
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
            closeProject()
            cameraBubble.hide()
            phase = .editing(session)
            hideCaptureBar()
            showMainWindow()
        } catch {
            if case .finishing = phase { phase = .idle }
            errorMessage = "Could not open \(bundle.name): \(error.localizedDescription)"
            showMainWindow(page: .library)
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
        panel.directoryURL = settings.storageDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    /// Leaves the editor for the library. The project is saved; the app window stays.
    func closeProject() {
        isExportSheetPresented = false
        if case .editing(let session) = phase {
            session.close()
            phase = .idle
            page = .library
            refreshLibrary()
        }
    }

    func requestExport(_ intent: ExportIntent = .export) {
        guard isEditing else { return }
        exportIntent = intent
        isExportSheetPresented = true
    }

    /// Re-reads the storage folder. Cheap: it lists one directory.
    func refreshLibrary() {
        recentProjects = ProjectLibrary.recentProjects(in: settings.storageDirectory, limit: 200)
        libraryRevision += 1
    }

    /// Moves a project to the Trash. The open project is never offered for deletion.
    func trashProject(_ bundle: RecordingBundle) {
        if let session = currentProject, session.bundle == bundle { return }
        do {
            try FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
        } catch {
            errorMessage = "Could not move \(bundle.name) to the Trash: \(error.localizedDescription)"
        }
        refreshLibrary()
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
            hotKeys.uninstall()
            return .terminateNow
        case .idle:
            hotKeys.uninstall()
            return .terminateNow
        }
    }

    private func finishTerminationIfRequested() {
        guard terminateAfterStop else { return }
        terminateAfterStop = false
        if case .editing(let session) = phase { session.close() }
        hotKeys.uninstall()
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - Surfaces

    /// Nothing of Ketto's may end up in the capture: the bar, the app window and any panel go away and Sparkle is
    /// held off; the HUD is the one window left, and the capture engine excludes it.
    private func hideSurfacesForCapture() {
        updates?.setDeferred(true)
        barWasVisibleBeforeCapture = isCaptureBarVisible
        bar?.hide()
        // The HUD and the camera bubble are meant to stay: neither is ever captured.
        hiddenWindows = NSApplication.shared.windows.filter {
            $0.isVisible && !($0 is RecordHUDPanel) && !($0 is CaptureBarPanel) && !($0 is CameraBubblePanel)
        }
        for window in hiddenWindows {
            window.orderOut(nil)
        }
    }

    private func restoreSurfacesAfterCapture(showBar: Bool) {
        updates?.setDeferred(false)
        let windows = hiddenWindows
        hiddenWindows = []
        for window in windows {
            window.makeKeyAndOrderFront(nil)
        }
        if showBar {
            showCaptureBar()
        } else {
            syncCameraBubble()
        }
        if !windows.isEmpty {
            NSApplication.shared.activate()
        }
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
