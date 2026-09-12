import Foundation
import AppKit
import AVFoundation
import CoreGraphics

/// Permissions are requested lazily, at the moment a feature is first used. Accessibility is never requested.
enum CapturePermissions {
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt (first time) or returns the current state. Subsequent denials require the
    /// user to enable Ketto in System Settings.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    @MainActor
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
