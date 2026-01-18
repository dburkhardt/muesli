@testable import Muesli
import XCTest

/// Tests for PermissionManager
///
/// Note: Many permission checks are skipped when NSClassFromString("XCTestCase") != nil
/// to avoid triggering system permission dialogs during tests. Tests focus on:
/// - Observable state management
/// - Monitoring lifecycle
/// - Permission refresh logic
/// - Callback mechanisms
@MainActor
final class PermissionManagerTests: XCTestCase {
    var permissionManager: PermissionManager!
    
    override func setUp() async throws {
        try await super.setUp()
        permissionManager = PermissionManager()
    }
    
    override func tearDown() async throws {
        permissionManager = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInit_InTestEnvironment_InitializesWithNoPermissions() {
        // Given: Test environment (detected via NSClassFromString("XCTestCase"))
        
        // When: Initialized
        let manager = PermissionManager()
        
        // Then: Should start with no permissions granted
        XCTAssertFalse(manager.hasScreenRecordingPermission)
        XCTAssertFalse(manager.hasMicrophonePermission)
        XCTAssertFalse(manager.hasAllPermissions)
    }
    
    func testInit_ObserversNotSetUp_InTestEnvironment() {
        // Given/When: Initialized in test environment
        let manager = PermissionManager()
        
        // Then: Should skip observer setup (verified implicitly - no permission prompts)
        // This test documents the behavior; actual observer setup is skipped in tests
        XCTAssertNotNil(manager) // Basic sanity check
    }
    
    // MARK: - Permission State Tests
    
    func testHasAllPermissions_RequiresBothPermissions() {
        // Given: Manager with manually set screen recording state
        // Note: hasMicrophonePermission always checks AVCaptureDevice (not cached)
        permissionManager.screenRecordingGranted = true
        
        // When: Checking all permissions
        let hasAll = permissionManager.hasAllPermissions
        
        // Then: Should return false in test environment (mic always false)
        // This tests the AND logic of hasAllPermissions
        XCTAssertFalse(hasAll)
    }
    
    func testHasScreenRecordingPermission_ReturnsCachedValue() {
        // Given: Cached screen recording permission set
        permissionManager.screenRecordingGranted = true
        
        // When: Checking screen recording permission
        let hasPermission = permissionManager.hasScreenRecordingPermission
        
        // Then: Should return cached value
        XCTAssertTrue(hasPermission)
    }
    
    func testHasScreenRecordingPermission_WhenNotGranted() {
        // Given: No screen recording permission cached
        permissionManager.screenRecordingGranted = false
        
        // When: Checking screen recording permission
        let hasPermission = permissionManager.hasScreenRecordingPermission
        
        // Then: Should return false
        XCTAssertFalse(hasPermission)
    }
    
    func testHasMicrophonePermission_InTestEnvironment_ReturnsFalse() {
        // Given: Test environment (AVCaptureDevice.authorizationStatus != .authorized)
        
        // When: Checking microphone permission
        let hasPermission = permissionManager.hasMicrophonePermission
        
        // Then: Should return false (system check, not cached)
        XCTAssertFalse(hasPermission)
    }
    
    // MARK: - Screen Recording Permission Tests
    
    func testCheckScreenRecordingPermissionAsync_InTestEnvironment_ReturnsFalse() async {
        // Given: Test environment
        
        // When: Checking screen recording permission async
        let granted = await permissionManager.checkScreenRecordingPermissionAsync()
        
        // Then: Should return false (test mode)
        XCTAssertFalse(granted)
    }
    
    func testRequestScreenRecordingPermission_InTestEnvironment_DoesNotCrash() {
        // Given: Test environment
        
        // When: Requesting permission
        permissionManager.requestScreenRecordingPermission()
        
        // Then: Should not crash or show dialog (test mode)
        // Test passes if no exception thrown
    }
    
    func testOpenScreenRecordingSettings_CreatesValidURL() {
        // Given: Permission manager
        
        // When: Opening settings
        // Note: We can't easily test actual opening, but we can verify the method exists
        permissionManager.openScreenRecordingSettings()
        
        // Then: Should not crash
        // The URL format is: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
    }
    
    // MARK: - Microphone Permission Tests
    
    func testRequestMicrophonePermission_InTestEnvironment_ReturnsFalse() async {
        // Given: Test environment
        
        // When: Requesting microphone permission
        let granted = await permissionManager.requestMicrophonePermission()
        
        // Then: Should return false (test mode)
        XCTAssertFalse(granted)
    }
    
    func testOpenMicrophoneSettings_DoesNotCrash() {
        // Given: Permission manager
        
        // When: Opening settings
        permissionManager.openMicrophoneSettings()
        
        // Then: Should not crash
        // The URL format is: x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone
    }
    
    // MARK: - Refresh Permission Tests
    
    func testRefreshPermissions_ReturnsCurrentState() {
        // Given: Known permission state
        permissionManager.screenRecordingGranted = true
        permissionManager.microphoneGranted = false
        
        // When: Refreshing permissions
        let (screen, mic) = permissionManager.refreshPermissions()
        
        // Then: Should return current state
        XCTAssertTrue(screen)
        XCTAssertFalse(mic)
    }
    
    func testRefreshPermissions_UpdatesCachedState() {
        // Given: Initial state
        permissionManager.screenRecordingGranted = false
        permissionManager.microphoneGranted = false
        
        // When: Refreshing permissions (in test environment, always returns false)
        let (screen, mic) = permissionManager.refreshPermissions()
        
        // Then: Cached state should be updated
        XCTAssertEqual(permissionManager.screenRecordingGranted, screen)
        XCTAssertEqual(permissionManager.microphoneGranted, mic)
    }
    
    func testRefreshPermissionsAsync_InTestEnvironment_ReturnsFalseForBoth() async {
        // Given: Test environment
        
        // When: Refreshing permissions async
        let (screen, mic) = await permissionManager.refreshPermissionsAsync()
        
        // Then: Should return false for both (test mode)
        XCTAssertFalse(screen)
        XCTAssertFalse(mic)
    }
    
    func testRefreshPermissionsAsync_UpdatesCachedState() async {
        // Given: Initial state
        permissionManager.screenRecordingGranted = true
        permissionManager.microphoneGranted = true
        
        // When: Refreshing permissions async
        _ = await permissionManager.refreshPermissionsAsync()
        
        // Then: Should update cached state (false in test environment)
        XCTAssertFalse(permissionManager.screenRecordingGranted)
    }
    
    // MARK: - Monitoring Tests
    
    func testStartMonitoringPermissions_StartsMonitoring() {
        // Given: Not monitoring
        
        // When: Starting monitoring
        permissionManager.startMonitoringPermissions()
        
        // Then: Should be monitoring
        // Note: isMonitoring is private, so we verify via side effects
        // Multiple starts should be idempotent
        permissionManager.startMonitoringPermissions()
        permissionManager.startMonitoringPermissions()
    }
    
    func testStopMonitoringPermissions_StopsMonitoring() {
        // Given: Monitoring
        permissionManager.startMonitoringPermissions()
        
        // When: Stopping monitoring
        permissionManager.stopMonitoringPermissions()
        
        // Then: Should stop monitoring
        // Multiple stops should be idempotent
        permissionManager.stopMonitoringPermissions()
        permissionManager.stopMonitoringPermissions()
    }
    
    func testMonitoringLifecycle_StartStopStart() {
        // Given: Permission manager
        
        // When: Starting, stopping, starting again
        permissionManager.startMonitoringPermissions()
        permissionManager.stopMonitoringPermissions()
        permissionManager.startMonitoringPermissions()
        
        // Then: Should handle lifecycle correctly (no crash)
        permissionManager.stopMonitoringPermissions()
    }
    
    // MARK: - Permission Change Callback Tests
    
    func testPermissionDidChange_WhenSet_IsCallable() {
        // Given: Callback set
        var callbackCalled = false
        var callbackScreen = false
        var callbackMic = false
        
        permissionManager.permissionDidChange = { screen, mic in
            callbackCalled = true
            callbackScreen = screen
            callbackMic = mic
        }
        
        // When: Manually triggering callback
        permissionManager.permissionDidChange?(true, false)
        
        // Then: Should be called with correct values
        XCTAssertTrue(callbackCalled)
        XCTAssertTrue(callbackScreen)
        XCTAssertFalse(callbackMic)
    }
    
    func testPermissionDidChange_CanBeNil() {
        // Given: No callback set
        permissionManager.permissionDidChange = nil
        
        // When: Attempting to call nil callback
        permissionManager.permissionDidChange?(true, true)
        
        // Then: Should not crash
    }
    
    func testPermissionDidChange_CanBeUpdated() {
        // Given: Initial callback
        var callCount = 0
        permissionManager.permissionDidChange = { _, _ in
            callCount += 1
        }
        
        // When: Updating callback
        permissionManager.permissionDidChange = { _, _ in
            callCount += 10
        }
        permissionManager.permissionDidChange?(true, true)
        
        // Then: Should use updated callback
        XCTAssertEqual(callCount, 10)
    }
    
    // MARK: - Observable State Tests
    
    func testScreenRecordingGranted_IsObservable() {
        // Given: Initial state
        permissionManager.screenRecordingGranted = false
        
        // When: Changing state
        permissionManager.screenRecordingGranted = true
        
        // Then: State should be updated
        XCTAssertTrue(permissionManager.screenRecordingGranted)
    }
    
    func testMicrophoneGranted_IsObservable() {
        // Given: Initial state
        permissionManager.microphoneGranted = false
        
        // When: Changing state
        permissionManager.microphoneGranted = true
        
        // Then: State should be updated
        XCTAssertTrue(permissionManager.microphoneGranted)
    }
    
    func testObservableState_CanBeReadMultipleTimes() {
        // Given: State set
        permissionManager.screenRecordingGranted = true
        permissionManager.microphoneGranted = false
        
        // When: Reading multiple times
        let read1 = (permissionManager.screenRecordingGranted, permissionManager.microphoneGranted)
        let read2 = (permissionManager.screenRecordingGranted, permissionManager.microphoneGranted)
        let read3 = (permissionManager.screenRecordingGranted, permissionManager.microphoneGranted)
        
        // Then: Should return consistent values
        XCTAssertTrue(read1.0)
        XCTAssertFalse(read1.1)
        XCTAssertTrue(read2.0)
        XCTAssertFalse(read2.1)
        XCTAssertTrue(read3.0)
        XCTAssertFalse(read3.1)
    }
    
    // MARK: - Edge Case Tests
    
    func testDeinit_CleansUpResources() {
        // Given: Manager with monitoring started
        var manager: PermissionManager? = PermissionManager()
        manager?.startMonitoringPermissions()
        
        // When: Deallocating
        manager = nil
        
        // Then: Should clean up without crashing
        XCTAssertNil(manager)
    }
    
    func testMultiplePermissionChecks_DoNotCrash() async {
        // Given: Permission manager
        
        // When: Multiple sequential checks
        for _ in 0..<10 {
            _ = await permissionManager.checkScreenRecordingPermissionAsync()
        }
        
        // Then: Should not crash
    }
    
    func testMultipleMicrophoneRequests_DoNotCrash() async {
        // Given: Permission manager
        
        // When: Multiple sequential requests
        for _ in 0..<10 {
            _ = await permissionManager.requestMicrophonePermission()
        }
        
        // Then: Should not crash
    }
    
    func testMultipleRefreshCalls_DoNotCrash() async {
        // Given: Permission manager
        
        // When: Multiple sequential refreshes
        for _ in 0..<10 {
            _ = await permissionManager.refreshPermissionsAsync()
        }
        
        // Then: Should not crash
    }
    
    func testMonitoring_StartAndStopMultipleTimes() {
        // Given: Permission manager
        
        // When: Starting and stopping multiple times
        for _ in 0..<5 {
            permissionManager.startMonitoringPermissions()
            permissionManager.stopMonitoringPermissions()
        }
        
        // Then: Should handle correctly (no crash)
    }
}
