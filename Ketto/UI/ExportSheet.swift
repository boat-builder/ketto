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

/// Export and Share: preset cards on top, the format underneath (the fields only matter for Custom), and the two
/// ways out. Share Link renders MP4 and uploads it to the user's own backend; Export saves a file or copies it.
struct ExportSheet: View {
    let session: ProjectSession
    /// Nil only if the app was assembled without a `ShareBackend`; the sheet then offers plain export only.
    var share: ShareBackend?
    var intent: ExportIntent = .export
    /// Opens Settings › Sharing; the sheet closes first.
    var setUpSharing: () -> Void = {}

    enum Destination: String, CaseIterable, Identifiable {
        case file, clipboard

        var id: String { rawValue }
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

    private static func isShareable(_ file: URL) -> Bool {
        file.pathExtension.lowercased() == ExportContainer.mp4.pathExtension
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch controller.state {
            case .idle:
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
        .padding(24)
        .frame(width: 600)
        .interactiveDismissDisabled(controller.isRunning)
        .onAppear { apply(preset) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(intent == .share ? "Share Link" : "Export")
                .font(.system(size: 20, weight: .bold))
            Text(headerSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var headerSubtitle: String {
        switch controller.state {
        case .idle:
            if intent == .share {
                if let connection = share?.connection {
                    return "Renders the edit as MP4 and uploads it to \(connection.displayName). The link works for about three days."
                }
                return "Share links need a backend of your own; set it up once in Settings › Sharing."
            }
            return "\(session.bundle.name) · \(TransportBar.timecode(session.duration))"
        case .running:
            return "Rendering \(session.bundle.name)…"
        case .uploading:
            return "Uploading to \(share?.connection?.displayName ?? "the backend")…"
        case .finished, .shared:
            return session.bundle.name
        case .failed:
            return "Something went wrong."
        }
    }

    // MARK: - States

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            presetCards
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Format").foregroundStyle(.secondary)
                    Picker("Format", selection: customised($container)) {
                        ForEach(ExportContainer.allCases) { container in
                            Text(container.displayName).tag(container)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if container.isMovie {
                    GridRow {
                        Text("Codec").foregroundStyle(.secondary)
                        Picker("Codec", selection: customised($codec)) {
                            ForEach(ExportCodec.allCases.filter { $0.isAvailable(in: container) }) { codec in
                                Text(codec.displayName).tag(codec)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Resolution").foregroundStyle(.secondary)
                        Picker("Resolution", selection: customised($resolution)) {
                            ForEach(ExportSettings.Resolution.allCases) { resolution in
                                Text(resolution.displayName).tag(resolution)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                } else {
                    GridRow {
                        Text("Width").foregroundStyle(.secondary)
                        Picker("Width", selection: customised($gifWidth)) {
                            ForEach(ExportSettings.gifWidths, id: \.self) { width in
                                Text("\(width) px").tag(width)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                GridRow {
                    Text("Frame rate").foregroundStyle(.secondary)
                    Picker("Frame rate", selection: customised($frameRate)) {
                        ForEach(container.isMovie ? ExportSettings.frameRates : ExportSettings.gifFrameRates, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if container.isMovie, codec != .proRes422 {
                    GridRow {
                        Text("Quality").foregroundStyle(.secondary)
                        HStack {
                            Slider(value: customised($quality), in: 0.5...2)
                            Text(String(format: "%.1f×", quality))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                } else if !container.isMovie {
                    GridRow {
                        Text("Loop").foregroundStyle(.secondary)
                        Toggle("Loop forever", isOn: customised($loop))
                    }
                }
                GridRow {
                    Text("Save to").foregroundStyle(.secondary)
                    Picker("Save to", selection: $destination) {
                        Text("File").tag(Destination.file)
                        Text("Clipboard").tag(Destination.clipboard)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .font(.callout)
            summary
            if container == .gif, session.duration > 20 {
                Text("GIFs longer than a few seconds get large quickly. Consider trimming the edit first.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                exportButton
                if let share {
                    if share.isConnected {
                        shareButton(share)
                    } else {
                        Button("Set Up Sharing…") {
                            dismiss()
                            setUpSharing()
                        }
                        .buttonStyle(intent == .share ? PillButtonStyle(emphasized: true) : PillButtonStyle())
                    }
                }
            }
        }
    }

    private var presetCards: some View {
        HStack(spacing: 8) {
            ForEach(ExportPreset.allCases) { candidate in
                PresetCard(preset: candidate, isSelected: candidate == preset) {
                    apply(candidate)
                }
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 18) {
            summaryItem("Output", "\(settings.sizeDescription) · \(settings.formatDescription)")
            summaryItem("Length", TransportBar.timecode(session.duration))
            summaryItem("Estimated size", ByteCountFormatter.string(fromByteCount: settings.estimatedFileSize(duration: session.duration), countStyle: .file))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func summaryItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        let title = destination == .file ? "Export…" : "Export and Copy"
        if intent == .share && isSharingConnected {
            Button(title) { startExport() }
                .buttonStyle(PillButtonStyle())
        } else {
            Button(title) { startExport() }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func shareButton(_ share: ShareBackend) -> some View {
        let button = Button {
            controller.share(session: session, settings: settings, using: share)
        } label: {
            Label("Share Link", systemImage: "link")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!canShare)
        .help(canShare
              ? "Upload to \(share.connection?.displayName ?? "the backend") and copy a link that works for about three days"
              : "Share links are MP4 only. Choose the MP4 format to share this export.")
        if intent == .share {
            button
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
        } else {
            button
                .buttonStyle(PillButtonStyle(emphasized: true))
        }
    }

    private func running(_ progress: ExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: progress.fraction)
            HStack {
                Text("Frame \(progress.framesRendered) of \(progress.totalFrames)")
                Spacer()
                Text(speedDescription(framesRendered: progress.framesRendered, elapsed: progress.elapsed))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .monospacedDigit()
            HStack {
                Spacer()
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func uploading(_ progress: UploadProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: progress.fraction)
            HStack {
                if progress.totalBytes > 0 {
                    Text("Uploading \(Self.bytes(progress.bytesSent)) of \(Self.bytes(progress.totalBytes))")
                } else {
                    Text("Starting upload…")
                }
                Spacer()
                Text("\(Int(progress.fraction * 100))%")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .monospacedDigit()
            HStack {
                Spacer()
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(url: URL, duration: Double, elapsed: Double, toClipboard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(toClipboard ? "Copied \(url.lastPathComponent) to the clipboard" : "Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(String(format: "%.1f s of video rendered in %.1f s (%.1f× real time).", duration, elapsed, elapsed > 0 ? duration / elapsed : 0))
                .font(.callout)
                .foregroundStyle(.secondary)
            if toClipboard {
                Text("Paste it into the Finder, Mail, Slack or a browser upload field.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(PillButtonStyle())
                if let share, share.isConnected, Self.isShareable(url) {
                    Button {
                        controller.shareExisting(file: url, title: session.bundle.name, using: share)
                    } label: {
                        Label("Share Link", systemImage: "link")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(PillButtonStyle(emphasized: true))
                }
                Button("Done") { dismiss() }
                    .buttonStyle(ProminentPillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func shared(link: URL, bytes: Int64, elapsed: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Link copied to the clipboard", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            HStack(spacing: 10) {
                Text(link.absoluteString)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    ShareBackend.copyLink(link)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .hoverHighlight()
                .help("Copy the link again")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            Text(String(format: "%@ uploaded in %.1f s. The link stops working after about three days; Shared Links lists it until then.", Self.bytes(bytes), elapsed))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Open in Browser") { NSWorkspace.shared.open(link) }
                    .buttonStyle(PillButtonStyle())
                Button("Done") { dismiss() }
                    .buttonStyle(ProminentPillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Try Again") { controller.reset() }
                    .buttonStyle(PillButtonStyle())
                Button("Close") { dismiss() }
                    .buttonStyle(ProminentPillButtonStyle())
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

/// One export preset as a card: an icon, the name and what it produces in a few words.
private struct PresetCard: View {
    let preset: ExportPreset
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(preset.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(shortSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(preset.summary)
    }

    private var symbol: String {
        switch preset {
        case .web: return "globe"
        case .social: return "rectangle.portrait"
        case .handoff: return "film"
        case .gif: return "photo.on.rectangle"
        case .custom: return "slider.horizontal.3"
        }
    }

    private var shortSummary: String {
        switch preset {
        case .web: return "MP4 · H.264 · 1080p60"
        case .social: return "MP4 · 1080p30 · higher bitrate"
        case .handoff: return "MOV · ProRes 422 · 60 fps"
        case .gif: return "640 px · 15 fps · looping"
        case .custom: return "Your own combination"
        }
    }
}
