import Foundation
import AVFoundation

/// Manages microphone device enumeration and selection
@MainActor
@Observable
final class MicrophoneManager: MicrophoneManagerProtocol {
    
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
        
        // Get system default (first device is typically the default)
        let defaultDevice = captureDevices.first
        
        for device in captureDevices {
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
            print("[MicrophoneManager] Selected microphone (pending permission): \(deviceID)")
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
            print("[MicrophoneManager] Selected microphone: \(deviceID)")
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
        
        guard let defaultDevice = discoverySession.devices.first else { return nil }
        
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
