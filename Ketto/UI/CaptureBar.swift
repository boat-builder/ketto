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
        let initialSize = CGSize(width: 720, height: 84)
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

/// Close · [Display | Window | Region] · inputs · Record · Library. The selected mode's segment carries the
/// source itself (the display's name, the window, the region's size) and opens its picker, so choosing what to
/// record is one control rather than a mode switch next to a separate chip.
private struct CaptureBarContent: View {
    let model: AppModel
    @Bindable var settings: CaptureSettings

    @State private var isShowingInputs = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.hideCaptureBar()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            .buttonStyle(IconButtonStyle(size: 24, cornerRadius: 12))
            .hoverHighlight(cornerRadius: 12)
            .help("Hide the capture bar. ⌥⌘K or the menu bar item brings it back.")
            .accessibilityLabel("Hide the capture bar")

            if settings.screenRecordingGranted {
                SourceSegment(model: model, settings: settings)
            } else {
                permissionButton
            }

            barDivider

            HStack(spacing: 4) {
                InputToggle(
                    symbol: "mic",
                    offSymbol: "mic.slash",
                    name: "Microphone",
                    isOn: $settings.recordMicrophone,
                    isAvailable: !settings.microphones.isEmpty,
                    help: settings.microphones.isEmpty
                        ? "No microphone found"
                        : "Microphone · \(settings.selectedMicrophone?.name ?? "")"
                )
                InputToggle(
                    symbol: "speaker.wave.2",
                    offSymbol: "speaker.slash",
                    name: "System audio",
                    isOn: $settings.recordSystemAudio,
                    help: settings.recordSystemAudio ? "System audio is recorded" : "System audio is not recorded"
                )
                InputToggle(
                    symbol: "video",
                    offSymbol: "video.slash",
                    name: "Camera",
                    isOn: $settings.recordCamera,
                    isAvailable: !settings.cameras.isEmpty,
                    needsAttention: settings.recordCamera && cameraDenied,
                    help: cameraHelp
                )
                InputToggle(
                    symbol: "keyboard",
                    offSymbol: "keyboard",
                    name: "Keystrokes",
                    isOn: Binding(
                        get: { settings.captureKeystrokes },
                        set: { settings.setCaptureKeystrokes($0) }
                    ),
                    needsAttention: settings.captureKeystrokes && !settings.accessibilityTrusted,
                    help: keyboardHelp
                )
                Button {
                    isShowingInputs.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .rotationEffect(.degrees(isShowingInputs ? 180 : 0))
                        .foregroundStyle(isShowingInputs ? KettoTheme.ink : KettoTheme.secondaryInk)
                        .frame(width: 20, height: 34)
                        .background(isShowingInputs ? KettoTheme.ink.opacity(0.08) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Microphone, camera and keystroke options")
                .accessibilityLabel("Input devices and options")
                .popover(isPresented: $isShowingInputs, arrowEdge: .top) {
                    InputsPanel(settings: settings, cameraDenied: cameraDenied)
                }
            }

            barDivider

            Button {
                model.record()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(KettoTheme.record)
                        .frame(width: 8, height: 8)
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
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            .buttonStyle(IconButtonStyle(size: 32, cornerRadius: 16))
            .hoverHighlight(cornerRadius: 16)
            .help("Library and Settings (⌘L)")
            .accessibilityLabel("Library and settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .glassSurface(Capsule(), material: .regularMaterial)
        .padding(14) // Room for the shadow inside the transparent panel.
        .tint(KettoTheme.accent)
        .onAppear {
            settings.refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            settings.refreshDisplays()
        }
        .onChange(of: settings.mode) { _, mode in
            if mode == .window { settings.refreshWindows() }
        }
        // The floating camera bubble follows the camera toggle, the chosen camera, the display it will be
        // recorded on, and its size.
        .onChange(of: settings.recordCamera) { _, _ in model.syncCameraBubble() }
        .onChange(of: settings.cameraID) { _, _ in model.syncCameraBubble() }
        .onChange(of: settings.mode) { _, _ in model.syncCameraBubble() }
        .onChange(of: settings.displayID) { _, _ in model.syncCameraBubble() }
        .onChange(of: settings.windowID) { _, _ in model.syncCameraBubble() }
        .onChange(of: settings.cameraBubbleSize) { _, _ in model.syncCameraBubble() }
    }

    private var barDivider: some View {
        Rectangle()
            .fill(KettoTheme.ink.opacity(0.12))
            .frame(width: KettoTheme.line, height: 20)
    }

    private var recordHelp: String {
        if !settings.screenRecordingGranted { return "Allow Screen Recording first" }
        switch settings.mode {
        case .display: return "Record \(settings.selectedDisplay?.name ?? "the display") (⇧⌘R)"
        case .window: return settings.selectedWindow == nil ? "Choose a window first" : "Record the window (⇧⌘R)"
        case .region: return settings.region == nil ? "Select a region first" : "Record the region (⇧⌘R)"
        }
    }

    /// Until macOS allows screen recording, the source control is replaced by the one thing to do.
    private var permissionButton: some View {
        Button {
            settings.requestScreenRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 13, weight: .regular))
                Text("Allow Screen Recording…")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(KettoTheme.accentInk)
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(height: 36)
            .background(KettoTheme.canvas, in: Capsule())
            .overlay(Capsule().strokeBorder(KettoTheme.accent, lineWidth: KettoTheme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Ketto needs Screen Recording access to record. macOS asks once; camera, microphone and keystrokes are only asked for when you switch them on. If access was denied, enable Ketto under System Settings › Privacy & Security › Screen Recording and relaunch.")
    }

    private var cameraDenied: Bool {
        settings.cameraStatus == .denied || settings.cameraStatus == .restricted
    }

    private var cameraHelp: String {
        if settings.cameras.isEmpty { return "No camera found" }
        guard settings.recordCamera else { return "The camera is not recorded" }
        if cameraDenied {
            return "Camera access was denied, so the recording will not include the camera. Enable Ketto under System Settings › Privacy & Security › Camera."
        }
        return "Camera · \(settings.selectedCamera?.name ?? ""). The floating bubble shows what is recorded; drag it wherever it is least in the way."
    }

    private var keyboardHelp: String {
        guard settings.captureKeystrokes else { return "Keystrokes are not shown on screen" }
        guard settings.accessibilityTrusted else {
            return "Keystroke capture needs Accessibility access: enable Ketto under System Settings › Privacy & Security › Accessibility, then relaunch."
        }
        return settings.captureAllKeystrokes ? "Everything typed is captured (including passwords)" : "Keyboard shortcuts are captured"
    }
}

// MARK: - Source

/// Display · Window · Region, where the selected segment is the source picker for that mode.
private struct SourceSegment: View {
    let model: AppModel
    @Bindable var settings: CaptureSettings

    @State private var isPickingWindow = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CaptureSettings.Mode.allCases) { candidate in
                if candidate == settings.mode {
                    selectedSegment
                } else {
                    Button {
                        choose(candidate)
                    } label: {
                        SegmentLabel(symbol: candidate.symbol, title: candidate.title, isSelected: false)
                    }
                    .buttonStyle(.plain)
                    .help(Self.help(for: candidate))
                }
            }
        }
        .padding(3)
        .background(KettoTheme.ink.opacity(0.06), in: Capsule())
        .popover(isPresented: $isPickingWindow, arrowEdge: .top) {
            WindowPicker(settings: settings, isPresented: $isPickingWindow)
        }
    }

    @ViewBuilder
    private var selectedSegment: some View {
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
                SegmentLabel(
                    symbol: CaptureSettings.Mode.display.symbol,
                    title: settings.selectedDisplay?.name ?? "No display",
                    isSelected: true,
                    showsChevron: true
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(settings.selectedDisplay.map { "Recording \(Self.displayDetail($0)). Click to choose another display." } ?? "The display to record")
        case .window:
            Button {
                settings.refreshWindows()
                isPickingWindow = true
            } label: {
                SegmentLabel(
                    symbol: CaptureSettings.Mode.window.symbol,
                    title: settings.selectedWindow.map(Self.windowLabel) ?? "Choose a window…",
                    isSelected: true,
                    showsChevron: true,
                    isPlaceholder: settings.selectedWindow == nil
                )
            }
            .buttonStyle(.plain)
            .help("The window to record")
        case .region:
            Button {
                model.selectRegion()
            } label: {
                SegmentLabel(
                    symbol: CaptureSettings.Mode.region.symbol,
                    title: settings.region.map { "\(Int($0.width.rounded())) × \(Int($0.height.rounded()))" } ?? "Select Region…",
                    isSelected: true,
                    isPlaceholder: settings.region == nil,
                    monospacedDigits: true
                )
            }
            .buttonStyle(.plain)
            .help("Drag out the area to record on \(settings.selectedDisplay?.name ?? "the display")")
        }
    }

    /// Switching to Window or Region with nothing chosen yet goes straight to choosing it.
    private func choose(_ mode: CaptureSettings.Mode) {
        settings.mode = mode
        switch mode {
        case .display:
            break
        case .window:
            if settings.selectedWindow == nil {
                settings.refreshWindows()
                isPickingWindow = true
            }
        case .region:
            if settings.region == nil { model.selectRegion() }
        }
    }

    private static func help(for mode: CaptureSettings.Mode) -> String {
        switch mode {
        case .display: return "Record a whole display"
        case .window: return "Record one window"
        case .region: return "Record part of a display"
        }
    }

    static func displayLabel(_ display: CaptureDisplay) -> String {
        display.isMain ? "\(display.name) (main)" : display.name
    }

    static func displayDetail(_ display: CaptureDisplay) -> String {
        let size = "\(display.pixelWidth) × \(display.pixelHeight)"
        return display.isMain ? "\(display.name), \(size), main display" : "\(display.name), \(size)"
    }

    static func windowLabel(_ window: CaptureWindow) -> String {
        window.title.isEmpty ? window.applicationName : "\(window.applicationName) — \(window.title)"
    }
}

/// One segment: an icon and a name. The selected one is a raised white pill.
private struct SegmentLabel: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    var showsChevron = false
    var isPlaceholder = false
    var monospacedDigits = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            if isSelected {
                Capsule()
                    .fill(KettoTheme.canvas)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    .overlay(Capsule().strokeBorder(KettoTheme.ink.opacity(0.08), lineWidth: 0.5))
            }
        }
        .contentShape(Capsule())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        if isPlaceholder { return KettoTheme.accentInk }
        return isSelected ? KettoTheme.ink : KettoTheme.secondaryInk
    }
}

