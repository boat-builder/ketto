import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

/// Drives one export from the sheet: runs the `Exporter` on its queue, mirrors progress on the main actor and hands
/// the finished file to a `PublishDestination`: the local file the user picked, the clipboard, or the sharing backend.
@Observable @MainActor
final class ExportController {
    enum State {
        case idle
        case running(ExportProgress)
        case uploading(UploadProgress)
        case finished(url: URL, duration: Double, elapsed: Double, toClipboard: Bool)
        case shared(link: URL, bytes: Int64, elapsed: Double)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var exporter: Exporter?
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated init() {}

    var isRunning: Bool {
        switch state {
        case .running, .uploading: return true
        case .idle, .finished, .shared, .failed: return false
        }
    }

    /// Renders to a temporary file and hands it to `destination`: the file the user picked, or the clipboard.
    func export(session: ProjectSession, settings: ExportSettings, to destination: any PublishDestination, toClipboard: Bool) {
        guard !isRunning else { return }
        let (exporter, temporaryURL, started) = begin(session: session, settings: settings)
        let metadata = VideoMetadata(title: session.bundle.name)
        let onProgress = renderProgressHandler()
        task = Task { [weak self] in
            do {
                let rendered = try await exporter.run(progress: onProgress)
                let url = try await destination.upload(rendered, metadata: metadata, progress: { _ in })
                self?.state = .finished(url: url, duration: exporter.duration, elapsed: Date().timeIntervalSince(started), toClipboard: toClipboard)
            } catch ExportError.cancelled {
                self?.state = .idle
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: temporaryURL)
            self?.exporter = nil
            self?.task = nil
        }
    }

    /// Renders to a temporary file, uploads it to the sharing backend and leaves the link on the pasteboard.
    func share(session: ProjectSession, settings: ExportSettings, using share: ShareBackend) {
        guard !isRunning, let destination = share.makeDestination(onProgress: uploadProgressHandler()) else { return }
        let (exporter, temporaryURL, started) = begin(session: session, settings: settings)
        let metadata = VideoMetadata(title: session.bundle.name)
        let onProgress = renderProgressHandler()
        task = Task { [weak self] in
            do {
                let rendered = try await exporter.run(progress: onProgress)
                self?.state = .uploading(.zero)
                let link = try await destination.upload(rendered, metadata: metadata, progress: { _ in })
                ShareBackend.copyLink(link)
                self?.state = .shared(link: link, bytes: Self.size(of: rendered), elapsed: Date().timeIntervalSince(started))
            } catch ExportError.cancelled {
                self?.state = .idle
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: temporaryURL)
            self?.exporter = nil
            self?.task = nil
        }
    }

    /// Uploads an export that is already on disk: the Share button after a local or clipboard export.
    func shareExisting(file: URL, title: String, using share: ShareBackend) {
        guard !isRunning, let destination = share.makeDestination(onProgress: uploadProgressHandler()) else { return }
        let previous = state
        state = .uploading(.zero)
        let started = Date()
        task = Task { [weak self] in
            do {
                let link = try await destination.upload(file, metadata: VideoMetadata(title: title), progress: { _ in })
                ShareBackend.copyLink(link)
                self?.state = .shared(link: link, bytes: Self.size(of: file), elapsed: Date().timeIntervalSince(started))
            } catch is CancellationError {
                self?.state = previous
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            self?.task = nil
        }
    }

    func cancel() {
        exporter?.cancel()
        task?.cancel()
    }

    func reset() {
        guard !isRunning else { return }
        state = .idle
    }

    // MARK: - Plumbing

    private func begin(session: ProjectSession, settings: ExportSettings) -> (Exporter, URL, Date) {
        session.saveNow()
        session.player.pause()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ketto-\(UUID().uuidString)")
            .appendingPathExtension(settings.container.pathExtension)
        let exporter = Exporter(bundle: session.bundle, events: session.events, edit: session.edit, settings: settings, outputURL: temporaryURL, voiceURL: session.processedVoiceURL)
        self.exporter = exporter
        state = .running(.zero)
        return (exporter, temporaryURL, Date())
    }

    // The handlers are built here, in the main-actor scope, so the weak capture happens once: re-capturing `self`
    // inside the nested Task would be a reference to a mutable capture from concurrent code.
    private func renderProgressHandler() -> @Sendable (ExportProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                guard let controller = self, case .running = controller.state else { return }
                controller.state = .running(progress)
            }
        }
    }

