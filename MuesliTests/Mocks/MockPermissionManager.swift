import Foundation
@testable import Muesli_vmr

/// Mock implementation of PermissionManager for testing
@MainActor
final class MockPermissionManager: PermissionManagerProtocol {
    
    // MARK: - State
    
    var hasScreenRecordingPermission: Bool = false
    var hasMicrophonePermission: Bool = false
    var isMicrophonePermissionDenied: Bool = false
    
    var hasAllPermissions: Bool {
        hasScreenRecordingPermission && hasMicrophonePermission
    }
    
    // MARK: - Test Control Properties
    
    var screenRecordingPermissionAsyncResult: Bool = false
    var microphonePermissionRequestResult: Bool = false
    
    // MARK: - Call Tracking
    
    var checkScreenRecordingAsyncCallCount: Int = 0
    var requestScreenRecordingCallCount: Int = 0
    var openScreenRecordingSettingsCallCount: Int = 0
    var requestMicrophoneCallCount: Int = 0
    var openMicrophoneSettingsCallCount: Int = 0
    var refreshPermissionsCallCount: Int = 0
    
    // MARK: - PermissionManagerProtocol
    
    func checkScreenRecordingPermissionAsync() async -> Bool {
        checkScreenRecordingAsyncCallCount += 1
        return screenRecordingPermissionAsyncResult
    }
    
    func requestScreenRecordingPermission() {
        requestScreenRecordingCallCount += 1
    }
    
    func openScreenRecordingSettings() {
        openScreenRecordingSettingsCallCount += 1
    }
    
    func requestMicrophonePermission() async -> Bool {
        requestMicrophoneCallCount += 1
        hasMicrophonePermission = microphonePermissionRequestResult
        return microphonePermissionRequestResult
    }
    
    func openMicrophoneSettings() {
        openMicrophoneSettingsCallCount += 1
    }
    
    func refreshPermissions() -> (screenRecording: Bool, microphone: Bool) {
        refreshPermissionsCallCount += 1
        return (hasScreenRecordingPermission, hasMicrophonePermission)
    }
    
    // MARK: - Test Helpers
    
    /// Grant all permissions
    func grantAllPermissions() {
        hasScreenRecordingPermission = true
        hasMicrophonePermission = true
        screenRecordingPermissionAsyncResult = true
        microphonePermissionRequestResult = true
        isMicrophonePermissionDenied = false
    }
    
    /// Deny all permissions
    func denyAllPermissions() {
        hasScreenRecordingPermission = false
        hasMicrophonePermission = false
        screenRecordingPermissionAsyncResult = false
        microphonePermissionRequestResult = false
    }
    
    /// Reset all state for next test
    func reset() {
        hasScreenRecordingPermission = false
        hasMicrophonePermission = false
        isMicrophonePermissionDenied = false
        screenRecordingPermissionAsyncResult = false
        microphonePermissionRequestResult = false
        checkScreenRecordingAsyncCallCount = 0
        requestScreenRecordingCallCount = 0
        openScreenRecordingSettingsCallCount = 0
        requestMicrophoneCallCount = 0
        openMicrophoneSettingsCallCount = 0
        refreshPermissionsCallCount = 0
    }
}
