@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

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
    
    /// Callback for real-time permission changes
    var permissionDidChange: ((Bool, Bool) -> Void)?
    
    /// Whether permission monitoring is active (for onboarding screens)
    private var isMonitoring: Bool = false
    
    /// Polling timer for permission checks (fallback)
    private var pollingTimer: Timer?
    
    // MARK: - Initialization
    
    init() {
        // Skip permission checks when running tests to avoid permission prompts
        guard !Self.isRunningTests else {
            // In test environment, assume no permissions granted
            screenRecordingGranted = false
            microphoneGranted = false
            return
        }
        
        // Check initial permissions using reliable async method
        // CGPreflightScreenCaptureAccess() is unreliable with ad-hoc signing
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // Screen recording will be checked async on first use
        screenRecordingGranted = false
        
        // Observe app becoming active (user returns from System Settings)
        // Use async refresh for reliable permission detection with ad-hoc signing
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    // ⚠️ CRITICAL: Do NOT call refreshPermissionsAsync() on the welcome screen!
                    // SCShareableContent.excludingDesktopWindows() triggers the screen recording
                    // permission prompt if permission not granted.
                    // 
                    // However, once user is on permission screens (step >= 1), we SHOULD refresh
                    // when they return from System Settings, otherwise they have to manually
                    // click "Check Again" which is poor UX.
                    // 
                    // See: spec/onboarding_flow.md "SCShareableContent in Notification Observers"
                    let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: AppStorageKeys.hasCompletedOnboarding)
                    let currentStep = UserDefaults.standard.integer(forKey: AppStorageKeys.onboardingCurrentStep)
                    
                    // Allow refresh if:
                    // 1. Onboarding is complete, OR
                    // 2. User is on permission screens (step 1+), not welcome (step 0)
                    guard hasCompletedOnboarding || currentStep > 0 else {
                        return
                    }
                    
                    // Use reliable async check - SCShareableContent correctly queries TCC
                    // even with ad-hoc signing (CGPreflightScreenCaptureAccess does not)
                    _ = await self?.refreshPermissionsAsync()
                }
            }
        )
    }
    
    /// Detect if running in test environment
    private static var isRunningTests: Bool {
        let result = NSClassFromString("XCTestCase") != nil
        // #region agent log
        Task { @MainActor in
            let logData: [String: Any] = ["isRunningTests": result, "className": NSClassFromString("XCTestCase") != nil]
            if let jsonData = try? JSONSerialization.data(withJSONObject: ["location": "PermissionManager.swift:87", "message": "isRunningTests check", "data": logData, "timestamp": Date().timeIntervalSince1970 * 1000, "sessionId": "debug-session", "hypothesisId": "C"], options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let urlString = "http://127.0.0.1:7242/ingest/479643ff-bd3c-4f32-9fd4-c21f7950fef0"
                guard let url = URL(string: urlString) else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = jsonData
                URLSession.shared.dataTask(with: request).resume()
            }
        }
        // #endregion
        return result
    }
    
    deinit {
        // Remove all observers (use MainActor.assumeIsolated since deinit is nonisolated)
        MainActor.assumeIsolated {
            // Remove from DistributedNotificationCenter (where they were registered)
            observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            pollingTimer?.invalidate()
        }
    }
    
    // MARK: - Real-time Permission Monitoring
    
    /// Start monitoring permissions for real-time updates
    /// This is more aggressive than the default app activation observer
    /// Use this when on permission screens to provide instant feedback
    func startMonitoringPermissions() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        // Register for distributed notifications (system-level)
        // Note: These may not fire reliably for all permission changes
        let distributedCenter = DistributedNotificationCenter.default()
        
        // Listen for TCC authorization changes
        let tccObserver = distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.security.authorization-right-change"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.checkAndNotifyPermissionChanges()
            }
        }
        observers.append(tccObserver)
        
        // Start polling as fallback (1 second interval)
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkAndNotifyPermissionChanges()
            }
        }
    }
    
    /// Stop monitoring permissions
    func stopMonitoringPermissions() {
        guard isMonitoring else { return }
        isMonitoring = false
        
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    /// Check permissions and notify if changed
    private func checkAndNotifyPermissionChanges() async {
        let oldScreenRecording = screenRecordingGranted
        let oldMicrophone = microphoneGranted
        
        // Check current state
        let (newScreenRecording, newMicrophone) = await refreshPermissionsAsync()
        
        // Notify if changed
        if newScreenRecording != oldScreenRecording || newMicrophone != oldMicrophone {
            permissionDidChange?(newScreenRecording, newMicrophone)
        }
    }
    
    // MARK: - Screen Recording Permission
    
    /// Check if screen recording permission is granted
    /// NOTE: Returns cached value from last async check. Use checkScreenRecordingPermissionAsync() 
    /// for fresh check. CGPreflightScreenCaptureAccess() is unreliable with ad-hoc signing.
    var hasScreenRecordingPermission: Bool {
        screenRecordingGranted
    }
    
    /// Check screen recording permission using SCShareableContent (async, reliable)
    /// This actually queries the TCC database correctly, unlike CGPreflightScreenCaptureAccess
    ///
    /// ⚠️ WARNING: This method calls SCShareableContent.excludingDesktopWindows() which
    /// TRIGGERS the screen recording permission prompt if permission is not granted.
    /// Do NOT call during onboarding welcome screen - see spec/onboarding_flow.md
    func checkScreenRecordingPermissionAsync() async -> Bool {
        // #region agent log
        let isTestEnv = Self.isRunningTests
        Task { @MainActor in
            let logData: [String: Any] = ["isRunningTests": isTestEnv, "willSkip": isTestEnv]
            if let jsonData = try? JSONSerialization.data(withJSONObject: ["location": "PermissionManager.swift:170", "message": "checkScreenRecordingPermissionAsync called", "data": logData, "timestamp": Date().timeIntervalSince1970 * 1000, "sessionId": "debug-session", "hypothesisId": "B"], options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let urlString = "http://127.0.0.1:7242/ingest/479643ff-bd3c-4f32-9fd4-c21f7950fef0"
                guard let url = URL(string: urlString) else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = jsonData
                URLSession.shared.dataTask(with: request).resume()
            }
        }
        // #endregion
        
        // Skip permission checks when running tests
        guard !Self.isRunningTests else {
            return false
        }
        
        // #region agent log
        Task { @MainActor in
            let logData: [String: Any] = ["aboutToCallSCShareableContent": true]
            if let jsonData = try? JSONSerialization.data(withJSONObject: ["location": "PermissionManager.swift:177", "message": "About to call SCShareableContent - THIS TRIGGERS PROMPT", "data": logData, "timestamp": Date().timeIntervalSince1970 * 1000, "sessionId": "debug-session", "hypothesisId": "B"], options: []) {
                let urlString = "http://127.0.0.1:7242/ingest/479643ff-bd3c-4f32-9fd4-c21f7950fef0"
                guard let url = URL(string: urlString) else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = jsonData
                URLSession.shared.dataTask(with: request).resume()
            }
        }
        // #endregion
        
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
    ///
    /// ⚠️ WARNING: Calls checkScreenRecordingPermissionAsync() which may trigger
    /// the screen recording permission prompt. Do NOT call during onboarding.
    func refreshPermissionsAsync() async -> (screenRecording: Bool, microphone: Bool) {
        screenRecordingGranted = await checkScreenRecordingPermissionAsync()
        microphoneGranted = hasMicrophonePermission
        return (screenRecordingGranted, microphoneGranted)
    }
}
