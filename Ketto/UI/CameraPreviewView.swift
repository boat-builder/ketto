import SwiftUI
import AppKit
@preconcurrency import AVFoundation

/// Shows what a capture session's camera sees, mirrored like a mirror. The recording itself is not mirrored
/// on disk; `edit.camera.mirrored` decides how the video shows it, and a new recording starts out mirrored so
/// the video matches what the bubble showed.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    /// Bump whenever the session's input changed, so the mirroring is re-applied to the new connection.
    var revision: Int = 0
    /// Clip the picture to a circle (the layer does it, so it holds whatever SwiftUI does around it).
    var circular: Bool = false

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session, circular: circular)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.circular = circular
        nsView.attach(session)
    }
}

/// A layer-hosting view around an `AVCaptureVideoPreviewLayer`.
final class CameraPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    var circular: Bool {
        didSet { needsLayout = true }
    }

    init(session: AVCaptureSession, circular: Bool = false) {
        self.circular = circular
        super.init(frame: .zero)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.masksToBounds = true
        layer = previewLayer
        wantsLayer = true
        attach(session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attach(_ session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        previewLayer.cornerRadius = circular ? min(bounds.width, bounds.height) / 2 : 0
    }

    /// Dragging the picture drags the window it sits in (the floating camera bubble).
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The camera before a recording starts: a capture session with just the chosen device as input, for the
/// floating bubble's preview. The recording's own `CameraCapture` takes the device over from it, so this
/// session is stopped (`stop()`) before a recording begins and started again afterwards. Like
/// `MicrophoneCapture`, the blocking `startRunning()` / `stopRunning()` calls run on a private queue; the
/// configuration is only ever changed from the main thread.
final class CameraPreviewSource: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cc.ketto.camera.preview", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?
    private var wantsRunning = false

    /// Shows `deviceID` (the default camera when nil), reconfiguring a running session for a different device.
    /// Returns false when no camera can be used.
    @MainActor
    @discardableResult
    func start(deviceID: String?) -> Bool {
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .video)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let device else { return false }
        if let input, input.device.uniqueID == device.uniqueID, wantsRunning { return true }
        session.beginConfiguration()
        if let input {
            session.removeInput(input)
            self.input = nil
        }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
        if let newInput = try? AVCaptureDeviceInput(device: device), session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
        }
        session.commitConfiguration()
        guard input != nil else { return false }
        wantsRunning = true
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        return true
    }

    /// Stops the session and returns once the camera has been released.
    @MainActor
    func stop() async {
        wantsRunning = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }
}
