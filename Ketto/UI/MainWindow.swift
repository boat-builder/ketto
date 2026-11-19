import SwiftUI
import AppKit

/// The app window: the library, shared links and settings behind one sidebar while no project is open, and the
/// editor once one is. An AppKit window so that nothing opens at launch on its own; the capture bar is the
/// launch surface and the gear on it brings this up.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ketto"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 640)
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(rootView: MainWindowView(model: model))
        window.center()
        window.setFrameAutosaveName("KettoMainWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window while a project is open leaves the editor: the project is saved and the library is what
    /// comes back next time.
    func windowWillClose(_ notification: Notification) {
        model.closeProject()
    }
}

/// Root of the app window.
struct MainWindowView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .editing(let session):
                EditorView(model: model, session: session)
                    .id(ObjectIdentifier(session))
            case .countdown, .recording, .finishing:
                RecordingPlaceholderView(model: model)
            case .idle:
                AppShellView(model: model)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 640)
        .alert("Ketto", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Sidebar plus the selected page.
struct AppShellView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 220)
            Hairline(axis: .vertical)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KettoTheme.canvas)
        }
        .foregroundStyle(KettoTheme.ink)
        .tint(KettoTheme.accent)
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .library:
            LibraryView(model: model)
        case .sharedLinks:
            SharedLinksView(model: model)
        case .recording:
            RecordingSettingsView(model: model, settings: model.settings)
        case .sharing:
            SharingSettingsPage(model: model)
        case .updates:
            UpdatesSettingsView(model: model)
        }
    }
}

/// Library and Shared Links on top, Settings below, the version at the bottom.
private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights sit in this corner; the wordmark sits under them.
            Spacer().frame(height: 46)
            Wordmark()
                .padding(.horizontal, 10)
                .padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 2) {
                row(.library)
                row(.sharedLinks)
            }
            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KettoTheme.secondaryInk)
                .padding(.horizontal, 10)
                .padding(.top, 20)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 2) {
                row(.recording)
                row(.sharing)
                row(.updates)
            }
            Spacer()
            Text(versionText)
                .font(.system(size: 12))
                .foregroundStyle(KettoTheme.secondaryInk)
                .lineLimit(1)
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity)
        .background(KettoTheme.surface.ignoresSafeArea())
    }

    private func row(_ page: AppPage) -> some View {
        let isSelected = model.page == page
        return Button {
            model.page = page
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
                if page == .sharedLinks, let count = model.share?.videos.count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(KettoTheme.secondaryInk)
                }
            }
            .foregroundStyle(isSelected ? KettoTheme.accentInk : KettoTheme.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isSelected ? KettoTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 8)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var versionText: String {
        guard let updates = model.updates else { return "Ketto" }
        var text = "Ketto \(updates.currentVersion)"
        switch updates.phase {
        case .upToDate: text += " · Up to date"
        case .available(let version): text += " · \(version) available"
        case .idle, .checking, .failed: break
        }
        return text
    }
}

/// What the app window shows while a capture runs. It is hidden then, so this is only ever seen if the user
/// brings the window back by hand.
struct RecordingPlaceholderView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .countdown(let remaining):
                Text("Recording starts in \(remaining)…")
                    .font(.system(size: 20, weight: .semibold))
                Button("Cancel") { model.cancelCountdown() }
                    .buttonStyle(PillButtonStyle())
            case .recording:
                Circle()
                    .fill(KettoTheme.record)
                    .frame(width: 12, height: 12)
                Text("Recording…")
                    .font(.system(size: 20, weight: .semibold))
                Button {
                    model.stopRecording()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                        Text("Stop Recording")
                    }
                }
                .buttonStyle(RecordButtonStyle())
            case .finishing:
                ProgressView()
                Text("Saving recording…")
                    .font(.system(size: 20, weight: .semibold))
            case .idle, .editing:
                EmptyView()
            }
        }
        .foregroundStyle(KettoTheme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KettoTheme.surface)
    }
}
