import Foundation
import AppKit
import Observation

/// App-wide sharing state: the connection to the user's Worker, the videos currently on it, and the setup flow that
/// produces a new connection. Main actor throughout; the network work lives in `ShareBackendClient`.
@Observable @MainActor
final class ShareBackend {
    enum SetupPhase: Equatable {
        case idle
        /// The folder is written and the command can be copied; the app probes the domain until the Worker answers.
        case waiting
        case connected
        case failed(String)
    }

    private(set) var connection: ShareBackendConnection?
    private(set) var videos: [SharedVideo] = []
    private(set) var isLoadingVideos = false
    private(set) var videosError: String?

    /// Bound to the domain field on the settings page.
    var setupDomain = ""
    private(set) var setupPhase: SetupPhase = .idle
    private(set) var setupBundle: ShareSetupBundle?
    /// What the last probe of the new backend found, shown under the spinner while waiting.
    private(set) var setupStatus: String?

    private let store: ShareBackendStore
    private let session: URLSession
    private let setupDirectory: URL
    @ObservationIgnored private var setupTask: Task<Void, Never>?

    static let watchTimeout: TimeInterval = 15 * 60
    static let probeInterval: Duration = .seconds(3)

    init(store: ShareBackendStore? = nil, session: URLSession = .shared, setupDirectory: URL = ShareSetupBundle.defaultDirectory) {
        self.store = store ?? ShareBackendStore()
        self.session = session
        self.setupDirectory = setupDirectory
        connection = try? self.store.load()
        // A setup generated earlier but never finished (the app was quit while the command ran, say) resumes
        // the moment the settings page is opened again.
        if connection == nil, let pending = ShareSetupBundle.pending(in: setupDirectory) {
            setupBundle = pending
            setupDomain = pending.domain
            setupPhase = .waiting
        }
    }

    var isConnected: Bool { connection != nil }

    var client: ShareBackendClient? {
        connection.map { ShareBackendClient(connection: $0, session: session) }
    }

    func makeDestination(onProgress: (@Sendable (UploadProgress) -> Void)? = nil) -> CloudflareShareDestination? {
        client.map { CloudflareShareDestination(client: $0, onUploadProgress: onProgress) }
    }

    // MARK: - Connection

    func connect(_ connection: ShareBackendConnection) throws {
        try store.save(connection)
        self.connection = connection
        videos = []
        videosError = nil
        Task { await refreshVideos() }
    }

    /// For a second Mac: the address and the token copied from the first one. Checked against the Worker first.
    func connect(urlText: String, token: String) async throws {
        let connection = try ShareBackendConnection(urlText: urlText, token: token)
        _ = try await ShareBackendClient(connection: connection, session: session).status()
        try connect(connection)
    }

    func disconnect() {
        try? store.clear()
        connection = nil
        videos = []
        videosError = nil
        if setupPhase == .connected { setupPhase = .idle }
    }

    func copyTokenToPasteboard() {
        guard let token = connection?.token else { return }
        Self.copy(token)
    }

    static func copyLink(_ url: URL) {
        copy(url.absoluteString)
    }

    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Videos

    func refreshVideos() async {
        guard let client else { return }
        isLoadingVideos = true
        defer { isLoadingVideos = false }
        do {
            videos = try await client.listVideos()
            videosError = nil
        } catch {
            videosError = error.localizedDescription
        }
    }

    func delete(_ video: SharedVideo) async {
        guard let client else { return }
        do {
            try await client.deleteVideo(id: video.id)
            videos.removeAll { $0.id == video.id }
            videosError = nil
        } catch {
            videosError = error.localizedDescription
        }
    }

    // MARK: - Setup

    /// Writes the setup folder for `setupDomain` and starts watching for the Worker to come up.
    func generateSetup() {
        do {
            let bundle = try ShareSetupBundle(domain: setupDomain, directory: setupDirectory)
            try bundle.write()
            setupBundle = bundle
            setupDomain = bundle.domain
            setupStatus = nil
            setupPhase = .waiting
            startWatching()
        } catch {
            setupPhase = .failed(error.localizedDescription)
        }
    }

    func cancelSetup() {
        setupTask?.cancel()
        setupTask = nil
        setupBundle?.removeSecret()
        setupBundle = nil
        setupStatus = nil
        setupPhase = .idle
    }

    func copySetupCommand() {
        guard let command = setupBundle?.command else { return }
        Self.copy(command)
    }

    /// The settings page calls this when it appears, so a setup left waiting picks up again.
    func resumeWatchingIfNeeded() {
        if setupPhase == .waiting, setupTask == nil { startWatching() }
    }

    func checkSetupNow() {
        guard setupPhase == .waiting else { return }
        startWatching()
    }

    private func startWatching() {
        setupTask?.cancel()
        guard let bundle = setupBundle, let connection = try? bundle.connection() else { return }
        let client = ShareBackendClient(connection: connection, session: session)
        setupTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.watchTimeout)
            while !Task.isCancelled {
                let outcome = await Self.probe(client)
                guard let self, !Task.isCancelled else { return }
                switch outcome {
                case .connected:
                    do {
                        try self.connect(connection)
                        bundle.removeSecret()
                        self.setupStatus = nil
                        self.setupPhase = .connected
                    } catch {
                        self.setupPhase = .failed(error.localizedDescription)
                    }
                    self.setupTask = nil
                    return
                case .waiting(let message):
                    self.setupStatus = message
                }
                if Date() > deadline {
                    self.setupStatus = "Stopped checking after 15 minutes. Once the command has finished, use Check Now."
                    self.setupTask = nil
                    return
                }
                try? await Task.sleep(for: Self.probeInterval)
            }
        }
    }

    private enum ProbeOutcome {
        case connected
        case waiting(String)
    }

    private static func probe(_ client: ShareBackendClient) async -> ProbeOutcome {
        do {
            _ = try await client.status()
            return .connected
        } catch ShareBackendError.notConfigured {
            return .waiting("The Worker is deployed; waiting for the token to be stored.")
        } catch ShareBackendError.unauthorized {
            return .waiting("The Worker is up but rejected this token. If the command already finished, generate it again and re-run it.")
        } catch {
            return .waiting("Not reachable yet: \(error.localizedDescription)")
        }
    }
}
