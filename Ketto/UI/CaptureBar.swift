import SwiftUI
import AppKit

/// The floating capture bar: what Ketto shows at launch instead of a window. A borderless, non-activating
/// glass panel at the bottom of the display with the source, the inputs and Record on it. It never appears in a
/// recording (it is hidden before capture starts, and `ScreenCaptureEngine` excludes every window of this
/// process anyway). ⌥⌘K brings it back once closed.
@MainActor
final class CaptureBarPanel: NSPanel {
    private let model: AppModel
    private var lastSize: CGSize

    init(model: AppModel) {
        self.model = model
        let initialSize = CGSize(width: 760, height: 92)
        self.lastSize = initialSize
        super.init(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .utilityWindow
        let root = CaptureBarView(model: model) { [weak self] size in
            self?.fit(to: size)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: initialSize)
        contentView = hosting
        moveToBottomCenter()
    }

    override var canBecomeKey: Bool { true }

    func show() {
        if !isVisible { moveToBottomCenter() }
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    /// Keeps the panel the size of its content, anchored at its bottom centre so it grows sideways.
    private func fit(to size: CGSize) {
        guard size.width > 1, size.height > 1, size != lastSize else { return }
        lastSize = size
        let current = frame
        let origin = NSPoint(x: current.midX - size.width / 2, y: current.minY)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func moveToBottomCenter() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let target = screen.visibleFrame
        setFrameOrigin(NSPoint(x: target.midX - frame.width / 2, y: target.minY + 40))
    }
}

/// The bar's content.
struct CaptureBarView: View {
    let model: AppModel
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        CaptureBarContent(model: model, settings: model.settings)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                onSizeChange(size)
            }
    }
}

private struct CaptureBarContent: View {
    let model: AppModel
    @Bindable var settings: CaptureSettings

    @State private var isPickingWindow = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.hideCaptureBar()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(IconButtonStyle(size: 24, cornerRadius: 12))
            .help("Hide the capture bar. ⌥⌘K or the menu bar item brings it back.")

            ModeSegment(mode: $settings.mode)
                .onChange(of: settings.mode) { _, mode in
                    if mode == .window { settings.refreshWindows() }
                }

            if settings.screenRecordingGranted {
                sourceChip
            } else {
                permissionChip
            }

            barDivider

            HStack(spacing: 6) {
                microphoneToggle
                InputToggle(
                    symbol: "speaker.wave.2.fill",
                    offSymbol: "speaker.slash.fill",
                    isOn: $settings.recordSystemAudio,
                    help: settings.recordSystemAudio ? "System audio is recorded" : "System audio is not recorded"
                )
                cameraToggle
                keyboardToggle
            }

            barDivider

