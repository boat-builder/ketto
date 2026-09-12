import SwiftUI
import AppKit
import AVFoundation
import Combine

/// The recorder: permission state, what to capture (a display, a window or a region), audio, camera and
/// keystroke choices, the Record button, and recent projects.
struct RecorderSetupView: View {
    let model: AppModel

    enum CaptureMode: String, CaseIterable, Identifiable {
        case display, window, region

        var id: String { rawValue }

        var title: String {
            switch self {
            case .display: return "Display"
            case .window: return "Window"
            case .region: return "Region"
            }
        }
    }

    @State private var displays: [CaptureDisplay] = []
    @State private var selectedDisplayID: CGDirectDisplayID = 0
    @State private var windows: [CaptureWindow] = []
    @State private var selectedWindowID: CGWindowID = 0
    @State private var isLoadingWindows = false
    @State private var region: CGRect?
    @State private var regionPanel: RegionSelectionPanel?
    @State private var microphones: [AudioInputDevice] = []
    @State private var selectedMicrophoneID: String = ""
    @State private var cameras: [CameraDevice] = []
    @State private var selectedCameraID: String = ""
    @State private var cameraAccess = CapturePermissions.cameraStatus
    @State private var screenRecordingGranted = CapturePermissions.screenRecordingGranted
    @State private var accessibilityTrusted = CapturePermissions.accessibilityTrusted
    @State private var recentProjects: [RecordingBundle] = []
    @AppStorage("captureMode") private var captureModeRaw = CaptureMode.display.rawValue
    @AppStorage("recordMicrophone") private var recordMicrophone = true
    @AppStorage("recordSystemAudio") private var recordSystemAudio = true
    @AppStorage("recordCamera") private var recordCamera = false
    @AppStorage("cameraBubbleSize") private var cameraBubbleSize = CameraBubbleController.defaultSizeFraction
    @AppStorage("captureKeystrokes") private var captureKeystrokes = false
    @AppStorage("captureAllKeystrokes") private var captureAllKeystrokes = false
    @AppStorage("hideDesktopIcons") private var hideDesktopIcons = false
    @AppStorage("recordingFrameRate") private var frameRate = 60
    @Environment(\.openSettings) private var openSettings

    private var captureMode: CaptureMode {
        get { CaptureMode(rawValue: captureModeRaw) ?? .display }
        nonmutating set { captureModeRaw = newValue.rawValue }
    }

    private var selectedDisplay: CaptureDisplay? {
        displays.first { $0.id == selectedDisplayID } ?? displays.first
    }

    private var selectedWindow: CaptureWindow? {
        windows.first { $0.id == selectedWindowID }
    }

