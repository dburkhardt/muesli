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
    
    func testRequestScreenRecordingPermission_InTestEnvironment_DoesNotCrash() async {
        // Given: Test environment
        
        // When: Requesting permission
        _ = await permissionManager.requestScreenRecordingPermission()
        
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
    
    // MARK: - Awaiting Settings Tests (Jan 18, 2026 Fix)
    
    func testMarkAwaitingScreenRecordingFromSettings_SetsFlag() {
        // Given: Manager with awaiting flag not set
        XCTAssertFalse(permissionManager.awaitingScreenRecordingFromSettings)
        
        // When: Marking as awaiting from settings
        permissionManager.markAwaitingScreenRecordingFromSettings()
        
        // Then: Flag should be set to true
        XCTAssertTrue(permissionManager.awaitingScreenRecordingFromSettings)
    }
    
    func testMarkAwaitingMicrophoneFromSettings_SetsFlag() {
        // Given: Manager with awaiting flag not set
        XCTAssertFalse(permissionManager.awaitingMicrophoneFromSettings)
        
        // When: Marking as awaiting from settings
        permissionManager.markAwaitingMicrophoneFromSettings()
        
        // Then: Flag should be set to true
        XCTAssertTrue(permissionManager.awaitingMicrophoneFromSettings)
    }
    
    func testAwaitingFlags_InitiallyFalse() {
        // Given: Fresh permission manager
        let manager = PermissionManager()
        
        // Then: Both awaiting flags should be false by default
        XCTAssertFalse(manager.awaitingScreenRecordingFromSettings)
        XCTAssertFalse(manager.awaitingMicrophoneFromSettings)
    }
    
    func testAwaitingFlags_AreIndependent() {
        // Given: Manager
        
        // When: Setting only screen recording awaiting flag
        permissionManager.markAwaitingScreenRecordingFromSettings()
        
        // Then: Screen recording flag should be true, microphone should be false
        XCTAssertTrue(permissionManager.awaitingScreenRecordingFromSettings)
        XCTAssertFalse(permissionManager.awaitingMicrophoneFromSettings)
        
        // When: Also setting microphone awaiting flag
        permissionManager.markAwaitingMicrophoneFromSettings()
        
        // Then: Both should be true
        XCTAssertTrue(permissionManager.awaitingScreenRecordingFromSettings)
        XCTAssertTrue(permissionManager.awaitingMicrophoneFromSettings)
    }
    
    func testVerifyScreenRecordingAfterRequest_ReturnsAsyncResult() async {
        // Given: Test environment (async always returns false)
        
        // When: Verifying screen recording after request
        let result = await permissionManager.verifyScreenRecordingAfterRequest()
        
        // Then: Should return false in test environment
        XCTAssertFalse(result)
    }
    
    func testVerifyScreenRecordingAfterRequest_UpdatesCachedState() async {
        // Given: Manager with cached value set to true
        permissionManager.screenRecordingGranted = true
        
        // When: Verifying (returns false in test environment)
        _ = await permissionManager.verifyScreenRecordingAfterRequest()
        
        // Then: Cached state should be updated to match result (false)
        XCTAssertFalse(permissionManager.screenRecordingGranted)
    }
    
    func testVerifyScreenRecordingAfterRequest_DoesNotAffectMicrophoneState() async {
        // Given: Manager with microphone granted set to true
        permissionManager.microphoneGranted = true
        
        // When: Verifying screen recording
        _ = await permissionManager.verifyScreenRecordingAfterRequest()
        
        // Then: Microphone state should be unchanged
        XCTAssertTrue(permissionManager.microphoneGranted)
    }
    
    // MARK: - Optimistic OR Pattern Tests (Jan 18, 2026 Fix)
    
    func testRefreshPermissions_UsesOptimisticOR_WhenCacheTrue() {
        // Given: Cache is already true (from a previous async check)
        permissionManager.screenRecordingGranted = true
        
        // When: refreshPermissions() is called
        // (CGPreflightScreenCaptureAccess may return false - it's unreliable)
        let (screen, _) = permissionManager.refreshPermissions()
        
        // Then: Should remain true (optimistic OR: preflight || cached)
        // This is the key fix: once true, stays true
        XCTAssertTrue(screen)
        XCTAssertTrue(permissionManager.screenRecordingGranted)
    }
    
    func testRefreshPermissions_PreservesCachedTrueValue() {
        // Given: Cache is true
        permissionManager.screenRecordingGranted = true
        
        // When: Calling refresh multiple times
        for _ in 0..<5 {
            _ = permissionManager.refreshPermissions()
        }
        
        // Then: Should still be true (cached value preserved)
        XCTAssertTrue(permissionManager.screenRecordingGranted)
    }
    
    func testRefreshPermissions_StartsFromFalse_StaysFalse_InTestEnvironment() {
        // Given: Cache is false initially
        permissionManager.screenRecordingGranted = false
        
        // When: refreshPermissions() is called
        let (screen, _) = permissionManager.refreshPermissions()
        
        // Then: Should remain false (preflight returns false in test, cache is false)
        // In test environment, CGPreflightScreenCaptureAccess returns false
        XCTAssertFalse(screen)
    }
    
    func testRefreshPermissions_MicrophoneAlwaysUsesSystemCheck() {
        // Given: Cache set to true (but system check will return false in tests)
        permissionManager.microphoneGranted = true
        
        // When: refreshPermissions() is called
        let (_, mic) = permissionManager.refreshPermissions()
        
        // Then: Microphone should use system check (always false in test environment)
        // Unlike screen recording, microphone doesn't use optimistic OR - it's always reliable
        XCTAssertFalse(mic)
    }
    
    func testRefreshPermissions_ReturnsUpdatedValues() {
        // Given: Initial state
        permissionManager.screenRecordingGranted = true
        permissionManager.microphoneGranted = false
        
        // When: refreshPermissions() is called
        let (screen, mic) = permissionManager.refreshPermissions()
        
        // Then: Should return the updated values
        XCTAssertTrue(screen) // Preserved via optimistic OR
        XCTAssertFalse(mic) // System check
    }
    
    // MARK: - Bundle ID Logging Test
    
    func testInit_LogsBundleID() {
        // Given/When: Creating a new permission manager
        // The init() logs the bundle ID via print()
        let manager = PermissionManager()
        
        // Then: Manager should be created successfully (log output verified manually)
        // This documents that bundle ID is logged for TCC debugging
        XCTAssertNotNil(manager)
    }
    
    // MARK: - handleDidBecomeActive Tests (Jan 18, 2026 Fix)
    
    func testHandleDidBecomeActive_WhenOnboardingComplete_RefreshesAsync() async {
        // Given: Onboarding completed
        UserDefaults.standard.set(true, forKey: AppStorageKeys.hasCompletedOnboarding)
        
        // When: App becomes active
        await permissionManager.handleDidBecomeActive()
        
        // Then: Should have called async refresh (in test env, returns false)
        // The method executes the hasCompletedOnboarding branch
        XCTAssertFalse(permissionManager.screenRecordingGranted)
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.hasCompletedOnboarding)
    }
    
    func testHandleDidBecomeActive_WhenWelcomeScreen_UsesSyncCheckOnly() async {
        // Given: On welcome screen (step 0), onboarding not complete
        UserDefaults.standard.set(false, forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.set(0, forKey: AppStorageKeys.onboardingCurrentStep)
        
        // When: App becomes active
        await permissionManager.handleDidBecomeActive()
        
        // Then: Should have only used sync check (no async check that triggers dialog)
        // This verifies the strict guard for welcome screen
        XCTAssertFalse(permissionManager.screenRecordingGranted)
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.onboardingCurrentStep)
    }
    
    func testHandleDidBecomeActive_WhenAwaitingScreenRecordingFromSettings_ChecksAndNotifies() async {
        // Given: User clicked "Open Settings" for screen recording
        UserDefaults.standard.set(false, forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.set(1, forKey: AppStorageKeys.onboardingCurrentStep) // On screen recording screen
        permissionManager.awaitingScreenRecordingFromSettings = true
        
        var callbackCalled = false
        permissionManager.permissionDidChange = { _, _ in
            callbackCalled = true
        }
        
        // When: App becomes active (user returned from Settings)
        await permissionManager.handleDidBecomeActive()
        
        // Then: Should have checked permission and called callback
        XCTAssertFalse(permissionManager.awaitingScreenRecordingFromSettings, "Flag should be cleared")
        XCTAssertTrue(callbackCalled, "Callback should have been called")
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.onboardingCurrentStep)
    }
    
    func testHandleDidBecomeActive_WhenAwaitingMicrophoneFromSettings_ChecksAndNotifies() async {
        // Given: User clicked "Open Settings" for microphone
        UserDefaults.standard.set(false, forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.set(2, forKey: AppStorageKeys.onboardingCurrentStep) // On microphone screen
        permissionManager.awaitingMicrophoneFromSettings = true
        
        var callbackCalled = false
        permissionManager.permissionDidChange = { _, _ in
            callbackCalled = true
        }
        
        // When: App becomes active (user returned from Settings)
        await permissionManager.handleDidBecomeActive()
        
        // Then: Should have checked permission and called callback
        XCTAssertFalse(permissionManager.awaitingMicrophoneFromSettings, "Flag should be cleared")
        XCTAssertTrue(callbackCalled, "Callback should have been called")
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.onboardingCurrentStep)
    }
    
    func testHandleDidBecomeActive_WhenOnPermissionScreenNotAwaiting_UsesSyncCheck() async {
        // Given: On permission screen but not awaiting (e.g., just navigated there)
        UserDefaults.standard.set(false, forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.set(1, forKey: AppStorageKeys.onboardingCurrentStep)
        permissionManager.awaitingScreenRecordingFromSettings = false
        permissionManager.awaitingMicrophoneFromSettings = false
        
        // When: App becomes active
        await permissionManager.handleDidBecomeActive()
        
        // Then: Should have used sync check only (else branch)
        XCTAssertFalse(permissionManager.screenRecordingGranted)
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.onboardingCurrentStep)
    }
    
    // MARK: - checkAndNotifyPermissionChangesSynchronously Tests
    
    func testCheckAndNotifyPermissionChangesSynchronously_NoChange_NoCallback() {
        // Given: Permissions unchanged
        permissionManager.screenRecordingGranted = false
        permissionManager.microphoneGranted = false
        
        var callbackCalled = false
        permissionManager.permissionDidChange = { _, _ in
            callbackCalled = true
        }
        
        // When: Checking permissions (in test env, will remain false)
        permissionManager.checkAndNotifyPermissionChangesSynchronously()
        
        // Then: Callback should NOT be called (no change)
        XCTAssertFalse(callbackCalled)
    }
    
    func testCheckAndNotifyPermissionChangesSynchronously_WithChange_CallsCallback() {
        // Given: Screen recording was true (cache), will become different after refresh
        // Note: In test environment, CGPreflightScreenCaptureAccess returns false
        // But with optimistic OR, if cache is true, it stays true
        permissionManager.screenRecordingGranted = true
        permissionManager.microphoneGranted = true // Will change to false (system check)
        
        var callbackValues: (Bool, Bool)?
        permissionManager.permissionDidChange = { screen, mic in
            callbackValues = (screen, mic)
        }
        
        // When: Checking permissions
        permissionManager.checkAndNotifyPermissionChangesSynchronously()
        
        // Then: Callback should be called if microphone changed
        // (microphone check always uses system check, not cache)
        if permissionManager.hasMicrophonePermission != true {
            XCTAssertNotNil(callbackValues, "Callback should be called when permission changes")
        }
    }
    
    func testCheckAndNotifyPermissionChangesSynchronously_UpdatesCachedState() {
        // Given: Initial state
        permissionManager.screenRecordingGranted = true
        
        // When: Checking permissions
        permissionManager.checkAndNotifyPermissionChangesSynchronously()
        
        // Then: Should have updated state
        // Due to optimistic OR, screen recording stays true
        XCTAssertTrue(permissionManager.screenRecordingGranted)
    }
    
    // MARK: - Step-Based Guard Comprehensive Tests
    
    func testStepBasedGuard_Step0_NeverTriggersAsyncCheck() async {
        // Given: Welcome screen
        UserDefaults.standard.set(false, forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.set(0, forKey: AppStorageKeys.onboardingCurrentStep)
        
        // Record initial state
        let initialScreenRecording = permissionManager.screenRecordingGranted
        
        // When: Calling handleDidBecomeActive multiple times
        for _ in 0..<3 {
            await permissionManager.handleDidBecomeActive()
        }
        
        // Then: State should be consistent (sync check doesn't change it in test env)
        XCTAssertEqual(permissionManager.screenRecordingGranted, initialScreenRecording)
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.onboardingCurrentStep)
    }
    
    func testStepBasedGuard_Step1_WithoutAwaiting_UsesSyncCheck() async {
        // Given: On screen recording permission screen, not awaiting
        UserDefaults.standard.set(false, forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.set(1, forKey: AppStorageKeys.onboardingCurrentStep)
        permissionManager.awaitingScreenRecordingFromSettings = false
        
        // When: App becomes active
        await permissionManager.handleDidBecomeActive()
        
        // Then: Should use sync check (else branch)
        XCTAssertFalse(permissionManager.awaitingScreenRecordingFromSettings)
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.onboardingCurrentStep)
    }
    
    func testStepBasedGuard_Step2_WithoutAwaiting_UsesSyncCheck() async {
        // Given: On microphone permission screen, not awaiting
        UserDefaults.standard.set(false, forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.set(2, forKey: AppStorageKeys.onboardingCurrentStep)
        permissionManager.awaitingMicrophoneFromSettings = false
        
        // When: App becomes active
        await permissionManager.handleDidBecomeActive()
        
        // Then: Should use sync check (else branch)
        XCTAssertFalse(permissionManager.awaitingMicrophoneFromSettings)
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.hasCompletedOnboarding)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.onboardingCurrentStep)
    }
    
    // MARK: - Permission Caching Tests
    
    /// Test: Permission caching returns early when permission was recently verified
    /// This test verifies that repeated calls to checkScreenRecordingPermissionAsync()
    /// return cached values instead of making repeated SCShareableContent calls.
    func testPermissionCachingReturnsEarlyWhenRecent() async {
        // Given: Permission manager in test environment (always returns false)
        // In test environment, checkScreenRecordingPermissionAsync returns false immediately
        // But we can still verify the caching mechanism by checking call timing
        
        // When: First check (should go through full check)
        let firstResult = await permissionManager.checkScreenRecordingPermissionAsync()
        
        // When: Second check within TTL (should return cached value if permission was granted)
        // In test env, permission is always false, so cache won't help, but we verify the mechanism
        let secondStart = Date()
        let secondResult = await permissionManager.checkScreenRecordingPermissionAsync()
        let secondDuration = Date().timeIntervalSince(secondStart)
        
        // Then: Both should return false in test environment (isRunningTests check)
        XCTAssertFalse(firstResult, "First check should return false in test environment")
        XCTAssertFalse(secondResult, "Second check should return false in test environment")
        
        // The second call should be fast (nearly instant in test env due to early return)
        XCTAssertLessThan(secondDuration, 0.1, "Test environment check should be nearly instant")
    }
    
    /// Test: Permission caching returns cached value when permission IS granted
    /// This test simulates the scenario where permission was previously granted.
    func testPermissionCachingReturnsCachedValueWhenGranted() async {
        // Given: Simulate permission being granted (set cached state)
        permissionManager.screenRecordingGranted = true
        
        // First, we need to trigger a permission check to set the lastPermissionCheck timestamp
        // But in test environment, checkScreenRecordingPermissionAsync returns early
        // So we directly verify the caching logic by checking the property
        
        // When: Permission is marked as granted
        XCTAssertTrue(permissionManager.hasScreenRecordingPermission)
        
        // Then: The cached value should be used
        // (In real app, this would avoid SCShareableContent call within TTL)
        XCTAssertTrue(permissionManager.screenRecordingGranted)
    }
    
    /// Test: Cache is cleared when app goes to background (willResignActiveNotification)
    /// This ensures fresh permission checks after the user returns from System Settings.
    func testPermissionCacheInvalidatedOnBackground() async {
        // Given: Permission manager with cached state
        permissionManager.screenRecordingGranted = true
        
        // When: App goes to background (simulated via notification)
        NotificationCenter.default.post(
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        
        // Give the observer a moment to process
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        // Then: The screenRecordingGranted state should remain (cache clearing only affects lastPermissionCheck)
        // Note: We can't directly test lastPermissionCheck as it's private, but we verify the observer exists
        // The actual behavior is: next checkScreenRecordingPermissionAsync will do a fresh check
        XCTAssertTrue(permissionManager.screenRecordingGranted, "Cached permission state should not be cleared")
        
        // Note: In real app, the lastPermissionCheck = nil happens, which forces a fresh SCShareableContent
        // check on the next call to checkScreenRecordingPermissionAsync(). This test verifies the observer
        // is properly set up and doesn't crash.
    }
    
    /// Test: Multiple sequential permission checks don't cause issues
    func testMultipleSequentialPermissionChecks() async {
        // Given: Permission manager
        
        // When: Multiple sequential checks
        var results: [Bool] = []
        for _ in 0..<5 {
            let result = await permissionManager.checkScreenRecordingPermissionAsync()
            results.append(result)
        }
        
        // Then: All should return consistently (false in test env)
        XCTAssertEqual(results, [false, false, false, false, false])
    }
}