            Button {
                model.record()
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 2).padding(-3))
                    Text("Record")
                }
            }
            .buttonStyle(RecordButtonStyle())
            .disabled(!settings.screenRecordingGranted || settings.source == nil)
            .help(recordHelp)
            .keyboardShortcut(.defaultAction)

            Button {
                model.showLibrary()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(IconButtonStyle(size: 28, cornerRadius: 14))
            .help("Library and Settings (⌘L)")
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .glassSurface(Capsule(), material: .regularMaterial)
        .padding(14) // Room for the shadow inside the transparent panel.
        .onAppear {
            settings.refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            settings.refreshDisplays()
        }
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 22)
    }

    private var recordHelp: String {
        if !settings.screenRecordingGranted { return "Allow Screen Recording first" }
        switch settings.mode {
        case .display: return "Record \(settings.selectedDisplay?.name ?? "the display") (⇧⌘R)"
        case .window: return settings.selectedWindow == nil ? "Choose a window first" : "Record the window (⇧⌘R)"
        case .region: return settings.region == nil ? "Select a region first" : "Record the region (⇧⌘R)"
        }
    }

    // MARK: - Source

    @ViewBuilder
    private var sourceChip: some View {
        switch settings.mode {
        case .display:
            Menu {
                Picker("Display", selection: $settings.displayID) {
                    ForEach(settings.displays) { display in
                        Text(Self.displayLabel(display)).tag(display.id)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Hide Desktop Icons", isOn: $settings.hideDesktopIcons)
            } label: {
                SourceChipLabel(
                    symbol: "desktopcomputer",
                    title: settings.selectedDisplay?.name ?? "No display",
                    detail: settings.selectedDisplay.map(Self.displayDetail),
                    showsChevron: true
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The display to record")
        case .window:
            Button {
                settings.refreshWindows()
                isPickingWindow = true
            } label: {
                SourceChipLabel(
                    symbol: "macwindow",
                    title: settings.selectedWindow?.applicationName ?? "Choose a window…",
                    detail: settings.selectedWindow.flatMap { $0.title.isEmpty ? nil : $0.title },
                    showsChevron: true,
                    isPlaceholder: settings.selectedWindow == nil
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPickingWindow, arrowEdge: .top) {
                WindowPicker(settings: settings, isPresented: $isPickingWindow)
            }
            .help("The window to record")
        case .region:
            Button {
                model.selectRegion()
            } label: {
                SourceChipLabel(
                    symbol: "rectangle.dashed",
                    title: settings.region.map { "\(Int($0.width.rounded())) × \(Int($0.height.rounded())) pt" } ?? "Select Region…",
                    detail: settings.region == nil ? nil : (settings.selectedDisplay?.name),
                    showsChevron: false,
                    isPlaceholder: settings.region == nil
                )
            }
            .buttonStyle(.plain)
            .help("Drag out the area to record on \(settings.selectedDisplay?.name ?? "the display")")
        }
    }

    private var permissionChip: some View {
        Button {
            settings.requestScreenRecording()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Allow Screen Recording…")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.orange.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Ketto needs Screen Recording access to record. If access was denied, enable Ketto under System Settings › Privacy & Security › Screen Recording and relaunch.")
    }

    static func displayLabel(_ display: CaptureDisplay) -> String {
        display.isMain ? "\(display.name) (main)" : display.name
    }

    static func displayDetail(_ display: CaptureDisplay) -> String {
        let size = "\(display.pixelWidth) × \(display.pixelHeight)"
        return display.isMain ? "\(size) · main" : size
    }

    // MARK: - Inputs

    private var microphoneToggle: some View {
        HStack(spacing: 0) {
            InputToggle(
                symbol: "mic.fill",
                offSymbol: "mic.slash.fill",
                isOn: $settings.recordMicrophone,
                isAvailable: !settings.microphones.isEmpty,
                help: settings.microphones.isEmpty
                    ? "No microphone found"
                    : "Microphone · \(settings.selectedMicrophone?.name ?? "")"
            )
            DeviceMenu(help: "Choose the microphone") {
                Picker("Microphone", selection: $settings.microphoneID) {
                    ForEach(settings.microphones) { device in
                        Text(device.isDefault ? "\(device.name) (Default)" : device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(settings.microphones.isEmpty)
        }
    }

    private var cameraToggle: some View {
        HStack(spacing: 0) {
            InputToggle(
                symbol: "video.fill",
                offSymbol: "video.slash.fill",
                isOn: $settings.recordCamera,
                isAvailable: !settings.cameras.isEmpty,
                help: settings.cameras.isEmpty
                    ? "No camera found"
                    : "Camera · \(settings.selectedCamera?.name ?? "")"
            )
            DeviceMenu(help: "Choose the camera") {
                Picker("Camera", selection: $settings.cameraID) {
                    ForEach(settings.cameras) { device in
                        Text(device.isDefault ? "\(device.name) (Default)" : device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(settings.cameras.isEmpty)
        }
    }

    private var keyboardToggle: some View {
        HStack(spacing: 0) {
            InputToggle(
                symbol: "keyboard.fill",
                offSymbol: "keyboard",
                isOn: Binding(
                    get: { settings.captureKeystrokes },
                    set: { settings.setCaptureKeystrokes($0) }
                ),
                help: keyboardHelp
            )
            .overlay(alignment: .topTrailing) {
                if settings.captureKeystrokes && !settings.accessibilityTrusted {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                        .offset(x: -2, y: 2)
                }
            }
            DeviceMenu(help: "What to capture from the keyboard") {
                Picker("Keyboard", selection: $settings.captureAllKeystrokes) {
                    Text("Shortcuts only").tag(false)
                    Text("Everything typed").tag(true)
                }
                .pickerStyle(.inline)
                if !settings.accessibilityTrusted {
                    Divider()
                    Button("Open Accessibility Settings…") { CapturePermissions.openAccessibilitySettings() }
                }
            }
        }
    }

    private var keyboardHelp: String {
        guard settings.captureKeystrokes else { return "Keystrokes are not shown on screen" }
        guard settings.accessibilityTrusted else {
            return "Keystroke capture needs Accessibility access: enable Ketto under System Settings › Privacy & Security › Accessibility, then relaunch."
        }
        return settings.captureAllKeystrokes ? "Everything typed is captured (including passwords)" : "Keyboard shortcuts are captured"
    }
}

// MARK: - Pieces

/// Display · Window · Region.
private struct ModeSegment: View {
    @Binding var mode: CaptureSettings.Mode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CaptureSettings.Mode.allCases) { candidate in
                let isOn = candidate == mode
                Button {
                    mode = candidate
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: candidate.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(candidate.title)
                            .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                    }
                    .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.75))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(isOn ? Color.accentColor.opacity(0.16) : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Self.help(for: candidate))
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private static func help(for mode: CaptureSettings.Mode) -> String {
        switch mode {
        case .display: return "Record a whole display"
        case .window: return "Record one window"
        case .region: return "Record part of a display"
        }
    }
}

/// The source chip: an icon, the name, a quieter detail, and a chevron when it opens a menu.
private struct SourceChipLabel: View {
    let symbol: String
    let title: String
    var detail: String?
    var showsChevron: Bool
    var isPlaceholder = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isPlaceholder ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isPlaceholder ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .contentShape(Capsule())
    }
}

/// A round on/off button for an input.
private struct InputToggle: View {
    let symbol: String
    let offSymbol: String
    @Binding var isOn: Bool
    var isAvailable = true
    let help: String

    private var active: Bool { isOn && isAvailable }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: active ? symbol : offSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 32)
                .background(active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(help)
    }
}

/// The small chevron beside a toggle that opens its device menu.
private struct DeviceMenu<Content: View>: View {
    let help: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

// MARK: - Window picker

/// The windows that can be recorded, as thumbnails, in a popover above the bar.
private struct WindowPicker: View {
    @Bindable var settings: CaptureSettings
    @Binding var isPresented: Bool

    @State private var thumbnails: [CGWindowID: WindowThumbnail] = [:]

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose a Window")
                    .font(.headline)
                Spacer()
                if settings.isLoadingWindows {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    settings.refreshWindows()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Refresh the list")
            }
            if settings.windows.isEmpty {
                Text(settings.isLoadingWindows ? "Looking for windows…" : "No windows to record. Open the app you want to capture, then refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(settings.windows) { window in
                            WindowCard(window: window, thumbnail: thumbnails[window.id], isSelected: window.id == settings.windowID) {
                                settings.windowID = window.id
                                isPresented = false
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 380)
            }
            Text("Windows of other apps. Minimized windows are not listed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 540)
        .task(id: settings.windows.map(\.id)) {
            let windows = settings.windows
            guard !windows.isEmpty else {
                thumbnails = [:]
                return
            }
            let loaded = await WindowThumbnailer.thumbnails(for: windows)
            guard !Task.isCancelled else { return }
            thumbnails = loaded
        }
    }
}

private struct WindowCard: View {
    let window: CaptureWindow
    let thumbnail: WindowThumbnail?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let thumbnail {
                        Image(decorative: thumbnail.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        appIcon
                            .resizable()
                            .frame(width: 40, height: 40)
                    }
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                HStack(spacing: 6) {
                    appIcon
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(window.title.isEmpty ? window.applicationName : window.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(6)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(window.displayName)
    }

    private var appIcon: Image {
        if let identifier = window.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(systemName: "macwindow")
    }
}
