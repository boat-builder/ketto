import SwiftUI
import AppKit
import AVFoundation
import ImageIO

/// The library: every project in the storage folder as a card, newest first, grouped by day.
struct LibraryView: View {
    @Bindable var model: AppModel

    @State private var query = ""
    @State private var infos: [URL: ProjectInfo] = [:]
    @State private var pendingTrash: RecordingBundle?

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16, alignment: .top)]

    private var projects: [RecordingBundle] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.recentProjects }
        return model.recentProjects.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Library", subtitle: subtitle) {
                    SearchField(text: $query)
                    Button {
                        model.presentOpenPanel()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .hoverHighlight()
                    .help("Open a project that is not in the library (⌘O)")
                    Button {
                        model.showCaptureBar()
                    } label: {
                        Label("New Recording", systemImage: "record.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(RecordButtonStyle(height: 30))
                    .help("Show the capture bar (⌥⌘K)")
                }
                if projects.isEmpty {
                    emptyState
                } else {
                    ForEach(ProjectGroup.group(projects)) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                ForEach(group.projects, id: \.url) { bundle in
                                    ProjectCard(bundle: bundle, info: infos[bundle.url]) {
                                        model.openProject(bundle: bundle)
                                    } reveal: {
                                        NSWorkspace.shared.activateFileViewerSelecting([bundle.url])
                                    } trash: {
                                        pendingTrash = bundle
                                    }
                                    .task(id: bundle.url) {
                                        guard infos[bundle.url] == nil else { return }
                                        let info = await ProjectInfoLoader.load(bundle)
                                        infos[bundle.url] = info
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
        .onAppear { model.refreshLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLibrary()
        }
        .onChange(of: model.libraryRevision) { _, _ in
            // A project that was re-recorded or moved gets its card refreshed.
            infos = infos.filter { entry in model.recentProjects.contains { $0.url == entry.key } }
        }
        .confirmationDialog(
            "Move this recording to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { bundle in
            Button("Move to Trash", role: .destructive) {
                model.trashProject(bundle)
            }
        } message: { bundle in
            Text("“\(bundle.name)” and its edits go to the Trash. Exports and shared links are not affected.")
        }
    }

    private var subtitle: String {
        let count = model.recentProjects.count
        let folder = model.settings.storageDirectory.lastPathComponent
        switch count {
        case 0: return "Recordings are saved to \(folder)."
        case 1: return "1 recording in \(folder)"
        default: return "\(count) recordings in \(folder)"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? "film.stack" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No recordings yet" : "Nothing matches “\(query)”")
                .font(.headline)
            if query.isEmpty {
                Text("Press Record on the capture bar, or ⇧⌘R from any app. Projects land here when you stop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - Grouping

/// Today, Yesterday, Earlier this week, Earlier.
private struct ProjectGroup: Identifiable {
    let title: String
    let projects: [RecordingBundle]
    var id: String { title }

    static func group(_ projects: [RecordingBundle], now: Date = Date()) -> [ProjectGroup] {
        let calendar = Calendar.current
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        var today: [RecordingBundle] = []
        var yesterday: [RecordingBundle] = []
        var week: [RecordingBundle] = []
        var earlier: [RecordingBundle] = []
        for bundle in projects {
            let date = ProjectInfoLoader.modificationDate(of: bundle) ?? .distantPast
            if calendar.isDateInToday(date) {
                today.append(bundle)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(bundle)
            } else if date > weekAgo {
                week.append(bundle)
            } else {
                earlier.append(bundle)
            }
        }
        return [
            ProjectGroup(title: "Today", projects: today),
            ProjectGroup(title: "Yesterday", projects: yesterday),
            ProjectGroup(title: "Earlier this week", projects: week),
            ProjectGroup(title: "Earlier", projects: earlier),
        ].filter { !$0.projects.isEmpty }
    }
}

// MARK: - Cards

/// What a card shows beyond the name: the thumbnail and the length, read off the bundle in the background.
struct ProjectInfo: @unchecked Sendable {
    let thumbnail: CGImage?
    let duration: Double?
}

enum ProjectInfoLoader {
    static func load(_ bundle: RecordingBundle) async -> ProjectInfo {
        let thumbnailURL = bundle.thumbnailURL
        let screenURL = bundle.screenURL
        return await Task.detached(priority: .utility) {
            var thumbnail: CGImage?
            if let source = CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil) {
                thumbnail = CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            var duration: Double?
            if FileManager.default.fileExists(atPath: screenURL.path) {
                let asset = AVURLAsset(url: screenURL)
                if let time = try? await asset.load(.duration), time.isNumeric {
                    duration = time.seconds
                }
            }
            return ProjectInfo(thumbnail: thumbnail, duration: duration)
        }.value
    }

    static func modificationDate(of bundle: RecordingBundle) -> Date? {
        (try? bundle.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// A project: thumbnail with the length in the corner, the name, and when it was recorded.
struct ProjectCard: View {
    let bundle: RecordingBundle
    let info: ProjectInfo?
    let open: () -> Void
    let reveal: () -> Void
    let trash: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail
                    .frame(height: 124)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = info?.duration {
                            Text(shortTimecode(duration))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(6)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(bundle.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(ProjectInfoLoader.modificationDate(of: bundle).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
            .padding(8)
            .background(Color.primary.opacity(isHovering ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { reveal() }
            Divider()
            Button("Move to Trash…", role: .destructive) { trash() }
        }
        .help(bundle.url.path)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = info?.thumbnail {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Color.primary.opacity(0.06))
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A rounded search field for page headers.
struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 200, height: 30)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
