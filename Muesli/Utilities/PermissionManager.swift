import Foundation
import AVFoundation
import ScreenCaptureKit

/// Manages app permissions for screen recording and microphone access
/// Can be injected into views via @Environment for permission state observation
@Observable
@MainActor
final class PermissionManager: PermissionManagerProtocol {
    
    // MARK: - Observable State
    
    /// Cached screen recording permission state (updated via refresh)
    var screenRecordingGranted: Bool = false
    
    /// Cached microphone permission state (updated via refresh)
    var microphoneGranted: Bool = false
    
    // MARK: - Notification Observers
    
    /// Notification observers for automatic permission refresh
    private var observers: [NSObjectProtocol] = []
    
    // MARK: - Initialization
    
    init() {
        // Skip permission checks when running tests to avoid permission prompts
        guard !Self.isRunningTests else {
            // In test environment, assume no permissions granted
            screenRecordingGranted = false
            microphoneGranted = false
            return
        }
        
        // Check initial permissions
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        
        // Observe app becoming active (user returns from System Settings)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshPermissionsAsync()
                }
            }
        )
    }
    
    /// Detect if running in test environment
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }
    
    deinit {
        // Remove all observers (use MainActor.assumeIsolated since deinit is nonisolated)
        MainActor.assumeIsolated {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
    
    // MARK: - Screen Recording Permission
    
    /// Check if screen recording permission is granted (sync, unreliable with ad-hoc signing)
    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }
    
    /// Check screen recording permission using SCShareableContent (async, reliable)
    /// This actually queries the TCC database correctly, unlike CGPreflightScreenCaptureAccess
    func checkScreenRecordingPermissionAsync() async -> Bool {
        // Skip permission checks when running tests
        guard !Self.isRunningTests else {
            return false
        }
        
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
        // Skip permission requests when running tests
        guard !Self.isRunningTests else {
            return
        }
        
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
        // Skip permission requests when running tests
        guard !Self.isRunningTests else {
            return false
        }
        
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
    /// Updates the observable cached state
    func refreshPermissions() -> (screenRecording: Bool, microphone: Bool) {
        screenRecordingGranted = hasScreenRecordingPermission
        microphoneGranted = hasMicrophonePermission
        return (screenRecordingGranted, microphoneGranted)
    }
    
    /// Async refresh that uses reliable SCShareableContent check
    func refreshPermissionsAsync() async -> (screenRecording: Bool, microphone: Bool) {
        screenRecordingGranted = await checkScreenRecordingPermissionAsync()
        microphoneGranted = hasMicrophonePermission
        return (screenRecordingGranted, microphoneGranted)
    }
}
