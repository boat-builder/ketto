import Foundation
@preconcurrency import AVFoundation
import CoreMedia

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool

    static func available() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return session.devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID) }
    }
}

/// Captures the microphone through AVFoundation as a separate track (`mic.caf`), timestamped on the host clock
/// so it aligns with the screen recording without ever being mixed with system audio.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let writer: AlignedAudioWriter
    private let queue = DispatchQueue(label: "cc.ketto.capture.microphone", qos: .userInitiated)

    init(deviceID: String?, writer: AlignedAudioWriter) throws {
        self.writer = writer
        super.init()
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .audio)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw CaptureError.writerSetupFailed("No microphone is available") }
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.writerSetupFailed("Cannot use the selected microphone") }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.writerSetupFailed("Cannot add microphone output") }
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() {
        queue.async { [session] in
            session.startRunning()
        }
    }

    /// Stops the capture session and closes the file.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [session, writer] in
                session.stopRunning()
                writer.finish()
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writer.append(sampleBuffer)
    }
}
