import Foundation
@testable import Muesli_vmr

/// Mock implementation of MicrophoneManager for testing
@MainActor
final class MockMicrophoneManager: MicrophoneManagerProtocol {
    
    // MARK: - State
    
    var availableDevices: [MicrophoneManager.MicrophoneDevice] = []
    private(set) var selectedDeviceID: String?
    
    var currentDefaultDevice: MicrophoneManager.MicrophoneDevice? {
        availableDevices.first { $0.isDefault }
    }
    
    // MARK: - Call Tracking
    
    var setSelectedDeviceIDCallCount: Int = 0
    var refreshDevicesCallCount: Int = 0
    var deviceWithIDCallCount: Int = 0
    var lastSelectedDeviceID: String?
    
    // MARK: - MicrophoneManagerProtocol
    
    func setSelectedDeviceID(_ deviceID: String?) {
        setSelectedDeviceIDCallCount += 1
        lastSelectedDeviceID = deviceID
        selectedDeviceID = deviceID
    }
    
    func refreshDevices() {
        refreshDevicesCallCount += 1
    }
    
    func device(withID deviceID: String) -> MicrophoneManager.MicrophoneDevice? {
        deviceWithIDCallCount += 1
        return availableDevices.first { $0.id == deviceID }
    }
    
    // MARK: - Test Helpers
    
    /// Create a mock microphone device
    static func createMockDevice(
        id: String = UUID().uuidString,
        name: String = "Mock Microphone",
        isDefault: Bool = false
    ) -> MicrophoneManager.MicrophoneDevice {
        MicrophoneManager.MicrophoneDevice(id: id, name: name, isDefault: isDefault)
    }
    
    /// Add common mock microphones
    func addCommonMicrophones() {
        availableDevices = [
            MicrophoneManager.MicrophoneDevice(id: "builtin-mic", name: "MacBook Pro Microphone", isDefault: true),
            MicrophoneManager.MicrophoneDevice(id: "external-mic", name: "External USB Microphone", isDefault: false),
            MicrophoneManager.MicrophoneDevice(id: "airpods-mic", name: "AirPods Pro", isDefault: false)
        ]
        selectedDeviceID = "builtin-mic"
    }
    
    /// Reset all state for next test
    func reset() {
        availableDevices = []
        selectedDeviceID = nil
        setSelectedDeviceIDCallCount = 0
        refreshDevicesCallCount = 0
        deviceWithIDCallCount = 0
        lastSelectedDeviceID = nil
    }
}
