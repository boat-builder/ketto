import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let kettoProject = UTType(exportedAs: "cc.ketto.project", conformingTo: .package)
}

enum RecordingBundleError: Error, LocalizedError {
    case notADirectory(URL)
    case missingScreenRecording(URL)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let url): return "\(url.lastPathComponent) is not a Ketto project."
        case .missingScreenRecording(let url): return "\(url.lastPathComponent) has no screen recording."
        }
    }
}

/// A `Name.ketto/` package directory. Source media is never rewritten; all edits live in `edit.json`.
struct RecordingBundle: Equatable, Hashable, Sendable {
    static let pathExtension = "ketto"

    let url: URL

    init(url: URL) {
        self.url = url
    }

    var name: String { url.deletingPathExtension().lastPathComponent }
    var screenURL: URL { url.appendingPathComponent("screen.mov") }
    var micURL: URL { url.appendingPathComponent("mic.caf") }
    var systemAudioURL: URL { url.appendingPathComponent("system.caf") }
    var cameraURL: URL { url.appendingPathComponent("camera.mov") }
    var eventsURL: URL { url.appendingPathComponent("events.json") }
    var editURL: URL { url.appendingPathComponent("edit.json") }
    var thumbnailURL: URL { url.appendingPathComponent("thumbnail.png") }

    var hasMicTrack: Bool { FileManager.default.fileExists(atPath: micURL.path) }
    var hasSystemAudioTrack: Bool { FileManager.default.fileExists(atPath: systemAudioURL.path) }
    var hasScreenRecording: Bool { FileManager.default.fileExists(atPath: screenURL.path) }

    /// Creates the package directory (and parents) if needed.
    @discardableResult
    static func create(at url: URL) throws -> RecordingBundle {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RecordingBundle(url: url)
    }

    /// Validates that an existing directory looks like a project.
    static func open(_ url: URL) throws -> RecordingBundle {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RecordingBundleError.notADirectory(url)
        }
        let bundle = RecordingBundle(url: url)
        guard bundle.hasScreenRecording else { throw RecordingBundleError.missingScreenRecording(url) }
        return bundle
    }

    func readEvents() throws -> EventsDocument {
        try EventsDocument.decode(Data(contentsOf: eventsURL))
    }

    /// Missing or unreadable `edit.json` yields the default document — a missing key is never an error.
    func readEdit() -> EditDocument {
        guard let data = try? Data(contentsOf: editURL), let doc = try? EditDocument.decode(data) else {
            return .default
        }
        return doc
    }

    func write(events: EventsDocument) throws {
        try events.encodedData().write(to: eventsURL, options: .atomic)
    }

    func write(edit: EditDocument) throws {
        try edit.encodedData().write(to: editURL, options: .atomic)
    }
}

/// Where new recordings are stored by default.
enum ProjectLibrary {
    static var defaultDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Ketto", isDirectory: true)
    }

    static func newBundleURL(date: Date = Date(), in directory: URL = defaultDirectory) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Recording \(formatter.string(from: date))"
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(RecordingBundle.pathExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(RecordingBundle.pathExtension)
            counter += 1
        }
        return candidate
    }

    static func recentProjects(in directory: URL = defaultDirectory, limit: Int = 20) -> [RecordingBundle] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let bundles = items.filter { $0.pathExtension == RecordingBundle.pathExtension }
        let dated = bundles.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map { RecordingBundle(url: $0.0) }
    }
}
