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

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 20, alignment: .top)]

    private var projects: [RecordingBundle] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.recentProjects }
        return model.recentProjects.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Library", subtitle: subtitle, inline: true) {
                    SearchField(text: $query)
                    Button {
                        model.presentOpenPanel()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(KettoTheme.ink)
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(KettoTheme.outline, lineWidth: KettoTheme.line))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 16)
                    .help("Open a project that is not in the library (⌘O)")
                    .accessibilityLabel("Open a project that isn’t in the library")
                    Button {
                        model.showCaptureBar()
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(KettoTheme.record)
                                .frame(width: 8, height: 8)
                            Text("New Recording")
                        }
                    }
                    .buttonStyle(RecordButtonStyle(height: 32))
                    .help("Show the capture bar (⌥⌘K)")
                }
                if projects.isEmpty {
                    emptyState
                } else {
                    ForEach(ProjectGroup.group(projects)) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(KettoTheme.secondaryInk)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
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
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 28)
        }
        .background(KettoTheme.canvas)
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
        case 0: return "Saved to \(folder)"
        case 1: return "1 recording in \(folder)"
        default: return "\(count) recordings in \(folder)"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if query.isEmpty {
                ProjectPlaceholder(seed: "")
                    .frame(width: 168, height: 94.5)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 8)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            Text(query.isEmpty ? "No recordings yet" : "Nothing matches “\(query)”")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(KettoTheme.ink)
            if query.isEmpty {
                Text("Press Record on the capture bar, or ⇧⌘R from any app. Projects land here when you stop.")
                    .font(.system(size: 13))
                    .foregroundStyle(KettoTheme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
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
            VStack(alignment: .leading, spacing: 10) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { thumbnail }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isHovering ? KettoTheme.accentLine : KettoTheme.ink.opacity(0.08), lineWidth: isHovering ? KettoTheme.line : 0.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(bundle.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KettoTheme.ink)
                        .lineLimit(1)
                    Text(meta)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
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

    /// "1:30 · 10:42" today and yesterday, "1:12 · Tuesday" this week, "0:36 · 3 Nov" before that.
    private var meta: String {
        var parts: [String] = []
        if let duration = info?.duration { parts.append(shortTimecode(duration)) }
        if let date = ProjectInfoLoader.modificationDate(of: bundle) {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
                parts.append(date.formatted(date: .omitted, time: .shortened))
            } else if date > Date().addingTimeInterval(-7 * 24 * 3600) {
                parts.append(date.formatted(.dateTime.weekday(.wide)))
            } else {
                parts.append(date.formatted(.dateTime.day().month(.abbreviated)))
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = info?.thumbnail {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ProjectPlaceholder(seed: bundle.name)
        }
    }
}

/// Stand-in art for a project without a thumbnail: one of the media gradients with a white window on it,
/// picked from the name so a card keeps its colour.
struct ProjectPlaceholder: View {
    let seed: String

    var body: some View {
        let gradients = [KettoTheme.sunrise, KettoTheme.cobalt, KettoTheme.violet, KettoTheme.limeWash, KettoTheme.midnight]
        let index = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % gradients.count
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(gradients[index])
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white)
                    .frame(width: proxy.size.width * 0.64, height: proxy.size.height * 0.62)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 6)
            }
        }
    }
}

/// A rounded search field for page headers.
struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(KettoTheme.secondaryInk)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: 32)
        .background(KettoTheme.surface, in: Capsule())
    }
}
