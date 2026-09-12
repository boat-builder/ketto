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

struct ExportSheet: View {
    let session: ProjectSession
    /// Nil only if the app was assembled without a `ShareBackend`; the sheet then offers plain export only.
    var share: ShareBackend?

    enum Destination: String, CaseIterable, Identifiable {
        case file, clipboard

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
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

    private static func isShareable(_ file: URL) -> Bool {
        file.pathExtension.lowercased() == ExportContainer.mp4.pathExtension
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export")
                .font(.title2.weight(.semibold))
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
        .frame(width: 500)
        .interactiveDismissDisabled(controller.isRunning)
        .onAppear { apply(preset) }
    }

    // MARK: - States

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Preset", selection: presetBinding) {
                ForEach(ExportPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            Text(preset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                GridRow {
                    Text("Output").foregroundStyle(.secondary)
                    Text("\(settings.sizeDescription) · \(settings.formatDescription)")
                }
                GridRow {
                    Text("Length").foregroundStyle(.secondary)
                    Text(TransportBar.timecode(session.duration))
                }
                GridRow {
                    Text("Estimated size").foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: settings.estimatedFileSize(duration: session.duration), countStyle: .file))
                }
            }
            .font(.callout)
            if container == .gif, session.duration > 20 {
                Text("GIFs longer than a few seconds get large quickly. Consider trimming the edit first.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let share {
                    if share.isConnected {
                        Button {
                            controller.share(session: session, settings: settings, using: share)
                        } label: {
                            Label("Share Link", systemImage: "link")
                        }
                        .disabled(!canShare)
                        .help(canShare
                              ? "Upload to \(share.connection?.displayName ?? "the backend") and copy a link that works for about three days"
                              : "Share links are MP4 only. Choose the MP4 format to share this export.")
                    } else {
                        Button("Set Up Sharing…") {
                            openSettings()
                            dismiss()
                        }
                    }
                }
                Button(destination == .file ? "Export…" : "Export and Copy") { startExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
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
            HStack {
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if let share, share.isConnected, Self.isShareable(url) {
                    Button("Share…") {
                        controller.shareExisting(file: url, title: session.bundle.name, using: share)
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func shared(link: URL, bytes: Int64, elapsed: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Link copied to the clipboard", systemImage: "link.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(link.absoluteString)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text(String(format: "%@ uploaded in %.1f s. The link stops working after about three days.", Self.bytes(bytes), elapsed))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Copy Link") { ShareBackend.copyLink(link) }
                Button("Open in Browser") { NSWorkspace.shared.open(link) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
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
            HStack {
                Spacer()
                Button("Try Again") { controller.reset() }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Presets

    private var presetBinding: Binding<ExportPreset> {
        Binding(get: { preset }, set: { apply($0) })
    }

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