    private func uploadProgressHandler() -> @Sendable (UploadProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                guard let controller = self, case .uploading = controller.state else { return }
                controller.state = .uploading(progress)
            }
        }
    }

    private static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

/// Which button opened the sheet. The sheet is the same either way; the intent picks the default action.
enum ExportIntent {
    case export
    case share
}

/// Export and Share as two questions: what (a preset card, with the format chips under it that only matter
/// for Custom), then where (a file, the clipboard, or a share link), and one primary action that does it. Share
/// Link renders MP4 and uploads it to the user's own backend; the other two save a file or copy it.
struct ExportSheet: View {
    let session: ProjectSession
    /// Nil only if the app was assembled without a `ShareBackend`; the sheet then offers plain export only.
    var share: ShareBackend?
    var intent: ExportIntent = .export
    /// Opens Settings › Sharing; the sheet closes first.
    var setUpSharing: () -> Void = {}

    enum Destination: String, CaseIterable, Identifiable {
        case file, clipboard, share

        var id: String { rawValue }

        var title: String {
            switch self {
            case .file: return "File"
            case .clipboard: return "Clipboard"
            case .share: return "Share link"
            }
        }

        var symbol: String {
            switch self {
            case .file: return "folder"
            case .clipboard: return "doc.on.doc"
            case .share: return "link"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var controller = ExportController()
    @State private var preset: ExportPreset = .web
    @State private var container: ExportContainer = .mp4
    @State private var codec: ExportCodec = .h264
    @State private var resolution: ExportSettings.Resolution = .hd1080
    @State private var gifWidth = 640
    @State private var frameRate = 60
    @State private var quality = 1.0
    @State private var loop = true
    @State private var destination: Destination = .file

    private var settings: ExportSettings {
        if container == .gif {
            var settings = ExportSettings.gif(width: gifWidth, fps: frameRate, canvas: session.edit.canvas)
            settings.loop = loop
            return settings
        }
        var settings = ExportSettings.preset(resolution, fps: frameRate, canvas: session.edit.canvas)
        settings.container = container
        settings.codec = codec.isAvailable(in: container) ? codec : .h264
        settings.quality = quality
        return settings
    }

    /// The sharing backend stores and serves MP4 only: the Worker keys every video `.mp4` and serves it as
    /// `video/mp4`, so a MOV or a GIF would come back as a broken link.
    private var canShare: Bool { container == .mp4 }

    private var isSharingConnected: Bool { share?.isConnected ?? false }

    private var destinations: [Destination] {
        share == nil ? [.file, .clipboard] : Destination.allCases
    }

    private static func isShareable(_ file: URL) -> Bool {
        file.pathExtension.lowercased() == ExportContainer.mp4.pathExtension
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch controller.state {
            case .idle:
                header
                options
            case .running(let progress):
                running(progress)
            case .uploading(let progress):
                uploading(progress)
            case .finished(let url, let duration, let elapsed, let toClipboard):
                finished(url: url, duration: duration, elapsed: elapsed, toClipboard: toClipboard)
            case .shared(let link, let bytes, let elapsed):
                shared(link: link, bytes: bytes, elapsed: elapsed)
            case .failed(let message):
                failed(message)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(KettoTheme.ink)
        .padding(20)
        .frame(width: 520)
        .background(KettoTheme.canvas)
        .tint(KettoTheme.accent)
        .interactiveDismissDisabled(controller.isRunning)
        .onAppear {
            apply(preset)
            if intent == .share, share != nil {
                destination = .share
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(intent == .share ? "Share Link" : "Export")
                .font(.system(size: 15, weight: .semibold))
            Text("\(session.bundle.name) · \(TransportBar.timecode(session.duration))")
                .foregroundStyle(KettoTheme.secondaryInk)
                .lineLimit(1)
        }
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            what
            where_
            if container == .gif, session.duration > 20 {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    StatusDot(color: KettoTheme.warning)
                    Text("GIFs longer than a few seconds get large quickly. Consider trimming the edit first.")
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
                primaryButton
            }
        }
    }

    /// What to make: the presets as cards, then the format as chips (changing one switches to Custom).
    private var what: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionTitle("What")
                if preset == .custom {
                    Text("Custom")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(KettoTheme.accentInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(KettoTheme.accentTint, in: Capsule())
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ExportPreset.allCases.filter { $0 != .custom }) { candidate in
                    PresetCard(preset: candidate, isSelected: candidate == preset) {
                        apply(candidate)
                    }
                }
            }
            formatChips
            Text("\(settings.sizeDescription) · \(settings.formatDescription) · about \(ByteCountFormatter.string(fromByteCount: settings.estimatedFileSize(duration: session.duration), countStyle: .file))")
                .font(.system(size: 12))
                .foregroundStyle(KettoTheme.secondaryInk)
                .monospacedDigit()
                .lineLimit(1)
                .help("Output size, format and estimated file size for \(TransportBar.timecode(session.duration)) of video")
        }
    }

    private var formatChips: some View {
        HStack(spacing: 6) {
            chip(container.displayName, help: "Format") {
                Picker("Format", selection: customised($container)) {
                    ForEach(ExportContainer.allCases) { container in
                        Text(container.displayName).tag(container)
                    }
                }
            }
            if container.isMovie {
                chip(codec.displayName, help: "Codec") {
                    Picker("Codec", selection: customised($codec)) {
                        ForEach(ExportCodec.allCases.filter { $0.isAvailable(in: container) }) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                }
                chip(resolution.displayName, help: "Resolution") {
                    Picker("Resolution", selection: customised($resolution)) {
                        ForEach(ExportSettings.Resolution.allCases) { resolution in
                            Text(resolution.displayName).tag(resolution)
                        }
                    }
                }
            } else {
                chip("\(gifWidth) px", help: "Width") {
                    Picker("Width", selection: customised($gifWidth)) {
                        ForEach(ExportSettings.gifWidths, id: \.self) { width in
                            Text("\(width) px").tag(width)
                        }
                    }
                }
            }
            chip("\(frameRate) fps", help: "Frame rate") {
                Picker("Frame rate", selection: customised($frameRate)) {
                    ForEach(container.isMovie ? ExportSettings.frameRates : ExportSettings.gifFrameRates, id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
            }
            if container.isMovie, codec != .proRes422 {
                chip(String(format: "Quality %.2g×", quality), help: "Quality: the bitrate relative to the preset") {
                    Picker("Quality", selection: customised($quality)) {
                        ForEach(qualitySteps, id: \.self) { step in
                            Text(String(format: "%.2g×", step)).tag(step)
                        }
                    }
                }
            } else if !container.isMovie {
                chip(loop ? "Loops" : "Plays once", help: "Loop") {
                    Picker("Loop", selection: customised($loop)) {
                        Text("Loop forever").tag(true)
                        Text("Play once").tag(false)
                    }
                }
            }
        }
    }

    private static let qualities: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private var qualitySteps: [Double] {
        Self.qualities.contains(quality) ? Self.qualities : (Self.qualities + [quality]).sorted()
    }

    /// A quiet menu chip: the current value and a small chevron.
    private func chip<Content: View>(_ title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
                .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(KettoTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }

    /// Where it goes: a file, the clipboard or a share link, with one line about what that means.
    private var where_: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Where")
            HStack(spacing: 2) {
                ForEach(destinations) { candidate in
                    let isOn = candidate == destination
                    Button {
                        destination = candidate
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: candidate.symbol)
                                .font(.system(size: 12))
                            Text(candidate.title)
                                .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                        }
                        .foregroundStyle(isOn ? KettoTheme.ink : KettoTheme.secondaryInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(KettoTheme.dynamic(light: 0xFFFFFF, dark: 0x4A4750))
                                    .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(3)
            .background(KettoTheme.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(destinationNote)
                .font(.system(size: 12))
                .foregroundStyle(destination == .share && isSharingConnected && !canShare ? KettoTheme.warning : KettoTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destinationNote: String {
        switch destination {
        case .file:
            return "You choose the folder and name next."
        case .clipboard:
            return "Paste it into the Finder, Mail, Slack or a browser upload field."
        case .share:
            guard let connection = share?.connection, isSharingConnected else {
                return "Share links need a backend of your own; set it up once in Settings › Sharing."
            }
            guard canShare else {
                return "Share links are MP4 only. Choose Web or Social, or the MP4 format, to share this export."
            }
            return "Renders an MP4 and uploads it to \(connection.displayName). The link works for about three days."
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(KettoTheme.secondaryInk)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch destination {
        case .file, .clipboard:
            Button(destination == .file ? "Export…" : "Export and Copy") { startExport() }
                .buttonStyle(ProminentPillButtonStyle(height: 32))
                .keyboardShortcut(.defaultAction)
        case .share:
            if let share, share.isConnected {
                Button {
                    controller.share(session: session, settings: settings, using: share)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 12))
                        Text("Share Link")
                    }
                }
                .buttonStyle(ProminentPillButtonStyle(height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(!canShare)
                .help(canShare
                      ? "Upload to \(share.connection?.displayName ?? "the backend") and copy a link that works for about three days"
                      : "Share links are MP4 only. Choose the MP4 format to share this export.")
            } else {
                Button("Set Up Sharing…") {
                    dismiss()
                    setUpSharing()
                }
                .buttonStyle(ProminentPillButtonStyle(height: 32))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - States

    private func progressTitle(_ title: String, fraction: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text("\(Int((fraction * 100).rounded(.down)))%")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func running(_ progress: ExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            progressTitle("Exporting \(session.bundle.name)", fraction: progress.fraction)
            ThinProgressBar(fraction: progress.fraction)
            HStack(spacing: 10) {
                Text("Frame \(progress.framesRendered) of \(progress.totalFrames)")
                Text(speedDescription(framesRendered: progress.framesRendered, elapsed: progress.elapsed))
                Spacer()
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(PillButtonStyle(height: 28))
                    .keyboardShortcut(.cancelAction)
            }
            .foregroundStyle(KettoTheme.secondaryInk)
            .monospacedDigit()
        }
    }

    private func uploading(_ progress: UploadProgress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            progressTitle("Creating your link", fraction: progress.fraction)
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11))
                    Text("Rendered")
                }
                .foregroundStyle(KettoTheme.secondaryInk)
                HStack(spacing: 6) {
                    Circle()
                        .fill(KettoTheme.accent)
                        .frame(width: 6, height: 6)
                    Text("Uploading to \(share?.connection?.displayName ?? "the backend")")
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
            }
            ThinProgressBar(fraction: progress.fraction)
            HStack {
                Group {
                    if progress.totalBytes > 0 {
                        Text("\(Self.bytes(progress.bytesSent)) of \(Self.bytes(progress.totalBytes))")
                    } else {
                        Text("Starting upload…")
                    }
                }
                .foregroundStyle(KettoTheme.secondaryInk)
                .monospacedDigit()
                Spacer()
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(PillButtonStyle(height: 28))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(url: URL, duration: Double, elapsed: Double, toClipboard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                DoneBadge()
                Text(toClipboard ? "Copied to the clipboard" : "Saved to \(url.deletingLastPathComponent().lastPathComponent)")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            Text(String(format: "%@ · %.1f s of video rendered in %.1f s (%.1f× real time).", url.lastPathComponent, duration, elapsed, elapsed > 0 ? duration / elapsed : 0))
                .foregroundStyle(KettoTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            if toClipboard {
                Text("Paste it into the Finder, Mail, Slack or a browser upload field.")
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(PillButtonStyle(height: 32))
                if let share, share.isConnected, Self.isShareable(url) {
                    Button {
                        controller.shareExisting(file: url, title: session.bundle.name, using: share)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.system(size: 12))
                            Text("Share Link")
                        }
                    }
                    .buttonStyle(PillButtonStyle(height: 32))
                }
                Button("Done") { dismiss() }
                    .buttonStyle(ProminentPillButtonStyle(height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func shared(link: URL, bytes: Int64, elapsed: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                DoneBadge()
                Text("Link copied")
                    .font(.system(size: 15, weight: .semibold))
            }
            HStack(spacing: 8) {
                Text(link.absoluteString)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    ShareBackend.copyLink(link)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
                .buttonStyle(IconButtonStyle(size: 26, cornerRadius: 8))
                .hoverHighlight(cornerRadius: 8)
                .help("Copy the link again")
                .accessibilityLabel("Copy the link again")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 36)
            .background(KettoTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(String(format: "%@ uploaded in %.1f s. Anyone with the link can watch. It stops working after about three days; Shared Links lists it until then.", Self.bytes(bytes), elapsed))
                .foregroundStyle(KettoTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Open in Browser") { NSWorkspace.shared.open(link) }
                    .buttonStyle(PillButtonStyle(height: 32))
                Button("Done") { dismiss() }
                    .buttonStyle(ProminentPillButtonStyle(height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(KettoTheme.warning, in: Circle())
                    .accessibilityHidden(true)
                Text("Export failed")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(message)
                .foregroundStyle(KettoTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Try Again") { controller.reset() }
                    .buttonStyle(PillButtonStyle(height: 32))
                Button("Close") { dismiss() }
                    .buttonStyle(ProminentPillButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Presets

    /// A binding that switches the preset to Custom whenever the user changes a field.
    private func customised<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                binding.wrappedValue = value
                preset = .custom
                if !codec.isAvailable(in: container) { codec = .h264 }
                let rates = container.isMovie ? ExportSettings.frameRates : ExportSettings.gifFrameRates
                if !rates.contains(frameRate) { frameRate = rates.last ?? 30 }
            }
        )
    }

    private func apply(_ preset: ExportPreset) {
        self.preset = preset
        guard preset != .custom else { return }
        let settings = preset.settings(canvas: session.edit.canvas)
        container = settings.container
        codec = settings.codec
        frameRate = settings.fps
        quality = settings.quality
        loop = settings.loop
        if settings.container == .gif {
            gifWidth = settings.width
        } else {
            resolution = ExportSettings.Resolution.allCases.first { $0.shortSide == min(settings.width, settings.height) } ?? .hd1080
        }
    }

    // MARK: - Actions

    private func startExport() {
        let settings = settings
        let fileName = session.bundle.name + "." + settings.container.pathExtension
        switch destination {
        case .file:
            let panel = NSSavePanel()
            panel.title = "Export"
            panel.allowedContentTypes = [settings.container.contentType]
            panel.nameFieldStringValue = fileName
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { return }
            controller.export(session: session, settings: settings, to: LocalFileDestination(targetURL: url), toClipboard: false)
        case .clipboard:
            controller.export(session: session, settings: settings, to: ClipboardDestination(fileName: fileName), toClipboard: true)
        case .share:
            // Share Link has its own action (`primaryButton`); nothing is saved locally.
            break
        }
    }

    private func speedDescription(framesRendered: Int, elapsed: Double) -> String {
        guard elapsed > 0.5, framesRendered > 0 else { return "" }
        let rendered = Double(framesRendered) / Double(settings.fps)
        return String(format: "%.1f× real time", rendered / elapsed)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// One export preset as a card: the name and what it produces in a few words. The chosen one sits on an accent
/// wash inside a 1pt accent line.
private struct PresetCard: View {
    let preset: ExportPreset
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KettoTheme.ink)
                Text(shortSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.secondaryInk)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .card(
                cornerRadius: 10,
                fill: isSelected ? KettoTheme.accentWash : KettoTheme.canvas,
                stroke: isSelected ? KettoTheme.accent : KettoTheme.track
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(preset.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var shortSummary: String {
        switch preset {
        case .web: return "MP4 · 1080p · 60 fps"
        case .social: return "MP4 · 30 fps · higher bitrate"
        case .handoff: return "ProRes 422 MOV for an editor"
        case .gif: return "Loops, no sound"
        case .custom: return "Your own combination"
        }
    }
}
