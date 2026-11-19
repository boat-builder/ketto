import SwiftUI
import AppKit

/// Settings › Sharing: connect a Cloudflare backend (or reuse one set up on another Mac). The videos on it are
/// listed under Shared Links.
struct SharingSettingsPage: View {
    let model: AppModel

    var body: some View {
        SettingsPage(title: "Sharing", subtitle: "Share links run on your own Cloudflare account, on a domain you own. Each link lasts about three days.") {
            if let share = model.share {
                SharingSettingsView(share: share, showSharedLinks: { model.page = .sharedLinks })
                    .frame(maxWidth: 620, alignment: .leading)
            } else {
                Text("Sharing is not available in this build.")
                    .font(.system(size: 13))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
        }
    }
}

/// Connected: what the backend is and the three things to do with it. Not connected: the three setup steps
/// (pick the domain, hand the prompt to a coding agent, wait for the Worker to answer), and a way to reuse a
/// backend from another Mac.
struct SharingSettingsView: View {
    @Bindable var share: ShareBackend
    var showSharedLinks: () -> Void = {}

    @State private var manualAddress = ""
    @State private var manualToken = ""
    @State private var manualError: String?
    @State private var isConnectingManually = false
    @State private var isShowingManualConnect = false
    /// Shows "Copied" on the Copy Prompt button for a moment; the clipboard gives no feedback of its own.
    @State private var promptCopied = false
    @State private var promptCopiedReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let connection = share.connection {
                connectedCard(connection)
            } else {
                setupSteps
                existingBackend
            }
        }
        .onAppear {
            share.resumeWatchingIfNeeded()
            if share.isConnected {
                Task { await share.refreshVideos() }
            }
        }
    }

    // MARK: - Connected

    private func connectedCard(_ connection: ShareBackendConnection) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                DoneBadge()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected to \(connection.displayName)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KettoTheme.ink)
                    Text("Share Link is ready in the editor and the export sheet.")
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            Hairline()
            SettingsRow("Shared right now", detail: share.videos.count == 1 ? "1 video" : "\(share.videos.count) videos") {
                Button("Show Shared Links") { showSharedLinks() }
                    .buttonStyle(PillButtonStyle(height: 28))
            }
            Hairline()
            SettingsRow("Share from another Mac", detail: "Paste this address and the token into its Sharing settings.") {
                Button("Copy Token") { share.copyTokenToPasteboard() }
                    .buttonStyle(PillButtonStyle(height: 28))
            }
            Hairline()
            SettingsRow("Disconnect", detail: "Forgets the token on this Mac. The Worker, the bucket and the videos stay on Cloudflare; videos are still deleted about three days after sharing.") {
                Button("Disconnect", role: .destructive) { share.disconnect() }
                    .buttonStyle(PillButtonStyle(height: 28))
            }
        }
        .card(cornerRadius: 12)
    }

    // MARK: - Setup

    private enum StepState { case done, current, upcoming }

    private var isWaiting: Bool { share.setupPhase == .waiting }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupStep(number: 1, state: isWaiting ? .done : .current, title: "Choose the domain for your links") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A domain that is already on your Cloudflare account")
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                    TextField("Domain for links", text: $share.setupDomain, prompt: Text("share.example.com"))
                        .textFieldStyle(.plain)
                        .fieldBox()
                        .frame(maxWidth: 320)
                        .disabled(isWaiting)
                        .onSubmit {
                            if !isWaiting { startSetup() }
                        }
                }
            }
            SetupStep(number: 2, state: isWaiting ? .done : .upcoming, title: "Hand the setup to your coding agent") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Copy Prompt writes the Worker and its configuration to a folder and copies a prompt. Paste it into Claude Code, Codex or Cursor on this Mac; the agent creates a private bucket and a small Worker with wrangler. Only you can log wrangler in (wrangler login).")
                        .font(.system(size: 13))
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if isWaiting, let bundle = share.setupBundle {
                        promptBox(bundle)
                    } else {
                        HStack(spacing: 10) {
                            Button("Copy Prompt") { startSetup() }
                                .buttonStyle(ProminentPillButtonStyle())
                                .disabled(share.setupDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                                .help("Writes the setup files for this domain and copies the prompt for your agent")
                            if case .failed(let message) = share.setupPhase {
                                Text(message)
                                    .font(.system(size: 12))
                                    .foregroundStyle(KettoTheme.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            SetupStep(number: 3, state: isWaiting ? .current : .upcoming, title: "Ketto connects by itself", isLast: true) {
                if isWaiting {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for \(share.setupBundle?.domain ?? share.setupDomain) to answer")
                                .font(.system(size: 13))
                                .foregroundStyle(KettoTheme.secondaryInk)
                            Spacer(minLength: 8)
                            Button("Check Now") { share.checkSetupNow() }
                                .buttonStyle(PillButtonStyle(height: 28))
                            Button("Cancel Setup") { share.cancelSetup() }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(KettoTheme.secondaryInk)
                                .padding(.horizontal, 6)
                        }
                        if let status = share.setupStatus {
                            Text(status)
                                .font(.system(size: 12))
                                .foregroundStyle(KettoTheme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("Once the Worker answers on your domain, Ketto connects and Share Link is ready.")
                        .font(.system(size: 13))
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func promptBox(_ bundle: ShareSetupBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    Text(bundle.prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 132)
                Button {
                    copyPrompt()
                } label: {
                    HStack(spacing: 6) {
                        if promptCopied {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(promptCopied ? "Copied" : "Copy Prompt")
                    }
                }
                .buttonStyle(ProminentPillButtonStyle(height: 28))
            }
            .padding(.vertical, 12)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .background(KettoTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Prefer Terminal? Run setup.sh in \(displayPath(bundle.directory)) instead.")
                .font(.system(size: 12))
                .foregroundStyle(KettoTheme.secondaryInk)
                .textSelection(.enabled)
        }
    }

    /// Writes the setup folder and copies the prompt in one go, as the button promises.
    private func startSetup() {
        share.startSetup()
        if share.setupPhase == .waiting { showCopied() }
    }

    private func copyPrompt() {
        share.copySetupPrompt()
        showCopied()
    }

    private func showCopied() {
        promptCopied = true
        promptCopiedReset?.cancel()
        promptCopiedReset = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { promptCopied = false }
        }
    }

    // MARK: - Existing backend

    private var existingBackend: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Already set up on another Mac?")
                        .font(.system(size: 13))
                        .foregroundStyle(KettoTheme.ink)
                    Text("Paste its address and the token from that Mac’s Settings › Sharing › Copy Token.")
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !isShowingManualConnect {
                    Button("Connect…") { isShowingManualConnect = true }
                        .buttonStyle(PillButtonStyle(height: 28))
                }
            }
            if isShowingManualConnect {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Address", text: $manualAddress, prompt: Text("share.example.com"))
                        .textFieldStyle(.plain)
                        .fieldBox()
                    SecureField("Token", text: $manualToken, prompt: Text("Token"))
                        .textFieldStyle(.plain)
                        .fieldBox()
                    HStack(spacing: 10) {
                        if let manualError {
                            Text(manualError)
                                .font(.system(size: 12))
                                .foregroundStyle(KettoTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if isConnectingManually {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Cancel") {
                            isShowingManualConnect = false
                            manualError = nil
                        }
                        .buttonStyle(PillButtonStyle(height: 28))
                        Button("Connect") { connectManually() }
                            .buttonStyle(ProminentPillButtonStyle(height: 28))
                            .disabled(manualAddress.isEmpty || manualToken.isEmpty || isConnectingManually)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Hairline() }
        .padding(.top, 32)
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
                isShowingManualConnect = false
            } catch {
                manualError = error.localizedDescription
            }
        }
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = url.path
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Step

    private struct SetupStep<Content: View>: View {
        let number: Int
        let state: StepState
        let title: String
        var isLast = false
        @ViewBuilder var content: Content

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 6) {
                    marker
                    if !isLast {
                        Rectangle()
                            .fill(state == .done ? KettoTheme.accentLine : KettoTheme.hairline)
                            .frame(width: KettoTheme.line)
                            .frame(maxHeight: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state == .upcoming ? KettoTheme.secondaryInk : KettoTheme.ink)
                    content
                }
                .padding(.top, 3)
                .padding(.bottom, isLast ? 0 : 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        @ViewBuilder
        private var marker: some View {
            switch state {
            case .done:
                DoneBadge()
            case .current, .upcoming:
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state == .current ? KettoTheme.accentInk : KettoTheme.secondaryInk)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(state == .current ? KettoTheme.accent : KettoTheme.outline, lineWidth: KettoTheme.line))
            }
        }
    }
}

extension View {
    /// A plain text field in a white box with a 1pt outline.
    func fieldBox() -> some View {
        font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(KettoTheme.canvas, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(KettoTheme.outline, lineWidth: KettoTheme.line))
    }
}
