import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

/// Drives one export from the sheet: runs the `Exporter` on its queue, mirrors progress on the main actor and
/// hands the finished file to the `PublishDestination`.
@Observable @MainActor
final class ExportController {
    enum State {
        case idle
        case running(ExportProgress)
        case finished(url: URL, duration: Double, elapsed: Double)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var exporter: Exporter?
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated init() {}

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func export(session: ProjectSession, settings: ExportSettings, to target: URL) {
        guard !isRunning else { return }
        session.saveNow()
        session.player.pause()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ketto-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        let exporter = Exporter(bundle: session.bundle, events: session.events, edit: session.edit, settings: settings, outputURL: temporaryURL)
        self.exporter = exporter
        state = .running(.zero)
        let started = Date()
        let metadata = VideoMetadata(title: session.bundle.name)
        // The handler is built here, in the main-actor scope, so the weak capture happens once: re-capturing
        // `self` inside the nested Task would be a reference to a mutable capture from concurrent code.
        let onProgress: @Sendable (ExportProgress) -> Void = { [weak self] progress in
            guard let controller = self else { return }
            Task { @MainActor in
                guard controller.isRunning else { return }
                controller.state = .running(progress)
            }
        }
        task = Task { [weak self] in
            do {
                let rendered = try await exporter.run(progress: onProgress)
                let destination = LocalFileDestination(targetURL: target)
                let url = try await destination.upload(rendered, metadata: metadata, progress: { _ in })
                self?.state = .finished(url: url, duration: exporter.duration, elapsed: Date().timeIntervalSince(started))
            } catch ExportError.cancelled {
                self?.state = .idle
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            self?.exporter = nil
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
}

struct ExportSheet: View {
    let session: ProjectSession

    @Environment(\.dismiss) private var dismiss
    @State private var controller = ExportController()
    @State private var resolution: ExportSettings.Resolution = .hd1080
    @State private var frameRate = 60

    private var settings: ExportSettings {
        ExportSettings.preset(resolution, fps: frameRate, canvas: session.edit.canvas)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Video")
                .font(.title2.weight(.semibold))
            switch controller.state {
            case .idle:
                options
            case .running(let progress):
                running(progress)
            case .finished(let url, let duration, let elapsed):
                finished(url: url, duration: duration, elapsed: elapsed)
            case .failed(let message):
                failed(message)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(controller.isRunning)
    }

    // MARK: - States

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Resolution", selection: $resolution) {
                ForEach(ExportSettings.Resolution.allCases) { resolution in
                    Text(resolution.displayName).tag(resolution)
                }
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: $frameRate) {
                ForEach(ExportSettings.frameRates, id: \.self) { rate in
                    Text("\(rate) fps").tag(rate)
                }
            }
            .pickerStyle(.segmented)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Output").foregroundStyle(.secondary)
                    Text("\(settings.sizeDescription) · H.264 · AAC · MP4")
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
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { chooseDestinationAndExport() }
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

    private func finished(url: URL, duration: Double, elapsed: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(String(format: "%.1f s of video rendered in %.1f s (%.1f× real time).", duration, elapsed, elapsed > 0 ? duration / elapsed : 0))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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

    // MARK: - Actions

    private func chooseDestinationAndExport() {
        let panel = NSSavePanel()
        panel.title = "Export Video"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = session.bundle.name + ".mp4"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.export(session: session, settings: settings, to: url)
    }

    private func speedDescription(framesRendered: Int, elapsed: Double) -> String {
        guard elapsed > 0.5, framesRendered > 0 else { return "" }
        let rendered = Double(framesRendered) / Double(settings.fps)
        return String(format: "%.1f× real time", rendered / elapsed)
    }
}
