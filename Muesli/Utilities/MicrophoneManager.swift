import AVFoundation
import CoreAudio
import Foundation
import os.log

/// Manages microphone device enumeration and selection
@MainActor
@Observable
final class MicrophoneManager: MicrophoneManagerProtocol {
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "MicrophoneManager")
    
    // MARK: - Types
    
    struct MicrophoneDevice: Identifiable, Hashable {
        let id: String
        let name: String
        let isDefault: Bool
        
        init(id: String, name: String, isDefault: Bool = false) {
            self.id = id
            self.name = name
            self.isDefault = isDefault
        }
    }
    
    // MARK: - Properties
    
    /// Available microphone devices
    var availableDevices: [MicrophoneDevice] = []
    
    /// Currently selected microphone device ID
    private(set) var selectedDeviceID: String?
    
    private static let selectedDeviceIDKey = "selectedMicrophoneDeviceID"
    
    /// Listener for device list changes (devices added/removed)
    private var deviceListListenerID: AudioObjectPropertyListenerBlock?
    
    /// Whether the device change listener is active
    private var isListeningForDeviceChanges = false
    
    // MARK: - Initialization
    
    init() {
        // Load saved preference from UserDefaults
        selectedDeviceID = UserDefaults.standard.string(forKey: Self.selectedDeviceIDKey)
        
        // ⚠️ WARNING: Do NOT call refreshDevices() here!
        // AVCaptureDevice.DiscoverySession for audio devices can trigger the
        // microphone permission prompt on macOS. We must defer device enumeration
        // until after microphone permission has been granted during onboarding.
        // Call refreshDevices() explicitly when permission is confirmed.
        // See: spec/onboarding_flow.md "AVCaptureDevice and Permission Prompts"
    }
    
    deinit {
        // Note: Can't call MainActor-isolated method from deinit
        // The listener will be automatically cleaned up when this object is deallocated
    }
    
    // MARK: - Device Change Listening
    
    /// Start listening for device changes (call after permission is granted)
    func startListeningForDeviceChanges() {
        guard !isListeningForDeviceChanges else { return }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Dispatch to main actor for UI updates
            Task { @MainActor in
                guard let self = self else { return }
                self.logger.info("Audio device list changed - refreshing")
                self.refreshDevices()
            }
        }
        
        deviceListListenerID = listenerBlock
        
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            listenerBlock
        )
        
        if status == noErr {
            isListeningForDeviceChanges = true
            logger.info("Started listening for audio device changes")
        } else {
            logger.warning("Failed to add device list change listener: \(status)")
        }
    }
    
    /// Stop listening for device changes
    func stopListeningForDeviceChanges() {
        guard isListeningForDeviceChanges, let listenerBlock = deviceListListenerID else { return }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            listenerBlock
        )
        
        deviceListListenerID = nil
        isListeningForDeviceChanges = false
        logger.info("Stopped listening for audio device changes")
    }
    
    // MARK: - Device Filtering
    
    /// Check if a device is a Continuity Camera device (iPhone/iPad microphone)
    /// - Parameter device: The AVCaptureDevice to check
    /// - Returns: true if the device is an iPhone/iPad Continuity Camera device
    private func isContinuityCameraDevice(_ device: AVCaptureDevice) -> Bool {
        // Primary filter: Check for Continuity Camera device type (macOS 14+)
        if #available(macOS 14.0, *) {
            if device.deviceType == .continuityCamera {
                logger.debug("Skipping Continuity Camera device: \(device.localizedName)")
                return true
            }
        }
        
        // Fallback filter 1: Check device name for iPhone/iPad
        let deviceName = device.localizedName.lowercased()
        if deviceName.contains("iphone") || deviceName.contains("ipad") {
            logger.debug("Skipping iOS device: \(device.localizedName)")
            return true
        }
        
        // Fallback filter 2: Check modelID for iOS device identifiers
        let modelID = device.modelID.lowercased()
        if modelID.hasPrefix("iphone") || modelID.hasPrefix("ipad") {
            logger.debug("Skipping iOS device by modelID: \(device.localizedName) (\(modelID))")
            return true
        }
        
        return false
    }
    
    // MARK: - Device Selection
    
    /// Set the selected microphone device ID
    func setSelectedDeviceID(_ deviceID: String?) {
        selectedDeviceID = deviceID
        
        if let deviceID = deviceID {
            UserDefaults.standard.set(deviceID, forKey: Self.selectedDeviceIDKey)
            setSystemDefaultMicrophone(deviceID: deviceID)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedDeviceIDKey)
        }
        
        refreshDevices()
    }
    
    // MARK: - System Default Device

    /// Query Core Audio for the system default input device UID.
    /// Returns nil if the query fails (e.g., no input devices present).
    private static func getSystemDefaultInputUID() -> String? {
        guard let deviceID = try? CoreAudioHelpers.getDefaultInputDevice(),
              let uid = try? CoreAudioHelpers.getDeviceUID(deviceID) else {
            return nil
        }
        return uid
    }

    // MARK: - Device Enumeration

    /// Refresh the list of available microphone devices
    ///
    /// ⚠️ WARNING: Only call this after microphone permission has been granted.
    /// AVCaptureDevice.DiscoverySession can trigger permission prompts on macOS.
    /// See: spec/onboarding_flow.md "AVCaptureDevice and Permission Prompts"
    func refreshDevices() {
        // Check if microphone permission is granted before accessing devices
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            // Permission not granted - clear devices and return
            availableDevices = []
            return
        }

        var devices: [MicrophoneDevice] = []

        // Use AVCaptureDevice to enumerate audio input devices (works on macOS)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )

        let captureDevices = discoverySession.devices

        // Get the true system default input device via Core Audio
        // (AVCaptureDevice.DiscoverySession ordering is arbitrary and unreliable)
        let systemDefaultUID = Self.getSystemDefaultInputUID()
        let defaultDevice = captureDevices.first(where: { $0.uniqueID == systemDefaultUID })
            ?? captureDevices.first
        
        for device in captureDevices {
            // Filter out virtual aggregate devices created by ScreenCaptureKit
            // These devices (like "CADefaultDeviceAggregate-XXXXX") don't deliver real audio
            // and cause the microphone to fail on first recording
            if device.uniqueID.contains("Aggregate") || device.localizedName.contains("Aggregate") {
                logger.debug("Skipping aggregate device: \(device.localizedName) (\(device.uniqueID))")
                continue
            }
            
            // Filter out Continuity Camera devices (iPhone/iPad microphones)
            if isContinuityCameraDevice(device) {
                continue
            }
            
            let isDefault = device.uniqueID == defaultDevice?.uniqueID
            let microphoneDevice = MicrophoneDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: isDefault
            )
            devices.append(microphoneDevice)
        }
        
        // Sort: default first, then alphabetically
        devices.sort { device1, device2 in
            if device1.isDefault { return true }
            if device2.isDefault { return false }
            return device1.name < device2.name
        }
        
        availableDevices = devices
        
        // If we have a saved preference but it's not in the list, clear it
        if let savedID = selectedDeviceID, !devices.contains(where: { $0.id == savedID }) {
            selectedDeviceID = nil
        }
        
        // If no device is selected but we have devices, select the default
        if selectedDeviceID == nil, let defaultDevice = devices.first(where: { $0.isDefault }) {
            selectedDeviceID = defaultDevice.id
        }
    }
    
    // MARK: - System Default Management
    
    /// Set the preferred microphone device
    /// Note: We now use AVAudioEngine which allows specifying the input device.
    private func setSystemDefaultMicrophone(deviceID: String) {
        // Check permission before accessing devices
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            // Just store the preference, device validation will happen when permission is granted
            logger.info("Selected microphone (pending permission): \(deviceID)")
            return
        }
        
        // Verify the device exists
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        
        if discoverySession.devices.contains(where: { $0.uniqueID == deviceID }) {
            // Device exists, preference is stored in UserDefaults
            logger.info("Selected microphone: \(deviceID)")
        }
    }
    
    /// Get the current default microphone device
    ///
    /// ⚠️ WARNING: Only call this after microphone permission has been granted.
    /// AVCaptureDevice.DiscoverySession can trigger permission prompts.
    var currentDefaultDevice: MicrophoneDevice? {
        // Check if microphone permission is granted before accessing devices
        // to avoid triggering the permission prompt during onboarding
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return nil
        }
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        
        // Find the system default input device via Core Audio, filtering out
        // aggregate and Continuity Camera devices that don't deliver real audio
        let systemDefaultUID = Self.getSystemDefaultInputUID()
        let eligibleDevices = discoverySession.devices.filter { device in
            !device.uniqueID.contains("Aggregate") &&
            !device.localizedName.contains("Aggregate") &&
            !isContinuityCameraDevice(device)
        }
        // Prefer the true system default; fall back to first eligible device
        guard let defaultDevice = eligibleDevices.first(where: { $0.uniqueID == systemDefaultUID })
                ?? eligibleDevices.first else { return nil }
        
        return MicrophoneDevice(
            id: defaultDevice.uniqueID,
            name: defaultDevice.localizedName,
            isDefault: true
        )
    }
    
    /// Get device by ID
    func device(withID deviceID: String) -> MicrophoneDevice? {
        availableDevices.first { $0.id == deviceID }
    }
}
