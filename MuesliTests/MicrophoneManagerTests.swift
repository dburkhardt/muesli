@testable import Muesli
import XCTest

/// Tests for MicrophoneManager
///
/// Note: Many tests verify permission-gated behavior. In test environment,
/// AVCaptureDevice.authorizationStatus(for: .audio) is typically .notDetermined
/// or .denied, so device enumeration returns empty arrays.
@MainActor
final class MicrophoneManagerTests: XCTestCase {
    var microphoneManager: MicrophoneManager!
    let testDeviceIDKey = "selectedMicrophoneDeviceID"
    
    override func setUp() async throws {
        try await super.setUp()
        // Clear UserDefaults before each test
        UserDefaults.standard.removeObject(forKey: testDeviceIDKey)
        microphoneManager = MicrophoneManager()
    }
    
    override func tearDown() async throws {
        microphoneManager = nil
        UserDefaults.standard.removeObject(forKey: testDeviceIDKey)
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInit_LoadsSavedDeviceIDFromUserDefaults() {
        // Given: Saved device ID in UserDefaults
        let savedID = "saved-mic-123"
        UserDefaults.standard.set(savedID, forKey: testDeviceIDKey)
        
        // When: Creating new manager
        let manager = MicrophoneManager()
        
        // Then: Should load saved ID
        XCTAssertEqual(manager.selectedDeviceID, savedID)
    }
    
    func testInit_WithNoSavedID_StartsWithNil() {
        // Given: No saved device ID
        UserDefaults.standard.removeObject(forKey: testDeviceIDKey)
        
        // When: Creating new manager
        let manager = MicrophoneManager()
        
        // Then: Should start with nil
        XCTAssertNil(manager.selectedDeviceID)
    }
    
    func testInit_DoesNotTriggerDeviceEnumeration() {
        // Given: Test environment without mic permission
        
        // When: Creating new manager
        let manager = MicrophoneManager()
        
        // Then: availableDevices should be empty (not enumerated)
        XCTAssertEqual(manager.availableDevices.count, 0)
    }
    
    // MARK: - Device Selection Tests
    
    func testSetSelectedDeviceID_UpdatesProperty() {
        // Given: Manager
        XCTAssertNil(microphoneManager.selectedDeviceID)
        
        // When: Setting device ID
        let deviceID = "test-mic-456"
        microphoneManager.setSelectedDeviceID(deviceID)
        
        // Then: Property should be updated
        XCTAssertEqual(microphoneManager.selectedDeviceID, deviceID)
    }
    
    func testSetSelectedDeviceID_PersistsToUserDefaults() {
        // Given: Manager
        let deviceID = "persistent-mic-789"
        
        // When: Setting device ID
        microphoneManager.setSelectedDeviceID(deviceID)
        
        // Then: Should persist to UserDefaults
        let saved = UserDefaults.standard.string(forKey: testDeviceIDKey)
        XCTAssertEqual(saved, deviceID)
    }
    
    func testSetSelectedDeviceID_WithNil_RemovesFromUserDefaults() {
        // Given: Manager with device ID set
        let deviceID = "temporary-mic"
        microphoneManager.setSelectedDeviceID(deviceID)
        XCTAssertNotNil(UserDefaults.standard.string(forKey: testDeviceIDKey))
        
        // When: Setting to nil
        microphoneManager.setSelectedDeviceID(nil)
        
        // Then: Should remove from UserDefaults
        XCTAssertNil(UserDefaults.standard.string(forKey: testDeviceIDKey))
        XCTAssertNil(microphoneManager.selectedDeviceID)
    }
    
    func testSetSelectedDeviceID_UpdatesSelection() {
        // Given: Manager with initial device
        microphoneManager.setSelectedDeviceID("device-1")
        XCTAssertEqual(microphoneManager.selectedDeviceID, "device-1")
        
        // When: Changing device
        microphoneManager.setSelectedDeviceID("device-2")
        
        // Then: Selection should be updated
        XCTAssertEqual(microphoneManager.selectedDeviceID, "device-2")
    }
    
    // MARK: - Device Enumeration Tests
    
    func testRefreshDevices_WithoutPermission_ClearsDevices() {
        // Given: Manager (no mic permission in test environment)
        
        // When: Refreshing devices
        microphoneManager.refreshDevices()
        
        // Then: Should return empty list
        XCTAssertEqual(microphoneManager.availableDevices.count, 0)
    }
    
    func testRefreshDevices_CanBeCalledMultipleTimes() {
        // Given: Manager
        
        // When: Calling refresh multiple times
        microphoneManager.refreshDevices()
        microphoneManager.refreshDevices()
        microphoneManager.refreshDevices()
        
        // Then: Should not crash
        XCTAssertEqual(microphoneManager.availableDevices.count, 0)
    }
    
    // MARK: - MicrophoneDevice Tests
    
    func testMicrophoneDevice_InitializesCorrectly() {
        // Given: Device parameters
        let id = "device-id"
        let name = "Test Microphone"
        let isDefault = true
        
        // When: Creating device
        let device = MicrophoneManager.MicrophoneDevice(
            id: id,
            name: name,
            isDefault: isDefault
        )
        
        // Then: Should initialize with correct values
        XCTAssertEqual(device.id, id)
        XCTAssertEqual(device.name, name)
        XCTAssertEqual(device.isDefault, isDefault)
    }
    
    func testMicrophoneDevice_DefaultsIsDefaultToFalse() {
        // Given/When: Creating device without isDefault
        let device = MicrophoneManager.MicrophoneDevice(
            id: "id",
            name: "name"
        )
        
        // Then: isDefault should be false
        XCTAssertFalse(device.isDefault)
    }
    
    func testMicrophoneDevice_IsIdentifiable() {
        // Given: Two devices with same ID
        let device1 = MicrophoneManager.MicrophoneDevice(id: "same-id", name: "Device 1")
        let device2 = MicrophoneManager.MicrophoneDevice(id: "same-id", name: "Device 2")
        
        // When/Then: IDs should match
        XCTAssertEqual(device1.id, device2.id)
    }
    
    func testMicrophoneDevice_IsHashable() {
        // Given: Two identical devices
        let device1 = MicrophoneManager.MicrophoneDevice(id: "id", name: "name", isDefault: true)
        let device2 = MicrophoneManager.MicrophoneDevice(id: "id", name: "name", isDefault: true)
        
        // When: Creating set with both
        let set: Set<MicrophoneManager.MicrophoneDevice> = [device1, device2]
        
        // Then: Should deduplicate
        XCTAssertEqual(set.count, 1)
    }
    
    func testMicrophoneDevice_HashWithDifferentIDs() {
        // Given: Two devices with different IDs
        let device1 = MicrophoneManager.MicrophoneDevice(id: "id-1", name: "Device")
        let device2 = MicrophoneManager.MicrophoneDevice(id: "id-2", name: "Device")
        
        // When: Creating set with both
        let set: Set<MicrophoneManager.MicrophoneDevice> = [device1, device2]
        
        // Then: Should keep both
        XCTAssertEqual(set.count, 2)
    }
    
    // MARK: - Device Lookup Tests
    
    func testDeviceWithID_WhenDeviceExists_ReturnsDevice() {
        // Given: Manager with devices
        let device1 = MicrophoneManager.MicrophoneDevice(id: "id-1", name: "Device 1")
        let device2 = MicrophoneManager.MicrophoneDevice(id: "id-2", name: "Device 2")
        microphoneManager.availableDevices = [device1, device2]
        
        // When: Looking up by ID
        let found = microphoneManager.device(withID: "id-2")
        
        // Then: Should return correct device
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "id-2")
        XCTAssertEqual(found?.name, "Device 2")
    }
    
