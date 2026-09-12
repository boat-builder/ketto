import SwiftUI
import AppKit
import AVFoundation

/// Settings › Recording: the defaults behind every recording, the keyboard capture choice, where projects are
/// stored, the system-wide shortcuts, and the permissions Ketto depends on.
struct RecordingSettingsView: View {
    let model: AppModel
    @Bindable var settings: CaptureSettings

    @State private var microphoneStatus = CapturePermissions.microphoneStatus
    @State private var cameraStatus = CapturePermissions.cameraStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Recording", subtitle: "Defaults for every recording. The source and the inputs are chosen on the capture bar.")
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 6)
            Form {
                captureSection
                keyboardSection
                storageSection
                shortcutsSection
                permissionsSection
            }
            .formStyle(.grouped)
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Sections

    private var captureSection: some View {
        Section("Capture") {
            Picker("Frame rate", selection: $settings.frameRate) {
                ForEach(CaptureSettings.frameRateChoices, id: \.self) { rate in
                    Text("\(rate) fps").tag(rate)
                }
            }
            .pickerStyle(.segmented)
            Picker("Countdown", selection: $settings.countdownSeconds) {
                ForEach(CaptureSettings.countdownChoices, id: \.self) { seconds in
                    Text(seconds == 0 ? "Off" : "\(seconds) s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Hide desktop icons while recording", isOn: $settings.hideDesktopIcons)
            Toggle(isOn: $settings.showsBarAtLaunch) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show the capture bar at launch")
                    Text("Otherwise Ketto starts in the menu bar: ⌥⌘K shows the bar, ⇧⌘R starts recording right away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var keyboardSection: some View {
        Section("Keyboard") {
            Toggle(isOn: Binding(get: { settings.captureKeystrokes }, set: { settings.setCaptureKeystrokes($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture keyboard shortcuts to show on screen")
                    Text("Shortcuts like ⌘S appear as key caps in the video. Needs Accessibility access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $settings.captureAllKeystrokes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also capture everything typed")
                    if settings.captureAllKeystrokes {
                        Text("Typed text, including passwords, is stored in the project. Leave this off unless you need it.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(!settings.captureKeystrokes)
            if settings.captureKeystrokes && !settings.accessibilityTrusted {
                HStack(spacing: 8) {
                    StatusDot(color: .orange)
                    Text("Accessibility access is not granted, so keystrokes are not captured yet. Relaunch Ketto after granting it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open System Settings…") { CapturePermissions.openAccessibilitySettings() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Recordings folder") {
                HStack(spacing: 8) {
                    Text(displayPath(settings.storageDirectory))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Change…") { settings.chooseStorageDirectory() }
                    if !settings.usesDefaultStorageDirectory {
                        Button("Reset") { settings.resetStorageDirectory() }
                    }
                }
            }
            Text("Projects are .ketto packages: the untouched screen recording, the microphone, system audio and camera as separate tracks, and every edit in edit.json. The library lists this folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutsSection: some View {
        Section {
            LabeledContent("Start or stop recording") { keys("⇧", "⌘", "R") }
            LabeledContent("Pause or resume") { keys("⇧", "⌘", "P") }
            LabeledContent("Show the capture bar") { keys("⌥", "⌘", "K") }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("These work from any app, so a recording can start without switching to Ketto first.")
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow(
                "Screen Recording",
                symbol: "rectangle.dashed.badge.record",
                state: settings.screenRecordingGranted ? .granted : .denied,
                detail: settings.screenRecordingGranted ? "Granted" : "Required to record. Relaunch Ketto after granting it.",
                allow: { settings.requestScreenRecording() },
                openSettings: { CapturePermissions.openScreenRecordingSettings() }
            )
            permissionRow(
                "Microphone",
                symbol: "mic",
                state: Self.state(for: microphoneStatus),
                detail: Self.detail(for: microphoneStatus, feature: "Needed to record your voice."),
                allow: { Task { _ = await CapturePermissions.requestMicrophone(); refreshPermissions() } },
                openSettings: { CapturePermissions.openMicrophoneSettings() }
            )
            permissionRow(
                "Camera",
                symbol: "video",
                state: Self.state(for: cameraStatus),
                detail: Self.detail(for: cameraStatus, feature: "Needed for the camera bubble."),
                allow: { Task { _ = await CapturePermissions.requestCamera(); refreshPermissions() } },
                openSettings: { CapturePermissions.openCameraSettings() }
            )
            permissionRow(
                "Accessibility",
                symbol: "keyboard",
                state: settings.accessibilityTrusted ? .granted : .notDetermined,
                detail: settings.accessibilityTrusted ? "Granted" : "Only needed to show keystrokes on screen.",
                allow: { settings.setCaptureKeystrokes(true) },
                openSettings: { CapturePermissions.openAccessibilitySettings() }
            )
        }
    }

    // MARK: - Pieces

    private enum PermissionState {
        case granted, denied, notDetermined
    }

    private func permissionRow(
        _ title: String,
        symbol: String,
        state: PermissionState,
        detail: String,
        allow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                switch state {
                case .granted:
                    EmptyView()
                case .notDetermined:
                    Button("Allow…", action: allow)
                        .controlSize(.small)
                case .denied:
                    Button("Open System Settings…", action: openSettings)
                        .controlSize(.small)
                }
            }
        } label: {
            HStack(spacing: 8) {
                StatusDot(color: state == .granted ? .green : (state == .denied ? .orange : .gray))
                Label(title, systemImage: symbol)
            }
        }
    }

    private func keys(_ caps: String...) -> some View {
        HStack(spacing: 4) {
            ForEach(caps, id: \.self) { cap in
                KeyCap(text: cap)
            }
        }
    }

    private static func state(for status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    private static func detail(for status: AVAuthorizationStatus, feature: String) -> String {
        switch status {
        case .authorized: return "Granted"
        case .notDetermined: return feature
        case .denied, .restricted: return "Not granted. \(feature)"
        @unknown default: return feature
        }
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = url.path
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        return path
    }

    private func refreshPermissions() {
        settings.refreshPermissions()
        microphoneStatus = CapturePermissions.microphoneStatus
        cameraStatus = CapturePermissions.cameraStatus
    }
}
