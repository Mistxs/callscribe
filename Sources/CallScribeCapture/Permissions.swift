import AVFoundation
import AppKit
import CoreGraphics
import Foundation

public enum Permissions {
    public static var screenGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreen() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    public static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    public static func openScreenSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    public static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
