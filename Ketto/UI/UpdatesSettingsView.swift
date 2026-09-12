import SwiftUI
import AppKit

/// Settings › Updates: the installed version, one-click update through Sparkle, and the automatic-update
/// switches. Says so plainly when this build has no update feed (see `UpdateController.isConfigured`).
struct UpdatesSettingsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Updates", subtitle: "Ketto \(model.updates?.currentVersion ?? "")")
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 6)
            Form {
                if let updates = model.updates, updates.isConfigured {
                    Section {
                        LabeledContent("Installed version", value: updates.currentVersion)
                        LabeledContent("Status") {
                            status(updates)
                        }
                        HStack {
                            Spacer()
                            Button(buttonTitle(updates)) { updates.checkForUpdates() }
                                .disabled(!updates.canCheck || updates.isDeferred)
                        }
                    } footer: {
                        Text("Updates are downloaded from GitHub and verified against the key in this build before they are installed. Nothing is ever shown during a recording.")
                    }
                    Section("Automatic Updates") {
                        Toggle("Check for updates automatically", isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates },
                            set: { updates.automaticallyChecksForUpdates = $0 }
                        ))
                        Toggle("Download and install updates in the background", isOn: Binding(
                            get: { updates.automaticallyDownloadsUpdates },
                            set: { updates.automaticallyDownloadsUpdates = $0 }
                        ))
                        .disabled(!updates.automaticallyChecksForUpdates)
                    }
                } else {
                    Section {
                        LabeledContent("Installed version", value: model.updates?.currentVersion ?? "")
                        Text("This build has no update feed configured, so it never checks for updates. Builds from the releases page update themselves.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Link("Release notes on GitHub", destination: URL(string: "https://github.com/boat-builder/ketto/releases")!)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func status(_ updates: UpdateController) -> some View {
        switch updates.phase {
        case .idle:
            Text("Not checked yet")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available(let version):
            Label("Version \(version) is available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .failed(let message):
            Text("Couldn’t check: \(message)")
                .foregroundStyle(.orange)
        }
    }

    private func buttonTitle(_ updates: UpdateController) -> String {
        if case .available(let version) = updates.phase { return "Update to \(version)…" }
        return "Check for Updates…"
    }
}
