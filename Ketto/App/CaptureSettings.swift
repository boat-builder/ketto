import Foundation
import AppKit
import CoreGraphics
import Observation

/// What a recording captures and how, shared by the capture bar and Settings › Recording. The defaults that
/// outlive a launch (mode, inputs, frame rate, countdown, storage) are written to `UserDefaults` as they change;
/// the chosen window and region are only ever kept for the session, because both stop existing on their own.
@Observable @MainActor
final class CaptureSettings {
    enum Mode: String, CaseIterable, Identifiable {
        case display, window, region

        var id: String { rawValue }

        var title: String {
            switch self {
            case .display: return "Display"
            case .window: return "Window"
            case .region: return "Region"
            }
        }

        var symbol: String {
            switch self {
            case .display: return "desktopcomputer"
            case .window: return "macwindow"
            case .region: return "rectangle.dashed"
            }
        }
    }

    enum Keys {
        static let mode = "captureMode"
        static let displayID = "captureDisplayID"
        static let recordMicrophone = "recordMicrophone"
        static let microphoneID = "microphoneDeviceID"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordCamera = "recordCamera"
        static let cameraID = "cameraDeviceID"
        static let captureKeystrokes = "captureKeystrokes"
        static let captureAllKeystrokes = "captureAllKeystrokes"
        static let hideDesktopIcons = "hideDesktopIcons"
        static let frameRate = "recordingFrameRate"
        static let countdown = "recordingCountdownSeconds"
        static let showsBarAtLaunch = "showsCaptureBarAtLaunch"
        static let storageDirectory = "recordingStorageDirectory"
    }

    static let countdownChoices = [0, 3, 5, 10]
    static let frameRateChoices = [30, 60]

    // MARK: Persisted choices

    // Each of these lives in `UserDefaults`; the accessors go through the observation registrar by hand, which is
    // what the `@Observable` macro does for stored properties, so the bar and the settings page both update.

    var mode: Mode {
        get { access(keyPath: \.mode); return Mode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .display }
        set { withMutation(keyPath: \.mode) { defaults.set(newValue.rawValue, forKey: Keys.mode) } }
    }

    var displayID: CGDirectDisplayID {
        get { access(keyPath: \.displayID); return CGDirectDisplayID(max(defaults.integer(forKey: Keys.displayID), 0)) }
        set { withMutation(keyPath: \.displayID) { defaults.set(Int(newValue), forKey: Keys.displayID) } }
    }

    var recordMicrophone: Bool {
        get { access(keyPath: \.recordMicrophone); return defaults.object(forKey: Keys.recordMicrophone) as? Bool ?? true }
        set { withMutation(keyPath: \.recordMicrophone) { defaults.set(newValue, forKey: Keys.recordMicrophone) } }
    }

    var microphoneID: String? {
        get { access(keyPath: \.microphoneID); return defaults.string(forKey: Keys.microphoneID) }
        set { withMutation(keyPath: \.microphoneID) { defaults.set(newValue, forKey: Keys.microphoneID) } }
    }

    var recordSystemAudio: Bool {
        get { access(keyPath: \.recordSystemAudio); return defaults.object(forKey: Keys.recordSystemAudio) as? Bool ?? true }
        set { withMutation(keyPath: \.recordSystemAudio) { defaults.set(newValue, forKey: Keys.recordSystemAudio) } }
    }

    var recordCamera: Bool {
        get { access(keyPath: \.recordCamera); return defaults.bool(forKey: Keys.recordCamera) }
        set { withMutation(keyPath: \.recordCamera) { defaults.set(newValue, forKey: Keys.recordCamera) } }
    }

    var cameraID: String? {
        get { access(keyPath: \.cameraID); return defaults.string(forKey: Keys.cameraID) }
        set { withMutation(keyPath: \.cameraID) { defaults.set(newValue, forKey: Keys.cameraID) } }
    }

