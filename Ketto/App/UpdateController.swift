import Foundation
import Observation
import Sparkle

/// In-app updates, driven by Sparkle.
///
/// The release workflow (`.github/workflows/release.yml`) publishes a Developer ID signed,
/// notarised `Ketto-<version>.zip` and an `appcast.xml` manifest to every GitHub release, and
/// `appcast.xml` is reachable at a stable `releases/latest/download/` URL — the one `SUFeedURL` in
/// `Info.plist` points at. Sparkle polls that feed, downloads the zip, verifies it against the
/// EdDSA key in `SUPublicEDKey`, swaps the bundle in place and relaunches: one click, no browser,
/// no drag-to-Applications.
///
/// Three things here are deliberate.
///
/// - **Updates switch off rather than break when unconfigured.** A checkout whose `Info.plist`
///   still carries the `SUPublicEDKey` placeholder never starts the updater, so nobody building
///   locally gets Sparkle's "this application is misconfigured" alert. The release job refuses to
///   publish such a build.
/// - **Nothing is drawn while a capture is running.** `AppModel` hides every app window during a
///   recording precisely so it stays out of the video; an update alert appearing mid-take would be
///   recorded. Sparkle's gentle scheduled reminders let us decline the window and show a badge in
///   the recorder instead.
/// - **`phase` is the only state the UI reads.** Sparkle's own properties are not observable by
///   SwiftUI, so every interesting transition is mirrored into `phase` from the delegate callbacks.
@Observable @MainActor
final class UpdateController: NSObject {
    enum Phase: Equatable {
        /// Nothing has been checked yet this launch.
        case idle
        /// A check is in flight, started by the user.
        case checking
        /// The feed was read and this build is current.
        case upToDate
        /// A newer release is on the feed; the payload is its short version string.
        case available(String)
        /// The feed could not be read. The payload is a message for the user.
        case failed(String)
    }

    /// What `Ketto/Info.plist` ships until `Scripts/generate-sparkle-keys.sh` has been run and
    /// the real public key committed. Kept in sync with the guard in the release workflow.
    static let publicKeyPlaceholder = "SPARKLE_PUBLIC_KEY_NOT_SET"

    private(set) var phase: Phase = .idle

    /// True from the moment a recording hides the app's windows until they come back. Sparkle is
    /// held off entirely while it is set.
    private(set) var isDeferred = false

    /// `CFBundleShortVersionString` of the running app, e.g. `0.2.1`.
    let currentVersion: String

    /// False when this build has no usable update feed — see `publicKeyPlaceholder`. The UI hides
    /// every update affordance instead of offering a button that cannot work.
    let isConfigured: Bool

    @ObservationIgnored private var updaterController: SPUStandardUpdaterController?

    override init() {
        let info = Bundle.main.infoDictionary
        currentVersion = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let publicKey = info?["SUPublicEDKey"] as? String ?? ""
        let feedURL = info?["SUFeedURL"] as? String ?? ""
        isConfigured = !feedURL.isEmpty && !publicKey.isEmpty && publicKey != UpdateController.publicKeyPlaceholder
        super.init()
    }

    /// Starts Sparkle. Called once from `applicationDidFinishLaunching`; a no-op on a build with no
    /// feed configured, and inside a test run.
    func start() {
        guard isConfigured, updaterController == nil else { return }
        // `xcodebuild test` launches the app as the test host, so without this the updater runs on
        // every test run: reaching the network for the feed, and — once a release exists, with
        // SUAutomaticallyUpdate on — downloading it and trying to install over the build in
        // DerivedData. The suite is meant to need no display, no permissions and no network.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        // A silent check shortly after launch, so the recorder can show a badge without Sparkle
        // putting anything on screen. Sparkle's own scheduled check still runs on its own cadence;
        // this one only ever moves `phase`.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.checkQuietly()
        }
    }

    /// Whether the check button should be live: never during a capture, never while Sparkle is
    /// already in a session of its own.
    var canCheck: Bool {
        guard let updater = updaterController?.updater else { return false }
        return updater.canCheckForUpdates && !isDeferred
    }

    /// The recorder's button and the app menu's **Check for Updates…**: Sparkle shows its progress,
    /// then its update window with the release notes and an Install button, and relaunches into the
    /// new version afterwards.
    func checkForUpdates() {
        guard let updaterController, canCheck else { return }
        phase = .checking
        updaterController.checkForUpdates(nil)
    }

    /// Reads the feed without showing anything. Only `phase` moves.
    private func checkQuietly() {
        guard canCheck, let updater = updaterController?.updater else { return }
        updater.checkForUpdateInformation()
    }

    /// Called by `AppModel` when it hides the app's windows for a capture, and again when they come
    /// back. Nothing Sparkle draws may end up in the recording.
    func setDeferred(_ deferred: Bool) {
        isDeferred = deferred
    }

    // Sparkle keeps these two in its own defaults; the accessors go through the observation registrar so
    // Settings › Updates redraws when they change. Both read false while the updater is not running.

    /// Sparkle's scheduled check (`SUEnableAutomaticChecks`).
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return updaterController?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                updaterController?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// Install found updates without asking (`SUAutomaticallyUpdate`).
    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return updaterController?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                updaterController?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }
}

// MARK: - SPUUpdaterDelegate

// Every callback carries an explicit selector. These are optional requirements of an Objective-C
// protocol: a Swift name that does not match exactly would be silently ignored rather than
// rejected by the compiler, and the app would lose the badge without anyone noticing.
extension UpdateController: SPUUpdaterDelegate {
    @objc(updater:didFindValidUpdate:)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        phase = .available(item.displayVersionString)
    }

    @objc(updaterDidNotFindUpdate:)
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        phase = .upToDate
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        switch phase {
        case .idle, .checking:
            // Neither `didFindValidUpdate` nor `updaterDidNotFindUpdate` fired, so the cycle ended
            // on something real — an unreachable feed, or one that would not parse. Reading the
            // outcome off `phase` like this avoids having to recognise Sparkle's "no update found"
            // error code, which is reported through this callback as well.
            if let error {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .upToDate
            }
        case .upToDate, .available, .failed:
            break
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

// `@preconcurrency` because `SPUStandardUserDriverDelegate` is the one Sparkle protocol used here
// that the 2.9 headers do not mark `NS_SWIFT_UI_ACTOR` — unlike `SPUUpdaterDelegate` above, which
// is annotated and so needs nothing. Without it, Swift 6 rejects a main-actor-isolated type
// satisfying nonisolated requirements. It is safe rather than papered over: every caller is
// `SPUStandardUserDriver`, which *is* `NS_SWIFT_UI_ACTOR`, so these only ever run on the main
// thread, and the attribute inserts a runtime check that would trap rather than race if that
// stopped being true. Same escape hatch `MetalPreviewView` uses for `MTKViewDelegate`.
extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    /// Opts into gentle scheduled reminders, which is what makes the two callbacks below count.
    @objc var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle asks before putting a scheduled update window on screen. During a capture the answer
    /// is no — the window would be recorded — and the badge in the recorder carries the news
    /// instead, until the user asks for the update themselves.
    @objc(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:)
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        !isDeferred
    }

    /// Fires whichever way the answer above went, so the badge is accurate in both cases.
    @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        phase = .available(update.displayVersionString)
    }
}
