import SwiftUI

/// Root of the main window: the recorder in `setup`, the editor in `editing`, and a placeholder while recording
/// (the window is normally hidden then, so it never appears in the capture).
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .setup:
                RecorderSetupView(model: model)
            case .countdown, .recording, .finishing:
                RecordingPlaceholderView(model: model)
            case .editing(let session):
                EditorView(model: model, session: session)
                    .id(ObjectIdentifier(session))
            }
        }
        .alert("Ketto", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct RecordingPlaceholderView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .countdown(let remaining):
                Text("Recording starts in \(remaining)…")
                    .font(.title2)
                Button("Cancel") { model.cancelCountdown() }
            case .recording:
                Image(systemName: "record.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                Text("Recording…")
                    .font(.title2)
                Button("Stop Recording") { model.stopRecording() }
                    .buttonStyle(.borderedProminent)
            case .finishing:
                ProgressView()
                Text("Saving recording…")
                    .font(.title2)
            case .setup, .editing:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
