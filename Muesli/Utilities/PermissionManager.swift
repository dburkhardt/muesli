@preconcurrency import AVFoundation
import Foundation

/// Manages app permissions for audio capture and microphone access
/// Can be injected into views via @Environment for permission state observation
///
/// macOS 26+ uses Core Audio taps for system audio capture, which requires
/// the Audio Capture permission (NSAudioCaptureUsageDescription) - NOT screen recording.
@Observable
@MainActor
final class PermissionManager: PermissionManagerProtocol {
    // MARK: - Observable State

    /// Cached audio capture permission state (for system audio via Core Audio taps)
    var audioCaptureGranted: Bool = false

    /// Cached microphone permission state (updated via refresh)
    var microphoneGranted: Bool = false

    // MARK: - Legacy Compatibility

    /// Legacy alias for audioCaptureGranted (for code that still references screen recording)
    var screenRecordingGranted: Bool {
        get { audioCaptureGranted }
        set { audioCaptureGranted = newValue }
    }

    // MARK: - Awaiting Settings State

    /// Whether user clicked "Open System Settings" for audio capture and we're awaiting their return
    var awaitingAudioCaptureFromSettings: Bool = false

    /// Legacy alias
    var awaitingScreenRecordingFromSettings: Bool {
        get { awaitingAudioCaptureFromSettings }
        set { awaitingAudioCaptureFromSettings = newValue }
    }

    /// Whether user clicked "Open System Settings" for microphone and we're awaiting their return
    var awaitingMicrophoneFromSettings: Bool = false

    // MARK: - Notification Observers

    /// Observers registered with NotificationCenter (for proper cleanup)
    private var notificationCenterObservers: [NSObjectProtocol] = []

    /// Observers registered with DistributedNotificationCenter (for proper cleanup)
    private var distributedCenterObservers: [NSObjectProtocol] = []

    /// Callback for real-time permission changes
    var permissionDidChange: ((Bool, Bool) -> Void)?

    /// Whether permission monitoring is active (for onboarding screens)
    private var isMonitoring: Bool = false

    /// Polling timer for permission checks (fallback)
    private var pollingTimer: Timer?

    // MARK: - Initialization

    init() {
        // Log bundle ID for TCC debugging
        if let bundleID = Bundle.main.bundleIdentifier {
            print("[PermissionManager] Bundle ID: \(bundleID)")
        }

        // Skip permission checks when running tests to avoid permission prompts
        guard !Self.isRunningTests else {
            audioCaptureGranted = false
            microphoneGranted = false
            return
        }

        // Check initial permissions
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // Audio capture permission will be checked when needed
        audioCaptureGranted = false

        // Observe app becoming active (user returns from System Settings)
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
    }

    /// Handle app becoming active
    func handleDidBecomeActive() async {
        let hasCompletedOnboarding = UserDefaults.standard.bool(
            forKey: AppStorageKeys.hasCompletedOnboarding
        )

        if hasCompletedOnboarding {
            // Post-onboarding: refresh permissions
            _ = refreshPermissions()
        } else if awaitingAudioCaptureFromSettings {
            awaitingAudioCaptureFromSettings = false
            _ = refreshPermissions()
            permissionDidChange?(audioCaptureGranted, microphoneGranted)
        } else if awaitingMicrophoneFromSettings {
            awaitingMicrophoneFromSettings = false
            _ = refreshPermissions()
            permissionDidChange?(audioCaptureGranted, microphoneGranted)
        } else {
            _ = refreshPermissions()
        }
    }

    /// Detect if running in test environment
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    deinit {
        MainActor.assumeIsolated {
            notificationCenterObservers.forEach { NotificationCenter.default.removeObserver($0) }
            distributedCenterObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            pollingTimer?.invalidate()
        }
    }

    // MARK: - Awaiting Settings Methods

    /// Mark that user clicked "Open System Settings" for audio capture
    func markAwaitingScreenRecordingFromSettings() {
        awaitingAudioCaptureFromSettings = true
    }

    /// Mark that user clicked "Open System Settings" for microphone
    func markAwaitingMicrophoneFromSettings() {
        awaitingMicrophoneFromSettings = true
    }

    /// Verify screen recording permission after user clicks "Grant Permission"
    func verifyScreenRecordingAfterRequest() async -> Bool {
        // For Core Audio taps, the permission is granted through a TCC prompt
        // when the tap is first created. We assume granted if we get here.
        audioCaptureGranted = true
        return true
    }

    // MARK: - Real-time Permission Monitoring