    /// What Record would capture, or nil while the choice is incomplete.
    private var source: CaptureSource? {
        switch captureMode {
        case .display:
            return selectedDisplay.map { .display($0) }
        case .window:
            return selectedWindow.map { .window($0) }
        case .region:
            guard let display = selectedDisplay, let region else { return nil }
            return .region(display, region)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !screenRecordingGranted {
                    permissionBanner
                }
                captureSettings
                inputSettings
                recordRow
                sharingRow
                recentProjectsSection
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshDisplays()
        }
        .onChange(of: model.libraryRevision) { _, _ in
            recentProjects = ProjectLibrary.recentProjects()
        }
        .onChange(of: captureModeRaw) { _, _ in
            if captureMode == .window { refreshWindows() }
            syncCameraBubble()
        }
        .onChange(of: selectedCameraID) { _, _ in syncCameraBubble() }
        .onChange(of: cameraBubbleSize) { _, _ in syncCameraBubble() }
        .onChange(of: selectedDisplayID) { _, _ in syncCameraBubble() }
        .onChange(of: selectedWindowID) { _, _ in syncCameraBubble() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ketto")
                    .font(.largeTitle.weight(.bold))
                Text("Record a display, a window or a region. Zooms, cursor smoothing and framing are generated for you.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            UpdateStatusView(updates: model.updates)
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.title)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen Recording access is required")
                    .font(.headline)
                Text("Ketto uses ScreenCaptureKit to capture the display you choose. macOS asks once; if access was denied, enable Ketto under System Settings → Privacy & Security → Screen Recording. Relaunch Ketto after granting access.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Grant Screen Recording Access") { requestScreenRecording() }
                        .buttonStyle(.borderedProminent)
                    Button("Open System Settings") { CapturePermissions.openScreenRecordingSettings() }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var captureSettings: some View {
        GroupBox("Capture") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Source")
                        .gridColumnAlignment(.trailing)
                    Picker("Source", selection: Binding(get: { captureMode }, set: { captureMode = $0 })) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300, alignment: .leading)
                }
                switch captureMode {
                case .display:
                    displayRow
                case .window:
                    windowRow
                case .region:
                    displayRow
                    regionRow
                }
                if captureMode != .window {
                    GridRow {
                        Text("Desktop")
                        Toggle("Hide desktop icons while recording", isOn: $hideDesktopIcons)
                    }
                }
                GridRow {
                    Text("Frame rate")
                    Picker("Frame rate", selection: $frameRate) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 200, alignment: .leading)
                }
            }
            .padding(8)
        }
    }

    private var displayRow: some View {
        GridRow {
            Text("Display")
            Picker("Display", selection: $selectedDisplayID) {
                ForEach(displays) { display in
                    Text(label(for: display)).tag(display.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    private var windowRow: some View {
        GridRow {
            Text("Window")
            HStack(spacing: 10) {
                if !screenRecordingGranted {
                    Text("Windows can be listed once Screen Recording access is granted.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Window", selection: $selectedWindowID) {
                        if windows.isEmpty {
                            Text(isLoadingWindows ? "Looking for windows…" : "No windows found").tag(CGWindowID(0))
                        }
                        ForEach(windows) { window in
                            Text(window.displayName).tag(window.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    Button {
                        refreshWindows()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh the window list")
                    .disabled(isLoadingWindows)
                }
            }
        }
    }

    private var regionRow: some View {
        GridRow {
            Text("Region")
            HStack(spacing: 10) {
                Button(region == nil ? "Select Region…" : "Change Region…") { selectRegion() }
                    .disabled(selectedDisplay == nil)
                if let region {
                    Text("\(Int(region.width.rounded())) × \(Int(region.height.rounded())) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Drag out the area to record on the chosen display.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var inputSettings: some View {
        GroupBox("Audio, Camera and Keyboard") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Microphone")
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 12) {
                        Toggle("Record microphone", isOn: $recordMicrophone)
                            .labelsHidden()
                        Picker("Microphone", selection: $selectedMicrophoneID) {
                            ForEach(microphones) { device in
                                Text(device.isDefault ? "\(device.name) (Default)" : device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .disabled(!recordMicrophone || microphones.isEmpty)
                        .frame(maxWidth: 300, alignment: .leading)
                        if microphones.isEmpty {
                            Text("No microphone found")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("System audio")
                    Toggle("Record system audio", isOn: $recordSystemAudio)
                        .labelsHidden()
                }
                GridRow {
                    Text("Camera")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Toggle("Record camera", isOn: cameraToggle)
                                .labelsHidden()
                            Picker("Camera", selection: $selectedCameraID) {
                                ForEach(cameras) { device in
                                    Text(device.isDefault ? "\(device.name) (Default)" : device.name).tag(device.id)
                                }
                            }
                            .labelsHidden()
                            .disabled(!recordCamera || cameras.isEmpty)
                            .frame(maxWidth: 300, alignment: .leading)
                            if cameras.isEmpty {
                                Text("No camera found")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if recordCamera {
                            cameraStatus
                        }
                    }
                }
                GridRow {
                    Text("Keyboard")
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Capture keyboard shortcuts to show on screen", isOn: keystrokesToggle)
                        if captureKeystrokes {
                            if accessibilityTrusted {
                                Toggle("Also capture everything typed", isOn: $captureAllKeystrokes)
                                if captureAllKeystrokes {
                                    Text("Typed text, including passwords, is stored in the project. Leave this off unless you need it.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            } else {
                                Text("Keystroke capture needs Accessibility access. Enable Ketto under System Settings → Privacy & Security → Accessibility, then relaunch.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Open System Settings") { CapturePermissions.openAccessibilitySettings() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    /// Under the camera row: the bubble's size and what it does, or why the camera cannot be used.
    @ViewBuilder
    private var cameraStatus: some View {
        switch cameraAccess {
        case .authorized:
            if !cameras.isEmpty {
                HStack(spacing: 10) {
                    Text("Bubble size")
                        .foregroundStyle(.secondary)
                    Slider(value: $cameraBubbleSize, in: CameraBubbleController.sizeRange)
                        .frame(width: 160)
                    Text("\(Int((cameraBubbleSize * 100).rounded())) %")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .controlSize(.small)
                Text("Your camera floats over the display as the bubble it becomes in the video. Drag it wherever it is least in the way — it is never captured — and the bubble starts out in the edit where you left it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 6) {
                Text("Camera access was denied, so the recording will not include the camera. Enable Ketto under System Settings → Privacy & Security → Camera.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { CapturePermissions.openCameraSettings() }
                    .controlSize(.small)
            }
        case .notDetermined:
            Text("Ketto is asking for camera access…")
                .font(.caption)
                .foregroundStyle(.secondary)
        @unknown default:
            EmptyView()
        }
    }

    /// Switching the camera on asks for access right away (the moment the feature is first used) and brings
    /// up the floating bubble; switching it off takes the bubble down.
    private var cameraToggle: Binding<Bool> {
        Binding(
            get: { recordCamera },
            set: { enabled in
                recordCamera = enabled
                syncCameraBubble()
            }
        )
    }

    private var keystrokesToggle: Binding<Bool> {
        Binding(
            get: { captureKeystrokes },
            set: { enabled in
                captureKeystrokes = enabled
                if enabled {
                    accessibilityTrusted = CapturePermissions.requestAccessibility()
                }
            }
        )
    }

    private var recordRow: some View {
        HStack(spacing: 16) {
            Button {
                record()
            } label: {
                Label("Record", systemImage: "record.circle.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(source == nil || !screenRecordingGranted)
            VStack(alignment: .leading, spacing: 2) {
                Text("A 3-second countdown runs first. Pause and stop from the floating control at the bottom of the display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Recordings are saved to \(ProjectLibrary.defaultDirectory.path).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Where share links go, or how to set that up. The sheet after an export offers the same thing.
    private var sharingRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            if let connection = model.share?.connection {
                Text("Share links go to \(connection.displayName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Manage\u{2026}") { openSettings() }
                    .controlSize(.small)
            } else {
                Text("Share links aren\u{2019}t set up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Set Up\u{2026}") { openSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Projects")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Open…") { model.presentOpenPanel() }
            }
            if recentProjects.isEmpty {
                Text("Projects you record appear here.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(recentProjects, id: \.url) { bundle in
                        ProjectCard(bundle: bundle) {
                            model.openProject(bundle: bundle)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        screenRecordingGranted = CapturePermissions.screenRecordingGranted
        accessibilityTrusted = CapturePermissions.accessibilityTrusted
        cameraAccess = CapturePermissions.cameraStatus
        refreshDisplays()
        microphones = AudioInputDevice.available()
        if !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = microphones.first(where: \.isDefault)?.id ?? microphones.first?.id ?? ""
        }
        refreshCameras()
        recentProjects = ProjectLibrary.recentProjects()
        if captureMode == .window { refreshWindows() }
        syncCameraBubble()
    }

    private func refreshCameras() {
        cameras = CameraDevice.available()
        if !cameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = cameras.first(where: \.isDefault)?.id ?? cameras.first?.id ?? ""
        }
    }

    /// Keeps the floating camera bubble in step with the recorder: shown on the display that will be recorded,
    /// from the chosen camera, at the chosen size, whenever the camera is on and usable; hidden otherwise.
    /// Asks for camera access the first time the camera is switched on.
    private func syncCameraBubble() {
        guard recordCamera else {
            model.cameraBubble.hide()
            return
        }
        Task {
            if cameraAccess == .notDetermined {
                _ = await CapturePermissions.requestCamera()
                cameraAccess = CapturePermissions.cameraStatus
                refreshCameras()
            }
            guard recordCamera else { return }
            if cameraAccess == .authorized, !cameras.isEmpty, let display = source?.display ?? selectedDisplay {
                model.cameraBubble.show(on: display, deviceID: selectedCameraID.isEmpty ? nil : selectedCameraID, sizeFraction: cameraBubbleSize)
            } else {
                model.cameraBubble.hide()
            }
        }
    }

    private func refreshDisplays() {
        displays = DisplayEnumerator.displays()
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first(where: \.isMain)?.id ?? displays.first?.id ?? 0
            region = nil
        }
    }

    private func refreshWindows() {
        guard screenRecordingGranted, !isLoadingWindows else { return }
        isLoadingWindows = true
        let displays = displays
        Task {
            let found = (try? await WindowEnumerator.windows(displays: displays)) ?? []
            windows = found
            if !found.contains(where: { $0.id == selectedWindowID }) {
                selectedWindowID = found.first?.id ?? 0
            }
            isLoadingWindows = false
        }
    }

    private func selectRegion() {
        guard let display = selectedDisplay, regionPanel == nil else { return }
        regionPanel = RegionSelectionPanel.present(on: display, initial: region) { rect in
            if let rect { region = rect }
            regionPanel = nil
        }
    }

    private func requestScreenRecording() {
        let granted = CapturePermissions.requestScreenRecording()
        screenRecordingGranted = granted
        if !granted {
            CapturePermissions.openScreenRecordingSettings()
        }
    }

    private func record() {
        guard let source else { return }
        guard CapturePermissions.screenRecordingGranted else {
            requestScreenRecording()
            return
        }
        let keystrokes: KeystrokeCaptureMode
        if captureKeystrokes, CapturePermissions.accessibilityTrusted {
            keystrokes = captureAllKeystrokes ? .everything : .shortcuts
        } else {
            keystrokes = .off
        }
        let configuration = RecordingConfiguration(
            source: source,
            fps: frameRate,
            recordMicrophone: recordMicrophone && !microphones.isEmpty,
            microphoneDeviceID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID,
            recordSystemAudio: recordSystemAudio,
            recordCamera: recordCamera && cameraAccess == .authorized && !cameras.isEmpty,
            cameraDeviceID: selectedCameraID.isEmpty ? nil : selectedCameraID,
            keystrokes: keystrokes,
            hideDesktopIcons: hideDesktopIcons
        )
        Task {
            // The bubble's preview lets go of the camera so the recording's own capture session can take it; the
            // bubble comes back with the live recording during the countdown.
            await model.cameraBubble.releaseCamera()
            model.startRecording(configuration: configuration)
        }
    }

    private func label(for display: CaptureDisplay) -> String {
        let size = "\(display.pixelWidth) × \(display.pixelHeight)"
        return display.isMain ? "\(display.name) — \(size), main" : "\(display.name) — \(size)"
    }
}

/// Version and one-click update, in the corner of the recorder. The button does exactly what the
/// Ketto menu's **Check for Updates…** does — Sparkle takes over from there, downloading,
/// verifying and installing the new build and relaunching into it. Renders nothing at all on a
/// build with no update feed configured (see `UpdateController.isConfigured`).
struct UpdateStatusView: View {
    let updates: UpdateController?

    var body: some View {
        if let updates, updates.isConfigured {
            VStack(alignment: .trailing, spacing: 4) {
                control(updates)
                Text(status(updates))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(help(updates))
        }
    }

    @ViewBuilder
    private func control(_ updates: UpdateController) -> some View {
        switch updates.phase {
        case .available(let version):
            Button {
                updates.checkForUpdates()
            } label: {
                Label("Update to v\(version)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(updates.isDeferred)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
        case .idle, .upToDate, .failed:
            Button("Check for Updates") { updates.checkForUpdates() }
                .disabled(updates.isDeferred)
        }
    }

    private func status(_ updates: UpdateController) -> String {
        let version = "v\(updates.currentVersion)"
        switch updates.phase {
        case .idle, .checking:
            return version
        case .upToDate:
            return "\(version) · Up to date"
        case .available:
            return "\(version) installed"
        case .failed:
            return "\(version) · Couldn’t check"
        }
    }

    private func help(_ updates: UpdateController) -> String {
        if case .failed(let message) = updates.phase { return message }
        return "Ketto \(updates.currentVersion)"
    }
}

/// A recent project: thumbnail, name and date.
struct ProjectCard: View {
    let bundle: RecordingBundle
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(bundle.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(modificationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = NSImage(contentsOf: bundle.thumbnailURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.secondary.opacity(0.2))
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modificationDate: Date? {
        (try? bundle.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
