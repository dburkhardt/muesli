import Foundation
import AVFoundation
import ScreenCaptureKit

/// Manages app permissions for screen recording and microphone access
@MainActor
final class PermissionManager {
    
    // MARK: - Screen Recording Permission
    
    /// Check if screen recording permission is granted (sync, unreliable with ad-hoc signing)
    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }
    
    /// Check screen recording permission using SCShareableContent (async, reliable)
    /// This actually queries the TCC database correctly, unlike CGPreflightScreenCaptureAccess
    func checkScreenRecordingPermissionAsync() async -> Bool {
        do {
            // This call will fail with a specific TCC error if permission is not granted
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }
    
    /// Request screen recording permission
    /// Note: This will trigger the system permission dialog
    func requestScreenRecordingPermission() {
        // This will trigger the permission prompt
        _ = CGRequestScreenCaptureAccess()
    }
    
    /// Open System Settings to the Screen Recording pane
    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Microphone Permission
    
    /// Check if microphone permission is granted
    /// Always checks AVCaptureDevice authorization to ensure mic access is granted
    var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    /// Check if microphone permission has been denied
    var isMicrophonePermissionDenied: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }
    
    /// Request microphone permission
    /// - Returns: Whether permission was granted
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
    
    /// Open System Settings to the Microphone pane
    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Combined Checks
    
    /// Check if all required permissions are granted
    var hasAllPermissions: Bool {
        hasScreenRecordingPermission && hasMicrophonePermission
    }
    
    /// Refresh permission states (call after user returns from settings)
    func refreshPermissions() -> (screenRecording: Bool, microphone: Bool) {
        (hasScreenRecordingPermission, hasMicrophonePermission)
    }
}
