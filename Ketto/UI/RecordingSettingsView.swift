import SwiftUI
import AppKit
import AVFoundation

/// Settings › Recording: the defaults behind every recording, the keyboard capture choice, where projects are
/// stored, the system-wide shortcuts, and the permissions Ketto depends on.
struct RecordingSettingsView: View {
    let model: AppModel
    @Bindable var settings: CaptureSettings

    @State private var microphoneStatus = CapturePermissions.microphoneStatus

    var body: some View {
        SettingsPage(title: "Recording", subtitle: "Defaults for every recording. What to record and which inputs are chosen on the capture bar.") {
            SettingsColumns {
                captureSection
                keyboardSection
            } trailing: {
                shortcutsSection
                permissionsSection
                storageSection
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Sections

    private var captureSection: some View {
        SettingsSection("Capture") {
            SettingsRow("Frame rate") {
                SegmentedChoice(selection: $settings.frameRate, options: CaptureSettings.frameRateChoices.map { ($0, "\($0) fps") })
            }
            Hairline()
            SettingsRow("Countdown") {
                SegmentedChoice(selection: $settings.countdownSeconds, options: CaptureSettings.countdownChoices.map { ($0, $0 == 0 ? "Off" : "\($0) s") })
            }
            Hairline()
            SettingsRow("Hide desktop icons while recording") {
                SettingsSwitch(isOn: $settings.hideDesktopIcons, label: "Hide desktop icons while recording")
            }
            Hairline()
            SettingsRow("Camera bubble size", detail: "With the camera on, your picture floats over the display as the bubble it becomes in the video. Drag it wherever it is least in the way; it is never captured.") {
                HStack(spacing: 10) {
                    Slider(value: $settings.cameraBubbleSize, in: CameraBubbleController.sizeRange)
                        .controlSize(.small)
                        .frame(width: 110)
                        .accessibilityLabel("Camera bubble size")
                    Text("\(Int((settings.cameraBubbleSize * 100).rounded()))%")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Hairline()
            SettingsRow("Show the capture bar at launch", detail: "Otherwise Ketto waits in the menu bar: ⌥⌘K shows the bar, ⇧⌘R starts recording right away.") {
                SettingsSwitch(isOn: $settings.showsBarAtLaunch, label: "Show the capture bar at launch")
            }
        }
    }

    private var keyboardSection: some View {
        SettingsSection("Keyboard") {
            SettingsRow("Show keyboard shortcuts in the video", detail: "Shortcuts like ⌘S appear as key caps. Needs Accessibility access.") {
                SettingsSwitch(
                    isOn: Binding(get: { settings.captureKeystrokes }, set: { settings.setCaptureKeystrokes($0) }),
                    label: "Show keyboard shortcuts in the video"
                )
            }
            Hairline()
            SettingsRow(
                "Also capture everything typed",
                detail: "Typed text, passwords included, is stored in the project. Leave this off unless you need it.",
                detailColor: settings.captureAllKeystrokes ? KettoTheme.danger : KettoTheme.secondaryInk
            ) {
                SettingsSwitch(isOn: $settings.captureAllKeystrokes, label: "Also capture everything typed")
                    .disabled(!settings.captureKeystrokes)
            }
            if settings.captureKeystrokes && !settings.accessibilityTrusted {
                Hairline()
                SettingsRow("Accessibility access is off", detail: "Keystrokes are not captured until it is granted. Relaunch Ketto afterwards.", leading: StatusDot(color: KettoTheme.warning)) {
                    Button("Open System Settings…") { CapturePermissions.openAccessibilitySettings() }
                        .buttonStyle(PillButtonStyle(height: 26))
                }
            }
        }
    }

    private var storageSection: some View {
        SettingsSection("Storage") {
            SettingsRow(
                "Recordings folder",
                detail: "\(displayPath(settings.storageDirectory)) · each project keeps the untouched recording, the microphone, system audio and camera as separate tracks, and every edit. The library lists this folder."
            ) {
                HStack(spacing: 6) {
                    if !settings.usesDefaultStorageDirectory {
                        Button("Reset") { settings.resetStorageDirectory() }
                            .buttonStyle(PillButtonStyle(height: 26))
                    }
                    Button("Change…") { settings.chooseStorageDirectory() }
                        .buttonStyle(PillButtonStyle(height: 26))
                }
            }
        }
    }

    private var shortcutsSection: some View {
        SettingsSection("Shortcuts, from any app") {
            SettingsRow("Start or stop recording") { keys("⇧", "⌘", "R") }
            Hairline()
            SettingsRow("Pause or resume") { keys("⇧", "⌘", "P") }
            Hairline()
            SettingsRow("Show the capture bar") { keys("⌥", "⌘", "K") }
        }
    }

    private var permissionsSection: some View {
        SettingsSection("Permissions") {
            permissionRow(
                "Screen Recording",
                state: settings.screenRecordingGranted ? .granted : .denied,
                detail: "Required to record. Relaunch Ketto after granting it.",
                allow: { settings.requestScreenRecording() },
                openSettings: { CapturePermissions.openScreenRecordingSettings() }
            )
            Hairline()
            permissionRow(
                "Microphone",
                state: Self.state(for: microphoneStatus),
                detail: Self.detail(for: microphoneStatus, feature: "Asked the first time you switch the microphone on."),
                allow: { Task { _ = await CapturePermissions.requestMicrophone(); refreshPermissions() } },
                openSettings: { CapturePermissions.openMicrophoneSettings() }
            )
            Hairline()
            permissionRow(
                "Camera",
                state: Self.state(for: settings.cameraStatus),
                detail: Self.detail(for: settings.cameraStatus, feature: "Asked the first time you switch the camera on."),
                allow: { Task { _ = await CapturePermissions.requestCamera(); refreshPermissions() } },
                openSettings: { CapturePermissions.openCameraSettings() }
            )
            Hairline()
            permissionRow(
                "Accessibility",
                state: settings.accessibilityTrusted ? .granted : .notDetermined,
                detail: "Only for keystrokes. Relaunch Ketto after granting it.",
                allow: { settings.setCaptureKeystrokes(true) },
                openSettings: { CapturePermissions.openAccessibilitySettings() }
            )
        }
    }

    // MARK: - Pieces

    private enum PermissionState {
        case granted, denied, notDetermined
    }

    @ViewBuilder
    private func permissionRow(
        _ title: String,
        state: PermissionState,
        detail: String,
        allow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        switch state {
        case .granted:
            SettingsRow(title) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                    Text("Allowed")
                }
                .font(.system(size: 13))
                .foregroundStyle(KettoTheme.secondaryInk)
            }
        case .notDetermined:
            SettingsRow(title, detail: detail) {
                Button("Allow…", action: allow)
                    .buttonStyle(PillButtonStyle(height: 26))
            }
        case .denied:
            SettingsRow(title, detail: detail, leading: StatusDot(color: KettoTheme.warning)) {
                Button("Open System Settings…", action: openSettings)
                    .buttonStyle(PillButtonStyle(height: 26))
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
        case .authorized: return "Allowed"
        case .notDetermined: return feature
        case .denied, .restricted: return "Not allowed. Enable Ketto in System Settings › Privacy & Security."
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
    }
}

// MARK: - Settings building blocks

/// A settings page: the header and its sections, scrolling, on the canvas.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: title, subtitle: subtitle)
                    .frame(maxWidth: 620, alignment: .leading)
                content
            }
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KettoTheme.canvas)
        .tint(KettoTheme.accent)
    }
}

/// Two columns of sections when the window is wide enough, one otherwise.
struct SettingsColumns<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // Each column's ideal width is pinned at its minimum, so ViewThatFits picks two columns whenever two
        // 380pt columns fit, rather than measuring the single-line length of every description.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 24) { leading }
                    .frame(minWidth: 380, idealWidth: 380, maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 24) { trailing }
                    .frame(minWidth: 380, idealWidth: 380, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 24) {
                leading
                trailing
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

/// A titled group of rows inside a hairline card. Put a `Hairline()` between rows.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KettoTheme.secondaryInk)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                content
            }
            .card(cornerRadius: 12)
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.secondaryInk)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One settings row: a title with an optional line of detail, and the control on the trailing edge.
struct SettingsRow<Leading: View, Trailing: View>: View {
    let title: String
    var detail: String?
    var detailColor: Color = KettoTheme.secondaryInk
    var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(_ title: String, detail: String? = nil, detailColor: Color = KettoTheme.secondaryInk, leading: Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.detailColor = detailColor
        self.leading = leading
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(KettoTheme.ink)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(detailColor)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

extension SettingsRow where Leading == EmptyView {
    init(_ title: String, detail: String? = nil, detailColor: Color = KettoTheme.secondaryInk, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, detail: detail, detailColor: detailColor, leading: EmptyView(), trailing: trailing)
    }
}

/// The accent switch on a settings row.
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(KettoTheme.accent)
    }
}

/// A small segmented control: a quiet track with the chosen option raised in white.
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(isOn ? KettoTheme.ink : KettoTheme.secondaryInk)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(KettoTheme.canvas)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(KettoTheme.ink.opacity(0.08), lineWidth: 0.5))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(KettoTheme.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
    }
}
