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
    
    // MARK: - Awaiting Settings State
    
    /// Whether user clicked "Open System Settings" for screen recording and we're awaiting their return
    var awaitingScreenRecordingFromSettings: Bool = false
    
    /// Whether user clicked "Open System Settings" for microphone and we're awaiting their return
    var awaitingMicrophoneFromSettings: Bool = false
    
    // MARK: - Notification Observers
    
    /// Notification observers for automatic permission refresh
    /// Contains observers from both NotificationCenter and DistributedNotificationCenter
    private var observers: [NSObjectProtocol] = []
    
    /// Observers registered with NotificationCenter (for proper cleanup)
    private var notificationCenterObservers: [NSObjectProtocol] = []
    
    /// Observers registered with DistributedNotificationCenter (for proper cleanup)
    private var distributedCenterObservers: [NSObjectProtocol] = []
    
    /// Callback for real-time permission changes
    var permissionDidChange: ((Bool, Bool) -> Void)?
    
    /// Whether permission monitoring is active (for onboarding screens)
    private var isMonitoring: Bool = false
    
    /// Polling timer for permission checks (fallback) - DEPRECATED, kept for compatibility
    private var pollingTimer: Timer?
    
    // MARK: - Permission Caching
    
    /// Timestamp of last successful screen recording permission check
    /// Used to avoid repeated SCShareableContent calls which can trigger prompts
    private var lastPermissionCheck: Date?
    
    /// Duration to cache permission check results (5 minutes)
    /// This reduces SCShareableContent calls while still detecting permission revocation
    private let permissionCacheDuration: TimeInterval = 300
    
    // MARK: - Initialization
    
    init() {
        // Log bundle ID for TCC debugging
        if let bundleID = Bundle.main.bundleIdentifier {
            print("[PermissionManager] Bundle ID: \(bundleID)")
        }
        
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
        // Use strict step-based guards to prevent unwanted permission prompts
        notificationCenterObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.handleDidBecomeActive()
                }
            }
        )
        
        // Observe app going to background to clear permission cache
        // This ensures a fresh check when the user returns (in case they changed permissions)
        notificationCenterObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastPermissionCheck = nil
                }
            }
        )
    }
    
    /// Handle app becoming active with strict step-based guards
    /// CRITICAL: step == 0 (welcome screen) must NEVER trigger async checks
    ///
    /// Note: Made internal (not private) to enable testing of the permission flow logic.
    /// Tests can call this directly to verify step-based guards work correctly.
    func handleDidBecomeActive() async {
        let hasCompletedOnboarding = UserDefaults.standard.bool(
            forKey: AppStorageKeys.hasCompletedOnboarding
        )
        let currentStep = UserDefaults.standard.integer(forKey: AppStorageKeys.onboardingCurrentStep)
        
        if hasCompletedOnboarding {
            // Post-onboarding: safe to use async refresh
            _ = await refreshPermissionsAsync()
        } else if currentStep == 0 {
            // STRICT GUARD: Welcome screen (step 0) - ONLY safe sync check, NO async
            // This prevents the screen recording dialog from appearing on the welcome screen
            _ = refreshPermissions()
        } else if awaitingScreenRecordingFromSettings {
            // User returned from System Settings after clicking "Open Settings" for screen recording
            // Use async check to reliably detect if permission was granted
            awaitingScreenRecordingFromSettings = false
            _ = await checkScreenRecordingPermissionAsync()
            permissionDidChange?(screenRecordingGranted, microphoneGranted)
        } else if awaitingMicrophoneFromSettings {
            // User returned from System Settings after clicking "Open Settings" for microphone
            // Microphone check is always safe (doesn't trigger prompts)
            awaitingMicrophoneFromSettings = false
            _ = refreshPermissions()
            permissionDidChange?(screenRecordingGranted, microphoneGranted)
        } else {
            // On permission screens but not awaiting settings return
            // Use safe sync check only to avoid triggering prompts
            _ = refreshPermissions()
        }
    }
    
    /// Detect if running in test environment
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }
    
    deinit {
        // Remove all observers (use MainActor.assumeIsolated since deinit is nonisolated)
        MainActor.assumeIsolated {
            // Remove NotificationCenter observers (from init)
            notificationCenterObservers.forEach { NotificationCenter.default.removeObserver($0) }
            
            // Remove DistributedNotificationCenter observers (from startMonitoringPermissions)
            distributedCenterObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            
            pollingTimer?.invalidate()
        }
    }
    
    // MARK: - Awaiting Settings Methods
    
    /// Mark that user clicked "Open System Settings" for screen recording
    /// When app becomes active again, we'll use async check to detect permission change
    func markAwaitingScreenRecordingFromSettings() {
        awaitingScreenRecordingFromSettings = true
    }
    
    /// Mark that user clicked "Open System Settings" for microphone
    /// When app becomes active again, we'll check microphone permission
    func markAwaitingMicrophoneFromSettings() {
        awaitingMicrophoneFromSettings = true
    }
    
    /// Verify screen recording permission after user clicks "Grant Permission"
    /// This uses async check to reliably detect if permission was granted
    func verifyScreenRecordingAfterRequest() async -> Bool {
        let granted = await checkScreenRecordingPermissionAsync()
        screenRecordingGranted = granted
        return granted
    }
    
    // MARK: - Real-time Permission Monitoring
    
    /// Start monitoring permissions for real-time updates
    /// This is more aggressive than the default app activation observer
    /// Use this when on permission screens to provide instant feedback
    func startMonitoringPermissions() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        // Register for distributed notifications (system-level)
        // These fire when TCC permissions change in System Settings
        let distributedCenter = DistributedNotificationCenter.default()
        
        // Listen for TCC authorization changes
        let tccObserver = distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.security.authorization-right-change"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Use synchronous check to avoid triggering SCShareableContent
                // which would show the screen recording dialog
                self?.checkAndNotifyPermissionChangesSynchronously()
            }
        }
        distributedCenterObservers.append(tccObserver)
        
        // NOTE: Polling timer removed. We rely on:
        // 1. Distributed notifications (above) for TCC permission changes
        // 2. didBecomeActiveNotification (in init) for app returning from System Settings
        // This prevents the screen recording dialog from appearing on the microphone screen
    }
    
    /// Stop monitoring permissions
    func stopMonitoringPermissions() {
        guard isMonitoring else { return }
        isMonitoring = false
        
        // Invalidate and clear polling timer
        pollingTimer?.invalidate()
        pollingTimer = nil
        
        // Remove distributed notification observers
        distributedCenterObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedCenterObservers.removeAll()
    }
    
    /// Check permissions and notify if changed (synchronous version)
    /// Uses only AVCaptureDevice.authorizationStatus for microphone (no SCShareableContent)
    /// This prevents triggering the screen recording permission dialog
    ///
    /// Note: Made internal (not private) to enable testing of the notification flow logic.
    func checkAndNotifyPermissionChangesSynchronously() {
        let oldScreenRecording = screenRecordingGranted
        let oldMicrophone = microphoneGranted
        
        // Use synchronous refresh (no SCShareableContent call)
        let (newScreenRecording, newMicrophone) = refreshPermissions()
        
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
        return screenRecordingGranted
    }
    
    /// Check screen recording permission using SCShareableContent (async, reliable)
    /// This actually queries the TCC database correctly, unlike CGPreflightScreenCaptureAccess
    ///
    /// ⚠️ WARNING: This method calls SCShareableContent.excludingDesktopWindows() which
    /// TRIGGERS the screen recording permission prompt if permission is not granted.
    /// Do NOT call during onboarding welcome screen - see spec/onboarding_flow.md
    ///
    /// This method uses caching to avoid repeated SCShareableContent calls:
    /// - If permission was verified within the last 5 minutes and was granted, returns cached value
    /// - Cache is cleared when app goes to background (willResignActiveNotification)
    func checkScreenRecordingPermissionAsync() async -> Bool {
        await DiagnosticLogger.shared.log(.permission, "checkScreenRecordingPermissionAsync called")
        
        // Skip permission checks when running tests
        guard !Self.isRunningTests else {
            await DiagnosticLogger.shared.log(.permission, "EARLY RETURN: isRunningTests=true")
            return false
        }
        
        // Return cached value if recently verified and permission was granted
        if let lastCheck = lastPermissionCheck,
           Date().timeIntervalSince(lastCheck) < permissionCacheDuration,
           screenRecordingGranted {
            let remaining = Int(permissionCacheDuration - Date().timeIntervalSince(lastCheck))
            await DiagnosticLogger.shared.log(.permission, "Returning cached permission (valid for \(remaining)s)")
            return true
        }
        
        do {
            // This call will fail with a specific TCC error if permission is not granted
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            await DiagnosticLogger.shared.log(.permission, "Screen recording permission granted (SCShareableContent succeeded)")
            screenRecordingGranted = true
            lastPermissionCheck = Date()  // Update cache timestamp after successful check
            return true
        } catch {
            await DiagnosticLogger.shared.log(.permission, "Screen recording permission denied (SCShareableContent error: \(error.localizedDescription))")
            lastPermissionCheck = nil  // Clear cache on failure
            return false
        }
    }
    
    /// Request screen recording permission
    /// Note: This will trigger the system permission dialog
    func requestScreenRecordingPermission() {
        Task {
            await DiagnosticLogger.shared.log(.permission, "requestScreenRecordingPermission called")
        }
        
        // Skip permission requests when running tests
        guard !Self.isRunningTests else {
            Task {
                await DiagnosticLogger.shared.log(.permission, "EARLY RETURN: isRunningTests=true")
            }
            return
        }
        
        // This will trigger the permission prompt
        let result = CGRequestScreenCaptureAccess()
        Task {
            await DiagnosticLogger.shared.log(.permission, "CGRequestScreenCaptureAccess returned: \(result)")
        }
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
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let plistDesc = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        
        await DiagnosticLogger.shared.log(.permission,
            "requestMicrophonePermission called. Bundle: \(bundleID)")
        await DiagnosticLogger.shared.log(.permission,
            "NSMicrophoneUsageDescription: \(plistDesc ?? "MISSING")")
        
        // Skip permission requests when running tests
        if Self.isRunningTests {
            await DiagnosticLogger.shared.log(.permission, "EARLY RETURN: isRunningTests=true")
            return false
        }
        
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        await DiagnosticLogger.shared.log(.permission,
            "authorizationStatus(for: .audio) = \(status.rawValue) (\(statusName(status)))")
        
        switch status {
        case .authorized:
            await DiagnosticLogger.shared.log(.permission, "Already authorized, returning true")
            return true
        case .notDetermined:
            await DiagnosticLogger.shared.log(.permission, "Status is notDetermined, calling requestAccess...")
            let result = await AVCaptureDevice.requestAccess(for: .audio)
            await DiagnosticLogger.shared.log(.permission, "requestAccess returned: \(result)")
            return result
        case .denied, .restricted:
            await DiagnosticLogger.shared.log(.permission, "Status is denied/restricted, returning false (no prompt possible)")
            return false
        @unknown default:
            await DiagnosticLogger.shared.log(.permission, "Unknown status, returning false")
            return false
        }
    }
    
    /// Helper to convert AVAuthorizationStatus to string
    private func statusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
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
    /// Updates the observable cached state using optimistic OR pattern
    ///
    /// IMPORTANT: Uses optimistic OR pattern for screen recording:
    /// - CGPreflightScreenCaptureAccess() can detect newly granted permission
    /// - BUT it's unreliable with ad-hoc signing (may return false even when granted)
    /// - Once cache is true, we keep it true (permission can't be revoked without restart)
    func refreshPermissions() -> (screenRecording: Bool, microphone: Bool) {
        // Optimistic OR: CGPreflight can detect newly granted permission,
        // but is unreliable with ad-hoc signing. Once cache is true, keep it.
        let preflightResult = CGPreflightScreenCaptureAccess()
        screenRecordingGranted = preflightResult || screenRecordingGranted
        
        // Microphone check is always reliable
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