// MARK: - Inputs

/// A round on/off button for an input: accent tint when on, bare when off.
private struct InputToggle: View {
    let symbol: String
    let offSymbol: String
    let name: String
    @Binding var isOn: Bool
    var isAvailable = true
    var needsAttention = false
    let help: String

    private var active: Bool { isOn && isAvailable }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: active ? symbol : offSymbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(active ? KettoTheme.accentInk : KettoTheme.secondaryInk)
                .frame(width: 34, height: 34)
                .background(active ? KettoTheme.accentTint : Color.clear, in: Circle())
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if needsAttention {
                        Circle()
                            .fill(KettoTheme.warning)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(KettoTheme.canvas, lineWidth: KettoTheme.line))
                            .offset(x: -3, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1 : 0.4)
        .disabled(!isAvailable)
        .help(help)
        .accessibilityLabel(name)
        .accessibilityValue(active ? "On" : "Off")
    }
}

/// The one menu behind the chevron: every input with its device, what the keyboard shows, and a switch.
private struct InputsPanel: View {
    @Bindable var settings: CaptureSettings
    let cameraDenied: Bool

    var body: some View {
        VStack(spacing: 0) {
            InputRow(symbol: "mic", title: "Microphone", isOn: $settings.recordMicrophone, isAvailable: !settings.microphones.isEmpty) {
                if settings.microphones.isEmpty {
                    caption("No microphone found")
                } else {
                    DevicePicker(title: settings.selectedMicrophone?.name ?? "Choose…") {
                        Picker("Microphone", selection: $settings.microphoneID) {
                            ForEach(settings.microphones) { device in
                                Text(device.isDefault ? "\(device.name) (Default)" : device.name).tag(Optional(device.id))
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
            }
            Hairline()
            InputRow(symbol: "speaker.wave.2", title: "System audio", isOn: $settings.recordSystemAudio) {
                caption("Whatever your Mac plays")
            }
            Hairline()
            InputRow(symbol: "video", title: "Camera", isOn: $settings.recordCamera, isAvailable: !settings.cameras.isEmpty) {
                if settings.cameras.isEmpty {
                    caption("No camera found")
                } else {
                    DevicePicker(title: settings.selectedCamera?.name ?? "Choose…") {
                        Picker("Camera", selection: $settings.cameraID) {
                            ForEach(settings.cameras) { device in
                                Text(device.isDefault ? "\(device.name) (Default)" : device.name).tag(Optional(device.id))
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    if cameraDenied {
                        settingsLink("Camera access is off · Open Settings…") { CapturePermissions.openCameraSettings() }
                    }
                }
            }
            Hairline()
            InputRow(
                symbol: "keyboard",
                title: "Keystrokes",
                isOn: Binding(get: { settings.captureKeystrokes }, set: { settings.setCaptureKeystrokes($0) })
            ) {
                DevicePicker(title: settings.captureAllKeystrokes ? "Everything typed" : "Shortcuts only") {
                    Picker("Keyboard", selection: $settings.captureAllKeystrokes) {
                        Text("Shortcuts only").tag(false)
                        Text("Everything typed (including passwords)").tag(true)
                    }
                    .pickerStyle(.inline)
                }
                if settings.captureKeystrokes && !settings.accessibilityTrusted {
                    settingsLink("Needs Accessibility access · Open Settings…") { CapturePermissions.openAccessibilitySettings() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(width: 340)
        .tint(KettoTheme.accent)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(KettoTheme.secondaryInk)
    }

    private func settingsLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(KettoTheme.accentInk)
    }
}

private struct InputRow<Detail: View>: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    var isAvailable = true
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(KettoTheme.ink)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(KettoTheme.ink)
                detail
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isAvailable)
        }
        .padding(.vertical, 10)
    }
}

/// A quiet "Device name ⌄" menu under an input's name.
private struct DevicePicker<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .font(.system(size: 12))
            .foregroundStyle(KettoTheme.secondaryInk)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose a window")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KettoTheme.ink)
                Spacer()
                if settings.isLoadingWindows {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    settings.refreshWindows()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
                .buttonStyle(IconButtonStyle(size: 24, cornerRadius: 12))
                .hoverHighlight(cornerRadius: 12)
                .help("Refresh the list")
                .accessibilityLabel("Refresh the list")
            }
            .padding(.horizontal, 2)
            if settings.windows.isEmpty {
                Text(settings.isLoadingWindows ? "Looking for windows…" : "No windows to record. Open the app you want to capture, then refresh.")
                    .font(.system(size: 13))
                    .foregroundStyle(KettoTheme.secondaryInk)
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
                    .padding(5)
                }
                .frame(maxHeight: 380)
            }
            Text("Windows of other apps. Minimized windows aren’t listed.")
                .font(.system(size: 12))
                .foregroundStyle(KettoTheme.secondaryInk)
                .padding(.horizontal, 2)
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
                        .fill(KettoTheme.fill)
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
                .frame(height: 90)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 6) {
                    appIcon
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(window.title.isEmpty ? window.applicationName : window.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(KettoTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
            }
            .padding(6)
            .background(isSelected ? KettoTheme.accentWash : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                // A 1pt accent ring with a soft tint halo outside it when selected; a faint hairline otherwise.
                if isSelected {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(KettoTheme.accentTint, lineWidth: 3)
                        .padding(-4)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(KettoTheme.accent, lineWidth: KettoTheme.line)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(KettoTheme.ink.opacity(0.12), lineWidth: 0.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(window.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var appIcon: Image {
        if let identifier = window.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(systemName: "macwindow")
    }
}
