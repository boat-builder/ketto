import SwiftUI
import AppKit

/// Settings › Updates: the installed version, one-click update through Sparkle, and the automatic-update
/// switches. Says so plainly when this build has no update feed (see `UpdateController.isConfigured`).
struct UpdatesSettingsView: View {
    let model: AppModel

    var body: some View {
        SettingsPage(title: "Updates", subtitle: "Ketto \(model.updates?.currentVersion ?? "")") {
            VStack(alignment: .leading, spacing: 24) {
                if let updates = model.updates, updates.isConfigured {
                    SettingsSection("Version", footer: "Updates are downloaded from GitHub and verified against the key in this build before they are installed. Nothing is ever shown during a recording.") {
                        SettingsRow("Installed version") {
                            Text(updates.currentVersion)
                                .font(.system(size: 13))
                                .monospacedDigit()
                                .foregroundStyle(KettoTheme.secondaryInk)
                        }
                        Hairline()
                        SettingsRow("Status") {
                            HStack(spacing: 10) {
                                status(updates)
                                if case .available = updates.phase {
                                    Button(buttonTitle(updates)) { updates.checkForUpdates() }
                                        .buttonStyle(ProminentPillButtonStyle(height: 28))
                                        .disabled(!updates.canCheck || updates.isDeferred)
                                } else {
                                    Button(buttonTitle(updates)) { updates.checkForUpdates() }
                                        .buttonStyle(PillButtonStyle(height: 28))
                                        .disabled(!updates.canCheck || updates.isDeferred)
                                }
                            }
                        }
                    }
                    SettingsSection("Automatic updates") {
                        SettingsRow("Check for updates automatically") {
                            SettingsSwitch(isOn: Binding(
                                get: { updates.automaticallyChecksForUpdates },
                                set: { updates.automaticallyChecksForUpdates = $0 }
                            ), label: "Check for updates automatically")
                        }
                        Hairline()
                        SettingsRow("Download and install updates in the background") {
                            SettingsSwitch(isOn: Binding(
                                get: { updates.automaticallyDownloadsUpdates },
                                set: { updates.automaticallyDownloadsUpdates = $0 }
                            ), label: "Download and install updates in the background")
                            .disabled(!updates.automaticallyChecksForUpdates)
                        }
                    }
                } else {
                    SettingsSection("Version") {
                        SettingsRow(
                            "Installed version",
                            detail: "This build has no update feed configured, so it never checks for updates. Builds from the releases page update themselves."
                        ) {
                            Text(model.updates?.currentVersion ?? "")
                                .font(.system(size: 13))
                                .monospacedDigit()
                                .foregroundStyle(KettoTheme.secondaryInk)
                        }
                    }
                }
                Link(destination: URL(string: "https://github.com/boat-builder/ketto/releases")!) {
                    HStack(spacing: 4) {
                        Text("Release notes on GitHub")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(KettoTheme.accentInk)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    @ViewBuilder
    private func status(_ updates: UpdateController) -> some View {
        Group {
            switch updates.phase {
            case .idle:
                Text("Not checked yet")
                    .foregroundStyle(KettoTheme.secondaryInk)
            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
            case .upToDate:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                    Text("Up to date")
                }
                .foregroundStyle(KettoTheme.secondaryInk)
            case .available(let version):
                Text("Version \(version) is available")
                    .foregroundStyle(KettoTheme.accentInk)
            case .failed(let message):
                Text("Couldn’t check: \(message)")
                    .foregroundStyle(KettoTheme.danger)
                    .lineLimit(2)
            }
        }
        .font(.system(size: 13))
    }

    private func buttonTitle(_ updates: UpdateController) -> String {
        if case .available(let version) = updates.phase { return "Update to \(version)…" }
        return "Check Now"
    }
}