    func testDeviceWithID_WhenDeviceDoesNotExist_ReturnsNil() {
        // Given: Manager with devices
        let device = MicrophoneManager.MicrophoneDevice(id: "id-1", name: "Device 1")
        microphoneManager.availableDevices = [device]
        
        // When: Looking up non-existent ID
        let found = microphoneManager.device(withID: "non-existent")
        
        // Then: Should return nil
        XCTAssertNil(found)
    }
    
    func testDeviceWithID_WithEmptyDevices_ReturnsNil() {
        // Given: Manager with no devices
        microphoneManager.availableDevices = []
        
        // When: Looking up any ID
        let found = microphoneManager.device(withID: "any-id")
        
        // Then: Should return nil
        XCTAssertNil(found)
    }
    
    // MARK: - Current Default Device Tests
    
    func testCurrentDefaultDevice_WithoutPermission_ReturnsNil() {
        // Given: Test environment without mic permission
        
        // When: Getting current default device
        let defaultDevice = microphoneManager.currentDefaultDevice
        
        // Then: Should return nil (permission guard)
        XCTAssertNil(defaultDevice)
    }
    
    // MARK: - Observable State Tests
    
    func testAvailableDevices_IsObservable() {
        // Given: Manager with empty devices
        XCTAssertEqual(microphoneManager.availableDevices.count, 0)
        
        // When: Setting devices
        let device = MicrophoneManager.MicrophoneDevice(id: "id", name: "Device")
        microphoneManager.availableDevices = [device]
        
        // Then: Should be updated
        XCTAssertEqual(microphoneManager.availableDevices.count, 1)
        XCTAssertEqual(microphoneManager.availableDevices.first?.id, "id")
    }
    
