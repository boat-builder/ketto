import SwiftUI
import AppKit

/// Shared Links: the videos currently on the user's backend, with the three things to do with each.
struct SharedLinksView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Shared Links", subtitle: subtitle, inline: true) {
                    if let share = model.share, share.isConnected {
                        if share.isLoadingVideos {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            Task { await share.refreshVideos() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(KettoTheme.ink)
                                .frame(width: 32, height: 32)
                                .overlay(Circle().strokeBorder(KettoTheme.outline, lineWidth: KettoTheme.line))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 16)
                        .help("Refresh")
                        .accessibilityLabel("Refresh")
                    }
                }
                if let share = model.share, share.isConnected {
                    SharedVideosList(share: share)
                        .frame(maxWidth: 920)
                    Text("Videos live in a private bucket on your own Cloudflare account and are deleted about three days after sharing. Removing one stops its link immediately.")
                        .font(.system(size: 13))
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .lineSpacing(3)
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    setupPrompt
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 28)
        }
        .background(KettoTheme.canvas)
        .onAppear {
            if let share = model.share, share.isConnected {
                Task { await share.refreshVideos() }
            }
        }
    }

    private var subtitle: String? {
        guard let share = model.share, let connection = share.connection else { return nil }
        switch share.videos.count {
        case 0: return "on \(connection.displayName)"
        case 1: return "1 video on \(connection.displayName)"
        default: return "\(share.videos.count) videos on \(connection.displayName)"
        }
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(KettoTheme.accentInk)
                Text("Share links aren’t set up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(KettoTheme.ink)
            }
            Text("Ketto shares videos through your own Cloudflare account: a private bucket that deletes videos after about three days, and a small Worker that serves the links on a domain you own. Ketto writes the setup files and gives you a prompt for your coding agent, which does the rest with wrangler.")
                .font(.system(size: 13))
                .foregroundStyle(KettoTheme.secondaryInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set Up Sharing…") { model.showSettings(.sharing) }
                .buttonStyle(ProminentPillButtonStyle())
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .card(cornerRadius: 14)
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
                    .font(.system(size: 13))
                    .foregroundStyle(KettoTheme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            ForEach(Array(share.videos.enumerated()), id: \.element.id) { index, video in
                if index > 0 {
                    Hairline()
                }
                SharedVideoRow(video: video) { pendingDeletion = video }
            }
            if let error = share.videosError {
                Hairline()
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .card(cornerRadius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

/// One shared video: a thumbnail, the title and link, how long the link has left, and the three things to do
/// with it.
private struct SharedVideoRow: View {
    let video: SharedVideo
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ProjectPlaceholder(seed: video.title)
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KettoTheme.ink)
                    .lineLimit(1)
                Text(linkText)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(KettoTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(details)
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.secondaryInk)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(timeLeft)
                    .font(.system(size: 12, weight: expiresSoon ? .semibold : .regular))
                    .foregroundStyle(KettoTheme.ink)
                    .lineLimit(1)
                ThinProgressBar(fraction: remainingFraction)
            }
            .frame(width: 96)
            .help("Expires \(video.expires.formatted(date: .abbreviated, time: .shortened))")
            HStack(spacing: 4) {
                Button("Copy Link") { ShareBackend.copyLink(video.url) }
                    .buttonStyle(PillButtonStyle())
                Button {
                    NSWorkspace.shared.open(video.url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
                .buttonStyle(IconButtonStyle(size: 30, cornerRadius: 15))
                .hoverHighlight(cornerRadius: 15)
                .help("Open in the browser")
                .accessibilityLabel("Open in the browser")
                Button(action: delete) {
                    Image(systemName: "trash")
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
                .buttonStyle(IconButtonStyle(size: 30, cornerRadius: 15))
                .hoverHighlight(cornerRadius: 15)
                .help("Remove the video; the link stops working immediately")
                .accessibilityLabel("Remove; the link stops working immediately")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var linkText: String {
        let text = video.url.absoluteString
        if let range = text.range(of: "://") { return String(text[range.upperBound...]) }
        return text
    }

    private var expiresSoon: Bool {
        video.expires.timeIntervalSinceNow < 24 * 3600
    }

    private var remainingFraction: Double {
        let total = video.expires.timeIntervalSince(video.uploaded)
        guard total > 0 else { return 0 }
        return max(0, min(1, video.expires.timeIntervalSinceNow / total))
    }

    private var timeLeft: String {
        let remaining = video.expires.timeIntervalSinceNow
        guard remaining > 0 else { return "Expiring now" }
        let days = Int(remaining / 86_400)
        if days >= 1 { return days == 1 ? "1 day left" : "\(days) days left" }
        let hours = Int(remaining / 3600)
        if hours >= 1 { return hours == 1 ? "1 hour left" : "\(hours) hours left" }
        return "Under an hour left"
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: video.size, countStyle: .file)
        let shared = video.uploaded.formatted(.relative(presentation: .named))
        return "Shared \(shared) · \(size)"
    }
}
