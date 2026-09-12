import SwiftUI
import AppKit
import Combine

/// The recorder: permission state, display and audio choices, the Record button, and recent projects.
struct RecorderSetupView: View {
    let model: AppModel

    @State private var displays: [CaptureDisplay] = []
    @State private var selectedDisplayID: CGDirectDisplayID = 0
    @State private var microphones: [AudioInputDevice] = []
    @State private var selectedMicrophoneID: String = ""
    @State private var screenRecordingGranted = CapturePermissions.screenRecordingGranted
    @State private var recentProjects: [RecordingBundle] = []
    @AppStorage("recordMicrophone") private var recordMicrophone = true
    @AppStorage("recordSystemAudio") private var recordSystemAudio = true
    @AppStorage("recordingFrameRate") private var frameRate = 60
    @Environment(\.openSettings) private var openSettings

    private var selectedDisplay: CaptureDisplay? {
        displays.first { $0.id == selectedDisplayID } ?? displays.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !screenRecordingGranted {
                    permissionBanner
                }
                captureSettings
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
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ketto")
                    .font(.largeTitle.weight(.bold))
                Text("Record a display. Zooms, cursor smoothing and framing are generated for you.")
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
                    Text("Display")
                        .gridColumnAlignment(.trailing)
                    Picker("Display", selection: $selectedDisplayID) {
                        ForEach(displays) { display in
                            Text(label(for: display)).tag(display.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
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
                GridRow {
                    Text("Microphone")
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
            }
            .padding(8)
        }
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
            .disabled(selectedDisplay == nil || !screenRecordingGranted)
            VStack(alignment: .leading, spacing: 2) {
                Text("A 3-second countdown runs first. Stop from the floating control at the bottom of the display.")
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
        refreshDisplays()
        microphones = AudioInputDevice.available()
        if !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = microphones.first(where: \.isDefault)?.id ?? microphones.first?.id ?? ""
        }
        recentProjects = ProjectLibrary.recentProjects()
    }

    private func refreshDisplays() {
        displays = DisplayEnumerator.displays()
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first(where: \.isMain)?.id ?? displays.first?.id ?? 0
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
        guard let display = selectedDisplay else { return }
        guard CapturePermissions.screenRecordingGranted else {
            requestScreenRecording()
            return
        }
        let configuration = RecordingConfiguration(
            display: display,
            fps: frameRate,
            recordMicrophone: recordMicrophone && !microphones.isEmpty,
            microphoneDeviceID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID,
            recordSystemAudio: recordSystemAudio
        )
        model.startRecording(configuration: configuration)
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
