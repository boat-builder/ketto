import Foundation

struct VideoMetadata: Equatable, Sendable {
    var title: String
    var description: String

    init(title: String, description: String = "") {
        self.title = title
        self.description = description
    }
}

/// Where a finished export goes. Resolved at the very end of the pipeline so that destinations slot in without
/// touching the renderer or the exporter: `LocalFileDestination` (v1) and `CloudflareShareDestination` (v3).
protocol PublishDestination: Sendable {
    var displayName: String { get }
    func authenticate() async throws
    func upload(_ file: URL, metadata: VideoMetadata, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

enum PublishError: Error, LocalizedError {
    case sourceMissing(URL)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let url): return "The exported file \(url.lastPathComponent) could not be found."
        }
    }
}

/// v1's only destination: move the rendered file to the location the user picked.
struct LocalFileDestination: PublishDestination {
    let targetURL: URL

    var displayName: String { "Local File" }

    func authenticate() async throws {}

    func upload(_ file: URL, metadata: VideoMetadata, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
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