    var captureKeystrokes: Bool {
        get { access(keyPath: \.captureKeystrokes); return defaults.bool(forKey: Keys.captureKeystrokes) }
        set { withMutation(keyPath: \.captureKeystrokes) { defaults.set(newValue, forKey: Keys.captureKeystrokes) } }
    }

    var captureAllKeystrokes: Bool {
        get { access(keyPath: \.captureAllKeystrokes); return defaults.bool(forKey: Keys.captureAllKeystrokes) }
        set { withMutation(keyPath: \.captureAllKeystrokes) { defaults.set(newValue, forKey: Keys.captureAllKeystrokes) } }
    }

    var hideDesktopIcons: Bool {
        get { access(keyPath: \.hideDesktopIcons); return defaults.bool(forKey: Keys.hideDesktopIcons) }
        set { withMutation(keyPath: \.hideDesktopIcons) { defaults.set(newValue, forKey: Keys.hideDesktopIcons) } }
    }

    var frameRate: Int {
        get {
            access(keyPath: \.frameRate)
            let stored = defaults.integer(forKey: Keys.frameRate)
            return Self.frameRateChoices.contains(stored) ? stored : 60
        }
        set { withMutation(keyPath: \.frameRate) { defaults.set(newValue, forKey: Keys.frameRate) } }
    }

    /// Seconds counted down before capture starts; 0 starts at once.
    var countdownSeconds: Int {
        get {
            access(keyPath: \.countdownSeconds)
            let stored = defaults.object(forKey: Keys.countdown) as? Int ?? 3
            return Self.countdownChoices.contains(stored) ? stored : 3
        }
        set { withMutation(keyPath: \.countdownSeconds) { defaults.set(newValue, forKey: Keys.countdown) } }
    }

    /// Whether launching Ketto shows the capture bar, or only the menu bar item.
    var showsBarAtLaunch: Bool {
        get { access(keyPath: \.showsBarAtLaunch); return defaults.object(forKey: Keys.showsBarAtLaunch) as? Bool ?? true }
        set { withMutation(keyPath: \.showsBarAtLaunch) { defaults.set(newValue, forKey: Keys.showsBarAtLaunch) } }
    }

    /// Where new recordings are written and which folder the library lists.
    var storageDirectory: URL {
        get {
            access(keyPath: \.storageDirectory)
            if let path = defaults.string(forKey: Keys.storageDirectory), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return ProjectLibrary.defaultDirectory
        }
        set { withMutation(keyPath: \.storageDirectory) { defaults.set(newValue.path, forKey: Keys.storageDirectory) } }
    }

    var usesDefaultStorageDirectory: Bool {
        storageDirectory.standardizedFileURL == ProjectLibrary.defaultDirectory.standardizedFileURL
    }

    // MARK: Session choices

    var windowID: CGWindowID = 0
    /// Points, Core Graphics coordinates, on `selectedDisplay`.
    var region: CGRect?

    // MARK: What is available right now

