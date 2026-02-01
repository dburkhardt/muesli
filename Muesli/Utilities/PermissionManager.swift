import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Manages app permissions for audio capture and microphone access
/// Can be injected into views via @Environment for permission state observation
///
/// macOS 14.4+ uses Core Audio taps for system audio capture, which requires
/// the Audio Capture permission (NSAudioCaptureUsageDescription) in the
/// Screen & System Audio Recording privacy bucket.
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

    /// UserDefaults key for persisting system audio permission probe results
    private let systemAudioPermissionDefaultsKey = "systemAudioPermissionGranted"

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

        // Use persisted system audio permission result from our Core Audio tap probe.
        // CGPreflightScreenCaptureAccess reflects the Screen Recording bucket and can be true
        // even when System Audio Recording is not granted.
        audioCaptureGranted = UserDefaults.standard.bool(forKey: systemAudioPermissionDefaultsKey)
        let preflightScreenCapture = CGPreflightScreenCaptureAccess()

        // #region agent log
        let audioCaptureUsageDescription = Bundle.main.object(
            forInfoDictionaryKey: "NSAudioCaptureUsageDescription"
        ) as? String
        let logPayload: [String: Any] = [
            "location": "PermissionManager.swift:init",
            "message": "Initial audio capture permission snapshot",
            "data": [
                "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
                "hasAudioCaptureUsageDescription": audioCaptureUsageDescription != nil,
                "audioCaptureUsageDescription": audioCaptureUsageDescription ?? "MISSING",
                "preflightScreenCapture": preflightScreenCapture,
                "cachedSystemAudioGranted": audioCaptureGranted
            ],
            "timestamp": Date().timeIntervalSince1970 * 1000,
            "sessionId": "debug-session",
            "runId": "pre",
            "hypothesisId": "H1"
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: logPayload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            if let handle = FileHandle(forWritingAtPath: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log") {
                handle.seekToEndOfFile()
                handle.write((jsonStr + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? (jsonStr + "\n").write(
                    toFile: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log",
                    atomically: false,
                    encoding: .utf8
                )
            }
        }
        // #endregion

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
        // Re-check using cached tap-probe result (preflight can be true for screen recording only)
        return audioCaptureGranted
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
    var hasScreenRecordingPermission: Bool {
        return audioCaptureGranted
    }

    /// User-facing explanation for system audio capture permission
    static let screenRecordingExplanation = """
        Muesli needs System Audio Recording access to capture audio from meeting apps.

        This permission allows capturing system audio only - no screen content is recorded.
        """

    /// Check audio capture permission asynchronously
    func checkScreenRecordingPermissionAsync() async -> Bool {
        await DiagnosticLogger.shared.log(.permission, "checkScreenRecordingPermissionAsync called")

        guard !Self.isRunningTests else {
            await DiagnosticLogger.shared.log(.permission, "EARLY RETURN: isRunningTests=true")
            return false
        }

        // Use cached system audio permission (set by tap probe) to avoid false positives.
        return audioCaptureGranted
    }

    /// Request system audio capture permission
    /// Triggers the System Audio Recording permission prompt by attempting to create a Core Audio tap.
    /// Note: There is NO public API to request this permission directly - it's triggered by attempting
    /// to use the audio capture API (AudioHardwareCreateProcessTap).
    func requestScreenRecordingPermission() async -> Bool {
        Task {
            await DiagnosticLogger.shared.log(.permission, "requestSystemAudioPermission called - triggering via Core Audio tap probe")
        }

        // #region agent log
        let requestPayload: [String: Any] = [
            "location": "PermissionManager.swift:requestScreenRecordingPermission",
            "message": "Request system audio permission invoked",
            "data": [
                "isRunningTests": Self.isRunningTests,
                "preflightScreenCapture": CGPreflightScreenCaptureAccess(),
                "audioCaptureGranted": audioCaptureGranted,
                "hasAudioCaptureUsageDescription": Bundle.main.object(
                    forInfoDictionaryKey: "NSAudioCaptureUsageDescription"
                ) != nil
            ],
            "timestamp": Date().timeIntervalSince1970 * 1000,
            "sessionId": "debug-session",
            "runId": "pre",
            "hypothesisId": "H2"
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: requestPayload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            if let handle = FileHandle(forWritingAtPath: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log") {
                handle.seekToEndOfFile()
                handle.write((jsonStr + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? (jsonStr + "\n").write(
                    toFile: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log",
                    atomically: false,
                    encoding: .utf8
                )
            }
        }
        // #endregion

        guard !Self.isRunningTests else {
            Task {
                await DiagnosticLogger.shared.log(.permission, "EARLY RETURN: isRunningTests=true")
            }
            return false
        }

        // Trigger System Audio Recording permission by attempting to create a Core Audio tap.
        // This is the ONLY way to trigger this permission prompt - there is no public API.
        // The tap will be immediately destroyed after triggering the prompt.
        let result = await triggerSystemAudioPermissionPrompt()
        await MainActor.run {
            audioCaptureGranted = result || audioCaptureGranted
            if result {
                UserDefaults.standard.set(true, forKey: systemAudioPermissionDefaultsKey)
            }
        }
        await DiagnosticLogger.shared.log(.permission, "System audio permission probe result: \(result)")
        return result
    }
    
    /// Attempts to create a minimal Core Audio tap to trigger the System Audio Recording permission prompt.
    /// This is the only way to programmatically request this permission on macOS 14.4+.
    /// Returns true if permission was granted, false otherwise.
    private func triggerSystemAudioPermissionPrompt() async -> Bool {
        // Import Core Audio types
        typealias AudioObjectID = UInt32
        let kAudioObjectUnknown: AudioObjectID = 0
        
        // Try to create a tap - this will trigger the permission prompt if not yet granted
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "MuesliPermissionProbe"
        tapDescription.isPrivate = true
        
        var tapObjectID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(tapDescription, &tapObjectID)
        
        // Clean up immediately - we just wanted to trigger the prompt
        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
        }
        
        // noErr (0) means success - permission was granted
        // -54 (errSecNotAuthorized) or other errors mean permission denied/pending
        let granted = (status == noErr)

        // #region agent log
        let probePayload: [String: Any] = [
            "location": "PermissionManager.swift:triggerSystemAudioPermissionPrompt",
            "message": "Core Audio tap probe result",
            "data": [
                "status": status,
                "tapObjectID": tapObjectID,
                "granted": granted
            ],
            "timestamp": Date().timeIntervalSince1970 * 1000,
            "sessionId": "debug-session",
            "runId": "pre",
            "hypothesisId": "H3"
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: probePayload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            if let handle = FileHandle(forWritingAtPath: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log") {
                handle.seekToEndOfFile()
                handle.write((jsonStr + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? (jsonStr + "\n").write(
                    toFile: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log",
                    atomically: false,
                    encoding: .utf8
                )
            }
        }
        // #endregion
        
        Task {
            await DiagnosticLogger.shared.log(.permission, 
                "Core Audio tap probe: status=\(status), granted=\(granted)")
        }
        
        return granted
    }

    /// Open System Settings to the Screen & System Audio Recording pane
    /// On macOS 14.4+ with Core Audio taps, this is the correct privacy pane for system audio capture.
    func openScreenRecordingSettings() {
        // On macOS 14.4+, system audio recording permission is in the same pane as screen recording
        // The pane is called "Screen & System Audio Recording" in System Settings
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
        let oldAudioCapture = audioCaptureGranted
        let oldMicrophone = microphoneGranted
        microphoneGranted = hasMicrophonePermission

        // Audio capture: keep cached result from tap probe to avoid screen-recording false positives
        let preflight = CGPreflightScreenCaptureAccess()

        // #region agent log
        let refreshPayload: [String: Any] = [
            "location": "PermissionManager.swift:refreshPermissions",
            "message": "Permission refresh result",
            "data": [
                "preflightScreenCapture": preflight,
                "oldAudioCapture": oldAudioCapture,
                "newAudioCapture": audioCaptureGranted,
                "oldMicrophone": oldMicrophone,
                "newMicrophone": microphoneGranted
            ],
            "timestamp": Date().timeIntervalSince1970 * 1000,
            "sessionId": "debug-session",
            "runId": "pre",
            "hypothesisId": "H1"
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: refreshPayload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            if let handle = FileHandle(forWritingAtPath: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log") {
                handle.seekToEndOfFile()
                handle.write((jsonStr + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? (jsonStr + "\n").write(
                    toFile: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log",
                    atomically: false,
                    encoding: .utf8
                )
            }
        }
        // #endregion

        return (audioCaptureGranted, microphoneGranted)
    }

    func refreshPermissionsAsync() async -> (screenRecording: Bool, microphone: Bool) {
        audioCaptureGranted = await checkScreenRecordingPermissionAsync()
        microphoneGranted = hasMicrophonePermission

        return (audioCaptureGranted, microphoneGranted)
    }
}
