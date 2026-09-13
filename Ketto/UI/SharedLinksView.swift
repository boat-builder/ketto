import SwiftUI
import AppKit

/// Shared Links: the videos currently on the user's backend, with the three things to do with each.
struct SharedLinksView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Shared Links", subtitle: subtitle) {
                    if let share = model.share, share.isConnected {
                        if share.isLoadingVideos {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            Task { await share.refreshVideos() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(IconButtonStyle(size: 30))
                        .hoverHighlight()
                        .help("Refresh")
                    }
                }
                if let share = model.share, share.isConnected {
                    SharedVideosList(share: share)
                    howItWorks
                } else {
                    setupPrompt
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
        .onAppear {
            if let share = model.share, share.isConnected {
                Task { await share.refreshVideos() }
            }
        }
    }

    private var subtitle: String {
        if let connection = model.share?.connection {
            return "Videos on \(connection.displayName). Every link stops working after about three days."
        }
        return "Share Link uploads an MP4 to a bucket on your own Cloudflare account."
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Share links aren’t set up", systemImage: "link.badge.plus")
                .font(.headline)
            Text("Ketto shares videos through your own Cloudflare account: a private bucket that deletes videos after about three days, and a small Worker that serves the links on a domain you own. Ketto writes the setup files and gives you a prompt for your coding agent, which does the rest with wrangler.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set Up Sharing…") { model.showSettings(.sharing) }
                .buttonStyle(ProminentPillButtonStyle())
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How a link works")
                .font(.system(size: 13, weight: .semibold))
            Text("Share Link in the editor renders the edit as MP4 and uploads it to your bucket; the link is copied to the clipboard. Anyone with the link can watch the video in a browser. Remove a video here to stop its link early; otherwise it is deleted about three days after sharing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.top, 8)
    }
}

/// The list of shared videos on a connected backend. Also used by Settings › Sharing.
struct SharedVideosList: View {
    @Bindable var share: ShareBackend

    @State private var pendingDeletion: SharedVideo?

    var body: some View {
        VStack(spacing: 0) {
            if share.videos.isEmpty {
                Text(share.isLoadingVideos ? "Loading…" : "Nothing is shared right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            ForEach(Array(share.videos.enumerated()), id: \.element.id) { index, video in
                if index > 0 {
                    Divider().padding(.leading, 14)
                }
                SharedVideoRow(video: video) { pendingDeletion = video }
            }
            if let error = share.videosError {
                Divider().padding(.leading, 14)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .confirmationDialog(
            "Remove this shared video?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { video in
            Button("Remove", role: .destructive) {
                Task { await share.delete(video) }
            }
        } message: { video in
            Text("The link for “\(video.title)” stops working immediately.")
        }
    }
}

/// One shared video: title, when it was shared, how long the link has left, and the three things to do with it.
private struct SharedVideoRow: View {
    let video: SharedVideo
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 24)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(expiresSoon ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Copy Link") { ShareBackend.copyLink(video.url) }
                .buttonStyle(PillButtonStyle(height: 24))
            Button {
                NSWorkspace.shared.open(video.url)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .hoverHighlight()
            .help("Open in the browser")
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .hoverHighlight()
            .help("Remove the video; the link stops working immediately")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var expiresSoon: Bool {
        video.expires.timeIntervalSinceNow < 24 * 3600
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: video.size, countStyle: .file)
        let shared = video.uploaded.formatted(date: .abbreviated, time: .shortened)
        let expiry = video.expires > Date()
            ? "expires \(video.expires.formatted(.relative(presentation: .named)))"
            : "expiring now"
        return "\(shared) · \(size) · \(expiry)"
    }
}
