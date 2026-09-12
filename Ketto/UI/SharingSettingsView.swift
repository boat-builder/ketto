import SwiftUI
import AppKit

/// Settings › Sharing: connect a Cloudflare backend (or reuse one set up on another Mac). The videos on it are
/// listed under Shared Links.
struct SharingSettingsPage: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Sharing", subtitle: "Share Link uploads to a private bucket on your own Cloudflare account; links last about three days.")
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 6)
            if let share = model.share {
                SharingSettingsView(share: share, showSharedLinks: { model.page = .sharedLinks })
            } else {
                Form {
                    Text("Sharing is not available in this build.")
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            }
        }
    }
}

struct SharingSettingsView: View {
    @Bindable var share: ShareBackend
    var showSharedLinks: () -> Void = {}

    @State private var manualAddress = ""
    @State private var manualToken = ""
    @State private var manualError: String?
    @State private var isConnectingManually = false

    var body: some View {
        Form {
            if let connection = share.connection {
                backendSection(connection)
            } else {
                setupSection
                existingBackendSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            share.resumeWatchingIfNeeded()
            if share.isConnected {
                Task { await share.refreshVideos() }
            }
        }
    }

    // MARK: - Connected

    private func backendSection(_ connection: ShareBackendConnection) -> some View {
        Section {
            LabeledContent("Connected to") {
                HStack(spacing: 8) {
                    StatusDot(color: .green)
                    Text(connection.displayName)
                }
            }
            LabeledContent("Shared right now") {
                HStack(spacing: 8) {
                    Text(share.videos.count == 1 ? "1 video" : "\(share.videos.count) videos")
                        .foregroundStyle(.secondary)
                    Button("Show Shared Links") { showSharedLinks() }
                        .controlSize(.small)
                }
            }
            HStack {
                Button("Copy Token") { share.copyTokenToPasteboard() }
                    .help("To share from another Mac, paste this token and the address into its Settings › Sharing.")
                Spacer()
                Button("Disconnect", role: .destructive) { share.disconnect() }
            }
        } header: {
            Text("Backend")
        } footer: {
            Text("Shared videos are stored in your Cloudflare account and deleted about three days after sharing. Disconnecting forgets the token on this Mac; the Worker and the bucket stay as they are.")
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