    func testSelectedDeviceID_CanBeReadMultipleTimes() {
        // Given: Manager with device ID set
        microphoneManager.setSelectedDeviceID("test-id")
        
        // When: Reading multiple times
        let read1 = microphoneManager.selectedDeviceID
        let read2 = microphoneManager.selectedDeviceID
        let read3 = microphoneManager.selectedDeviceID
        
        // Then: Should return consistent value
        XCTAssertEqual(read1, "test-id")
        XCTAssertEqual(read2, "test-id")
        XCTAssertEqual(read3, "test-id")
    }
    
    // MARK: - Edge Case Tests
    
    func testSetSelectedDeviceID_WithEmptyString_PersistsEmptyString() {
        // Given: Manager
        
        // When: Setting empty string (not nil)
        microphoneManager.setSelectedDeviceID("")
        
        // Then: Should persist empty string
        XCTAssertEqual(microphoneManager.selectedDeviceID, "")
        XCTAssertEqual(UserDefaults.standard.string(forKey: testDeviceIDKey), "")
    }
    
    func testMultipleManagers_ShareUserDefaultsState() {
        // Given: First manager with device set
        let manager1 = MicrophoneManager()
        manager1.setSelectedDeviceID("shared-device")
        
        // When: Creating second manager
        let manager2 = MicrophoneManager()
        
        // Then: Should load same device ID
        XCTAssertEqual(manager2.selectedDeviceID, "shared-device")
    }
    
    func testDeviceWithID_PerformanceWithManyDevices() {
        // Given: Manager with many devices
        let devices = (0..<100).map { i in
            MicrophoneManager.MicrophoneDevice(id: "device-\(i)", name: "Device \(i)")
        }
        microphoneManager.availableDevices = devices
        
        // When: Looking up device
        let found = microphoneManager.device(withID: "device-50")
        
        // Then: Should find correct device
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "device-50")
    }
    
    func testRefreshDevices_DoesNotCrashWithInvalidPermissionState() {
        // Given: Manager in test environment
        
        // When: Calling refresh multiple times in succession
        for _ in 0..<20 {
            microphoneManager.refreshDevices()
        }
        
        // Then: Should not crash
        XCTAssertEqual(microphoneManager.availableDevices.count, 0)
    }
}