    func startMonitoringPermissions() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let distributedCenter = DistributedNotificationCenter.default()
        let tccObserver = distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.security.authorization-right-change"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndNotifyPermissionChangesSynchronously()
            }
        }
        distributedCenterObservers.append(tccObserver)
    }

    func stopMonitoringPermissions() {
        guard isMonitoring else { return }
        isMonitoring = false

        pollingTimer?.invalidate()
        pollingTimer = nil

        distributedCenterObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedCenterObservers.removeAll()
    }

    func checkAndNotifyPermissionChangesSynchronously() {
        let oldAudioCapture = audioCaptureGranted
        let oldMicrophone = microphoneGranted

        let (newAudioCapture, newMicrophone) = refreshPermissions()

        if newAudioCapture != oldAudioCapture || newMicrophone != oldMicrophone {
            permissionDidChange?(newAudioCapture, newMicrophone)
        }
    }

    // MARK: - Audio Capture Permission (Core Audio Taps)

    /// Check if audio capture permission is granted (for system audio via Core Audio taps)
    /// On macOS 26+, this uses the NSAudioCaptureUsageDescription permission
    var hasScreenRecordingPermission: Bool {
        // For Core Audio taps, we assume permission is granted once the user completes onboarding
        // The actual TCC prompt happens when the tap is created
        return audioCaptureGranted
    }

    /// User-facing explanation for audio capture permission
    static let screenRecordingExplanation = """
        Muesli needs Audio Capture access to record system audio from meeting apps.

        This permission allows capturing audio only - no screen content is recorded.
        """

    /// Check audio capture permission asynchronously
    func checkScreenRecordingPermissionAsync() async -> Bool {
        await DiagnosticLogger.shared.log(.permission, "checkScreenRecordingPermissionAsync called")

        guard !Self.isRunningTests else {
            await DiagnosticLogger.shared.log(.permission, "EARLY RETURN: isRunningTests=true")
            return false
        }

        // For Core Audio taps, the permission is checked when creating the tap
        // We return the cached state here
        return audioCaptureGranted
    }

    /// Request audio capture permission
    /// Note: For Core Audio taps, the system will prompt when the tap is first created
    func requestScreenRecordingPermission() {
        Task {
            await DiagnosticLogger.shared.log(.permission, "requestScreenRecordingPermission called")
        }

        guard !Self.isRunningTests else {
            Task {
                await DiagnosticLogger.shared.log(.permission, "EARLY RETURN: isRunningTests=true")
            }
            return
        }

        // For Core Audio taps on macOS 26+, the permission prompt happens automatically
        // when the tap is first created. Mark as granted to proceed with onboarding.
        audioCaptureGranted = true
        Task {
            await DiagnosticLogger.shared.log(.permission, "Audio capture permission assumed granted for Core Audio taps")
        }
    }

    /// Open System Settings to the Screen Recording pane
    /// Note: For macOS 26+ with Core Audio taps, this may need to point to a different pane
    func openScreenRecordingSettings() {
        // Try the audio capture settings first, fall back to screen recording
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Microphone Permission

    var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var isMicrophonePermissionDenied: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }

    func requestMicrophonePermission() async -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let plistDesc = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String

        await DiagnosticLogger.shared.log(.permission,
            "requestMicrophonePermission called. Bundle: \(bundleID)")
        await DiagnosticLogger.shared.log(.permission,
            "NSMicrophoneUsageDescription: \(plistDesc ?? "MISSING")")

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
            await DiagnosticLogger.shared.log(.permission, "Status is denied/restricted, returning false")
            return false
        @unknown default:
            await DiagnosticLogger.shared.log(.permission, "Unknown status, returning false")
            return false
        }
    }

    private func statusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Combined Checks

    var hasAllPermissions: Bool {
        hasScreenRecordingPermission && hasMicrophonePermission
    }

    var hasMinimumPermissions: Bool {
        return hasScreenRecordingPermission || hasMicrophonePermission
    }

    func refreshPermissions() -> (screenRecording: Bool, microphone: Bool) {
        // Microphone check is always reliable
        microphoneGranted = hasMicrophonePermission

        // Audio capture: once granted during onboarding, assume it stays granted
        // The actual permission is checked when creating the Core Audio tap

        return (audioCaptureGranted, microphoneGranted)
    }

    func refreshPermissionsAsync() async -> (screenRecording: Bool, microphone: Bool) {
        audioCaptureGranted = await checkScreenRecordingPermissionAsync()
        microphoneGranted = hasMicrophonePermission

        return (audioCaptureGranted, microphoneGranted)
    }
}
