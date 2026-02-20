import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// No-op IOProc callback as a C function pointer — has no Swift actor isolation context.
/// CoreAudio invokes this on its IO thread; using a Swift closure (even at file scope)
/// can inherit @MainActor isolation in Swift 6, causing a SIGTRAP crash.
private func noOpIOProc(
    _: AudioObjectID,
    _: UnsafePointer<AudioTimeStamp>,
    _: UnsafePointer<AudioBufferList>,
    _: UnsafePointer<AudioTimeStamp>,
    _: UnsafeMutablePointer<AudioBufferList>,
    _: UnsafePointer<AudioTimeStamp>,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    return noErr
}

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

    /// Tracks whether a system-audio permission probe is currently running
    private var systemAudioProbeTask: Task<Bool, Never>?

    /// Set to true by RecordingController when a recording session is active.
    /// The background re-probe in handleDidBecomeActive() is suppressed while recording
    /// to prevent the probe's aggregate device from interfering with the recording tap's
    /// audio hardware route (root cause of "stable but non-converging" AEC failure).
    var isActivelyRecording: Bool = false

    /// Exposes probe-in-flight state for UI gating
    var isSystemAudioProbeInFlight: Bool {
        systemAudioProbeTask != nil
    }

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
        // Note: CGPreflightScreenCaptureAccess() only reflects Screen Recording, not System Audio
        // Recording. Trust the cached tap probe result. If the user revoked permission, the tap
        // will fail at recording time and the error handler will trigger recovery.
        audioCaptureGranted = UserDefaults.standard.bool(forKey: systemAudioPermissionDefaultsKey)

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

            // Background re-probe: converge the tap permission cache with reality.
            // The cached UserDefaults key may be stale if the user granted/revoked
            // permission externally via System Settings.
            //
            // SUPPRESSED during active recording: the probe creates a temporary aggregate
            // device that competes with the recording tap for the audio hardware route.
            // This causes the recording tap's render ring to receive silence for ~20 seconds,
            // preventing AEC3 from converging (ERLE stays pinned at ~0.2 dB).
            guard !isActivelyRecording else {
                Task {
                    await DiagnosticLogger.shared.log(.permission,
                        "Background re-probe skipped — recording in progress")
                }
                return
            }

            Task { @MainActor in
                let probeResult = await self.triggerSystemAudioPermissionPrompt()
                let cachedValue = UserDefaults.standard.bool(forKey: self.systemAudioPermissionDefaultsKey)
                if probeResult != cachedValue {
                    UserDefaults.standard.set(probeResult, forKey: self.systemAudioPermissionDefaultsKey)
                    self.audioCaptureGranted = probeResult
                    self.permissionDidChange?(self.audioCaptureGranted, self.microphoneGranted)
                }
            }
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

        guard !Self.isRunningTests else {
            Task {
                await DiagnosticLogger.shared.log(.permission, "EARLY RETURN: isRunningTests=true")
            }
            return false
        }

        if let existingTask = systemAudioProbeTask {
            await DiagnosticLogger.shared.log(.permission, "System audio probe already in flight; awaiting result")
            return await existingTask.value
        }

        // Trigger System Audio Recording permission by attempting to create a Core Audio tap.
        // This is the ONLY way to trigger this permission prompt - there is no public API.
        // The tap will be immediately destroyed after triggering the prompt.
        let probeTask = Task { @MainActor [weak self] () -> Bool in
            guard let self = self else { return false }
            let previousPolicy = NSApp.activationPolicy()
            _ = NSApp.setActivationPolicy(.regular)
            defer { _ = NSApp.setActivationPolicy(previousPolicy) }
            NSApp.activate(ignoringOtherApps: true)
            let result = await self.triggerSystemAudioPermissionPrompt()
            await MainActor.run {
                self.audioCaptureGranted = result || self.audioCaptureGranted
                if result {
                    UserDefaults.standard.set(true, forKey: self.systemAudioPermissionDefaultsKey)
                }
            }
            await DiagnosticLogger.shared.log(.permission, "System audio permission probe result: \(result)")
            return result
        }

        systemAudioProbeTask = probeTask
        let result = await probeTask.value
        systemAudioProbeTask = nil
        return result
    }
    
    /// Attempts to create a minimal Core Audio tap to trigger the System Audio Recording permission prompt.
    /// This is the only way to programmatically request this permission on macOS 14.4+.
    /// Returns true if permission was granted, false otherwise.
    private func triggerSystemAudioPermissionPrompt() async -> Bool {
        let manager = AggregateDeviceManager()
        let excludedPIDs = [CoreAudioHelpers.getCurrentProcessID()]
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var ioProcID: AudioDeviceIOProcID?
        var createStatus: OSStatus = noErr
        var ioProcStatus: OSStatus = noErr
        var startStatus: OSStatus = noErr
        var granted = false

        do {
            deviceID = try manager.createTapOnlyDevice(excludedProcessIDs: excludedPIDs)
        } catch let error as AggregateDeviceError {
            switch error {
            case .creationFailed(let status), .formatQueryFailed(let status):
                createStatus = status
            default:
                createStatus = -1
            }
        } catch {
            createStatus = -1
        }

        if deviceID != kAudioObjectUnknown {
            // Use C function pointer API (AudioDeviceCreateIOProcID) instead of the
            // block-based API. C function pointers have NO Swift actor isolation context,
            // which avoids the SIGTRAP crash when CoreAudio invokes the callback on its
            // IO thread (Swift 6 would otherwise check @MainActor isolation on the block).
            ioProcStatus = AudioDeviceCreateIOProcID(
                deviceID,
                noOpIOProc,
                nil,
                &ioProcID
            )
            
            if ioProcStatus == noErr, let procID = ioProcID {
                startStatus = AudioDeviceStart(deviceID, procID)
                granted = (startStatus == noErr)
                
                if startStatus == noErr {
                    AudioDeviceStop(deviceID, procID)
                }
                
                AudioDeviceDestroyIOProcID(deviceID, procID)
                ioProcID = nil
            }
            
            manager.destroyDevice()
        }

        Task {
            await DiagnosticLogger.shared.log(
                .permission,
                "Core Audio tap probe: createStatus=\(describeOSStatus(createStatus)), ioProcStatus=\(describeOSStatus(ioProcStatus)), startStatus=\(describeOSStatus(startStatus)), granted=\(granted)"
            )
        }
        
        return granted
    }

    private func describeOSStatus(_ status: OSStatus) -> String {
        if status == noErr {
            return "noErr(0)"
        }
        let n = UInt32(bitPattern: status)
        func fourCCChar(_ value: UInt32) -> Character {
            Character(UnicodeScalar(value) ?? UnicodeScalar(32))
        }
        let chars = [
            fourCCChar((n >> 24) & 0xFF),
            fourCCChar((n >> 16) & 0xFF),
            fourCCChar((n >> 8) & 0xFF),
            fourCCChar(n & 0xFF)
        ]
        let fourCC = String(chars)
        let err = NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        return "\(status) '\(fourCC)' \(err.localizedDescription)"
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
        microphoneGranted = hasMicrophonePermission

        // Audio capture: keep cached result from tap probe to avoid screen-recording false positives

        return (audioCaptureGranted, microphoneGranted)
    }

    func refreshPermissionsAsync() async -> (screenRecording: Bool, microphone: Bool) {
        audioCaptureGranted = await checkScreenRecordingPermissionAsync()
        microphoneGranted = hasMicrophonePermission

        return (audioCaptureGranted, microphoneGranted)
    }
}
