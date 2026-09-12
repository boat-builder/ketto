import Foundation
import AppKit

struct VideoMetadata: Equatable, Sendable {
    var title: String
    var description: String

    init(title: String, description: String = "") {
        self.title = title
        self.description = description
    }
}

/// Where a finished export goes. Resolved at the very end of the pipeline so that v3 destinations (YouTube,
/// S3 / R2) slot in without touching the renderer or the exporter.
protocol PublishDestination: Sendable {
    var displayName: String { get }
    func authenticate() async throws
    func upload(_ file: URL, metadata: VideoMetadata, progress: @Sendable (Double) -> Void) async throws -> URL
}

enum PublishError: Error, LocalizedError {
    case sourceMissing(URL)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let url): return "The exported file \(url.lastPathComponent) could not be found."
        }
    }
}

/// Move the rendered file to the location the user picked.
struct LocalFileDestination: PublishDestination {
    let targetURL: URL

    var displayName: String { "Local File" }

    func authenticate() async throws {}

    func upload(_ file: URL, metadata: VideoMetadata, progress: @Sendable (Double) -> Void) async throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: file.path) else { throw PublishError.sourceMissing(file) }
        progress(0)
        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        do {
            try fileManager.moveItem(at: file, to: targetURL)
        } catch {
            // Moving across volumes can fail for some destinations; fall back to copy + delete.
            try fileManager.copyItem(at: file, to: targetURL)
            try? fileManager.removeItem(at: file)
        }
        progress(1)
        return targetURL
    }
}

/// Put the rendered file on the clipboard, ready to paste into the Finder, Mail, Slack or a browser upload.
/// The file itself lives in the app's cache folder, so it outlives the temporary export location; only the
/// latest few exports are kept there.
struct ClipboardDestination: PublishDestination {
    let fileName: String

    var displayName: String { "Clipboard" }

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Ketto/Clipboard", isDirectory: true)
    }

    func authenticate() async throws {}

    func upload(_ file: URL, metadata: VideoMetadata, progress: @Sendable (Double) -> Void) async throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: file.path) else { throw PublishError.sourceMissing(file) }
        progress(0)
        let directory = Self.directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        do {
            try fileManager.moveItem(at: file, to: target)
        } catch {
            try fileManager.copyItem(at: file, to: target)
            try? fileManager.removeItem(at: file)
        }
        Self.trim(directory: directory, keeping: target)
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([target as NSURL])
        }
        progress(1)
        return target
    }

    /// Keeps the folder to the five most recent exports.
    private static func trim(directory: URL, keeping current: URL) {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let dated = items.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(5) where url != current {
            try? fileManager.removeItem(at: url)
        }
    }
}
