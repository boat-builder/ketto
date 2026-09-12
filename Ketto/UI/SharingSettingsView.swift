import SwiftUI
import AppKit

/// Settings › Sharing. Connect a Cloudflare backend (or reuse one set up on another Mac), then manage the videos
/// that are currently shared on it.
struct SharingSettingsView: View {
    @Bindable var share: ShareBackend

    @State private var manualAddress = ""
    @State private var manualToken = ""
    @State private var manualError: String?
    @State private var isConnectingManually = false
    @State private var pendingDeletion: SharedVideo?

    var body: some View {
        Form {
            if let connection = share.connection {
                backendSection(connection)
                videosSection
            } else {
                setupSection
                existingBackendSection
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 480)
        .navigationTitle("Sharing")
        .onAppear {
            share.resumeWatchingIfNeeded()
            if share.isConnected {
                Task { await share.refreshVideos() }
            }
        }
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

    // MARK: - Connected

    private func backendSection(_ connection: ShareBackendConnection) -> some View {
        Section("Backend") {
            LabeledContent("Connected to", value: connection.displayName)
            Text("Shared videos are stored in your Cloudflare account and deleted about three days after sharing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Token") { share.copyTokenToPasteboard() }
                    .help("To share from another Mac, paste this token and the address into its Settings › Sharing.")
                Spacer()
                Button("Disconnect", role: .destructive) { share.disconnect() }
            }
        }
    }

    private var videosSection: some View {
        Section {
            if share.videos.isEmpty {
                Text(share.isLoadingVideos ? "Loading…" : "Nothing is shared right now.")
                    .foregroundStyle(.secondary)
            }
            ForEach(share.videos) { video in
                SharedVideoRow(video: video) { pendingDeletion = video }
            }
        } header: {
            HStack {
                Text("Shared Videos")
                Spacer()
                if share.isLoadingVideos {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Refresh") {
                    Task { await share.refreshVideos() }
                }
                .controlSize(.small)
            }
        } footer: {
            if let error = share.videosError {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section("Set Up Sharing") {
            Text("Ketto shares videos through your own Cloudflare account: a private bucket that deletes videos after about three days, and a small Worker that serves the links on a domain you own. Ketto writes the setup files; you run one command in Terminal.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Before you start")
                    .font(.subheadline.weight(.semibold))
                Label("wrangler is installed and logged in to your Cloudflare account (wrangler login).", systemImage: "1.circle")
                Label("That account already has the domain you want the links on.", systemImage: "2.circle")
            }
            .font(.callout)
            TextField("Domain for links", text: $share.setupDomain, prompt: Text("share.example.com"))
                .disabled(share.setupPhase == .waiting)
                .onSubmit {
                    if share.setupPhase != .waiting { share.generateSetup() }
                }
            switch share.setupPhase {
            case .idle, .failed, .connected:
                HStack {
                    if case .failed(let message) = share.setupPhase {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Generate Setup Command") { share.generateSetup() }
                        .disabled(share.setupDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .waiting:
                waitingControls
            }
        }
    }

    private var waitingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run this in Terminal:")
                .font(.callout)
            Text(share.setupBundle?.command ?? "")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for https://\(share.setupBundle?.domain ?? "") to answer…")
                    .font(.callout)
            }
            if let status = share.setupStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Copy Command") { share.copySetupCommand() }
                    .buttonStyle(.borderedProminent)
                Button("Check Now") { share.checkSetupNow() }
                Spacer()
                Button("Cancel Setup") { share.cancelSetup() }
            }
        }
    }

    private var existingBackendSection: some View {
        Section("Connect to an Existing Backend") {
            Text("Already set up on another Mac? Enter its address and the token from that Mac’s Settings › Sharing › Copy Token.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Address", text: $manualAddress, prompt: Text("share.example.com"))
            SecureField("Token", text: $manualToken)
            HStack {
                if let manualError {
                    Text(manualError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                if isConnectingManually {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Connect") { connectManually() }
                    .disabled(manualAddress.isEmpty || manualToken.isEmpty || isConnectingManually)
            }
        }
    }

    private func connectManually() {
        isConnectingManually = true
        manualError = nil
        Task {
            defer { isConnectingManually = false }
            do {
                try await share.connect(urlText: manualAddress, token: manualToken)
                manualAddress = ""
                manualToken = ""
            } catch {
                manualError = error.localizedDescription
            }
        }
    }
}

/// One shared video: title, when it was shared, how long the link has left, and the three things to do with it.
private struct SharedVideoRow: View {
    let video: SharedVideo
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Copy Link") { ShareBackend.copyLink(video.url) }
            Button {
                NSWorkspace.shared.open(video.url)
            } label: {
                Image(systemName: "safari")
            }
            .help("Open in the browser")
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .help("Remove the video; the link stops working immediately")
        }
        .controlSize(.small)
        .padding(.vertical, 2)
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