    private(set) var displays: [CaptureDisplay] = []
    private(set) var windows: [CaptureWindow] = []
    private(set) var isLoadingWindows = false
    private(set) var microphones: [AudioInputDevice] = []
    private(set) var cameras: [CameraDevice] = []
    private(set) var screenRecordingGranted = false
    private(set) var accessibilityTrusted = false

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshPermissions()
        refreshDisplays()
    }

    // MARK: - Derived

    var selectedDisplay: CaptureDisplay? {
        displays.first { $0.id == displayID } ?? displays.first
    }

    var selectedWindow: CaptureWindow? {
        windows.first { $0.id == windowID }
    }

    var selectedMicrophone: AudioInputDevice? {
        microphones.first { $0.id == microphoneID } ?? microphones.first(where: \.isDefault) ?? microphones.first
    }

    var selectedCamera: CameraDevice? {
        cameras.first { $0.id == cameraID } ?? cameras.first(where: \.isDefault) ?? cameras.first
    }

    /// What Record would capture, or nil while the choice is incomplete.
    var source: CaptureSource? {
        switch mode {
        case .display:
            return selectedDisplay.map { .display($0) }
        case .window:
            return selectedWindow.map { .window($0) }
        case .region:
            guard let display = selectedDisplay, let region else { return nil }
            return .region(display, region)
        }
    }

    /// The keystroke capture the recording will use: nothing unless the feature is on and the app is trusted.
    var keystrokeMode: KeystrokeCaptureMode {
        guard captureKeystrokes, accessibilityTrusted else { return .off }
        return captureAllKeystrokes ? .everything : .shortcuts
    }

    /// The configuration for a recording of the current choices, or nil if there is nothing to capture yet.
    func makeConfiguration() -> RecordingConfiguration? {
        guard let source else { return nil }
        return RecordingConfiguration(
            source: source,
            fps: frameRate,
            recordMicrophone: recordMicrophone && !microphones.isEmpty,
            microphoneDeviceID: selectedMicrophone?.id,
            recordSystemAudio: recordSystemAudio,
            recordCamera: recordCamera && !cameras.isEmpty,
            cameraDeviceID: selectedCamera?.id,
            keystrokes: keystrokeMode,
            hideDesktopIcons: hideDesktopIcons,
            destinationDirectory: storageDirectory
        )
    }

    // MARK: - Refreshing

    /// Re-reads permissions, displays and devices. Called whenever the bar appears or the app becomes active.
    func refreshAll() {
        refreshPermissions()
        refreshDisplays()
        refreshDevices()
        if mode == .window { refreshWindows() }
    }

    func refreshPermissions() {
        screenRecordingGranted = CapturePermissions.screenRecordingGranted
        accessibilityTrusted = CapturePermissions.accessibilityTrusted
    }

    func refreshDisplays() {
        displays = DisplayEnumerator.displays()
        if !displays.contains(where: { $0.id == displayID }) {
            displayID = displays.first(where: \.isMain)?.id ?? displays.first?.id ?? 0
            region = nil
        }
    }

    func refreshDevices() {
        microphones = AudioInputDevice.available()
        if microphoneID == nil || !microphones.contains(where: { $0.id == microphoneID }) {
            microphoneID = microphones.first(where: \.isDefault)?.id ?? microphones.first?.id
        }
        cameras = CameraDevice.available()
        if cameraID == nil || !cameras.contains(where: { $0.id == cameraID }) {
            cameraID = cameras.first(where: \.isDefault)?.id ?? cameras.first?.id
        }
    }

    func refreshWindows() {
        guard screenRecordingGranted, !isLoadingWindows else { return }
        isLoadingWindows = true
        let displays = displays
        Task { [weak self] in
            let found = (try? await WindowEnumerator.windows(displays: displays)) ?? []
            guard let self else { return }
            self.windows = found
            if !found.contains(where: { $0.id == self.windowID }) {
                self.windowID = found.first?.id ?? 0
            }
            self.isLoadingWindows = false
        }
    }

    /// Switching keystroke capture on is the one moment the Accessibility prompt may appear.
    func setCaptureKeystrokes(_ enabled: Bool) {
        captureKeystrokes = enabled
        if enabled {
            accessibilityTrusted = CapturePermissions.requestAccessibility()
        }
    }

    /// Shows the system prompt the first time; afterwards only System Settings can grant access.
    func requestScreenRecording() {
        screenRecordingGranted = CapturePermissions.requestScreenRecording()
        if !screenRecordingGranted {
            CapturePermissions.openScreenRecordingSettings()
        }
    }

    /// Lets the user pick the folder recordings are saved to.
    func chooseStorageDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Where Recordings Are Saved"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = storageDirectory
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        storageDirectory = url
    }

    func resetStorageDirectory() {
        storageDirectory = ProjectLibrary.defaultDirectory
    }
}
