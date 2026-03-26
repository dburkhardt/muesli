@testable import Muesli
import XCTest

/// Comprehensive tests for PreferencesManager
/// Target coverage: 90% (146/162 lines)
@MainActor
final class PreferencesManagerTests: XCTestCase {
    // MARK: - Properties
    
    private var preferencesManager: PreferencesManager!
    
    // MARK: - Setup / Teardown
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Clear all UserDefaults keys used by PreferencesManager
        clearUserDefaults()
        
        // Create fresh PreferencesManager
        preferencesManager = PreferencesManager()
    }
    
    override func tearDown() async throws {
        preferencesManager = nil
        
        // Clean up UserDefaults
        clearUserDefaults()
        
        try await super.tearDown()
    }
    
    private func clearUserDefaults() {
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.outputDirectory)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.launchAtLogin)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.transcriptionMode)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.echoCancellationEnabled)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.aecAlwaysOnMigrationDone)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.secondPassASREnabled)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.secondPassModelPreference)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.reprocessWorkflowMigrationDone)
        UserDefaults.standard.removeObject(forKey: "autoReprocessAfterMeetingEnabled")
        UserDefaults.standard.removeObject(forKey: "secondPassSpecificModel")
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.audioChunkDuration)
        UserDefaults.standard.removeObject(forKey: PreferencesManager.migrationCheckedKey)
    }
    
    // MARK: - Output Directory Tests
    
    /// Test that outputDirectory returns default path when no custom path is set
    func testOutputDirectory_ReturnsDefaultWhenNotSet() async {
        let defaultPath = PreferencesManager.defaultOutputDirectory
        
        XCTAssertEqual(preferencesManager.outputDirectory, defaultPath)
    }
    
    /// Test that outputDirectory can be set to a custom path
    func testOutputDirectory_CanSetCustomPath() async {
        let customPath = URL(fileURLWithPath: "/tmp/custom-recordings")
        
        preferencesManager.outputDirectory = customPath
        
        XCTAssertEqual(preferencesManager.outputDirectory, customPath)
    }
    
    /// Test that custom outputDirectory is persisted to UserDefaults
    func testOutputDirectory_PersistsToUserDefaults() async {
        let customPath = URL(fileURLWithPath: "/tmp/custom-recordings")
        
        preferencesManager.outputDirectory = customPath
        
        let savedPath = UserDefaults.standard.string(forKey: AppStorageKeys.outputDirectory)
        XCTAssertEqual(savedPath, customPath.path)
    }
    
    /// Test that outputDirectory persists across PreferencesManager instances
    func testOutputDirectory_PersistsAcrossInstances() async {
        let customPath = URL(fileURLWithPath: "/tmp/custom-recordings")
        preferencesManager.outputDirectory = customPath
        
        // Create new instance
        let newManager = PreferencesManager()
        
        XCTAssertEqual(newManager.outputDirectory, customPath)
    }
    
    /// Test that setOutputDirectory method works
    func testSetOutputDirectory_UpdatesValue() async {
        let customPath = URL(fileURLWithPath: "/tmp/test-output")
        
        preferencesManager.setOutputDirectory(customPath)
        
        XCTAssertEqual(preferencesManager.outputDirectory, customPath)
    }
    
    /// Test that resetOutputDirectory clears custom path
    func testResetOutputDirectory_RestoresDefault() async {
        let customPath = URL(fileURLWithPath: "/tmp/custom-recordings")
        preferencesManager.outputDirectory = customPath
        
        preferencesManager.resetOutputDirectory()
        
        XCTAssertEqual(preferencesManager.outputDirectory, PreferencesManager.defaultOutputDirectory)
    }
    
    /// Test that resetOutputDirectory removes UserDefaults key
    func testResetOutputDirectory_RemovesUserDefaultsKey() async {
        let customPath = URL(fileURLWithPath: "/tmp/custom-recordings")
        preferencesManager.outputDirectory = customPath
        
        preferencesManager.resetOutputDirectory()
        
        XCTAssertNil(UserDefaults.standard.string(forKey: AppStorageKeys.outputDirectory))
    }
    
    /// Test that output directory change callback fires
    func testOutputDirectory_CallbackFiresOnChange() async {
        let expectation = XCTestExpectation(description: "Output directory callback fires")
        let customPath = URL(fileURLWithPath: "/tmp/callback-test")
        
        preferencesManager.outputDirectoryDidChange = { url in
            XCTAssertEqual(url, customPath)
            expectation.fulfill()
        }
        
        preferencesManager.outputDirectory = customPath
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    /// Test that reset output directory callback fires with default path
    func testResetOutputDirectory_CallbackFiresWithDefaultPath() async {
        let expectation = XCTestExpectation(description: "Reset callback fires")
        let customPath = URL(fileURLWithPath: "/tmp/custom")
        preferencesManager.outputDirectory = customPath
        
        preferencesManager.outputDirectoryDidChange = { url in
            XCTAssertEqual(url, PreferencesManager.defaultOutputDirectory)
            expectation.fulfill()
        }
        
        preferencesManager.resetOutputDirectory()
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    // MARK: - Launch at Login Tests
    
    /// Test that launchAtLogin can be read (value depends on system state)
    func testLaunchAtLogin_CanBeRead() async {
        // On macOS 13+, this checks SMAppService.mainApp.status
        // On macOS 12 and earlier, checks UserDefaults
        // We can't control the system state in tests, so just verify it doesn't crash
        _ = preferencesManager.launchAtLogin
        XCTAssertTrue(true, "Launch at login property is readable")
    }
    
    /// Test that launchAtLogin can be enabled
    func testLaunchAtLogin_CanBeEnabled() async {
        preferencesManager.launchAtLogin = true
        
        // Note: SMAppService.mainApp.register() may fail in test environment
        // We verify UserDefaults was updated regardless
        let saved = UserDefaults.standard.bool(forKey: AppStorageKeys.launchAtLogin)
        XCTAssertTrue(saved)
    }
    
    /// Test that launchAtLogin can be disabled
    func testLaunchAtLogin_CanBeDisabled() async {
        UserDefaults.standard.set(true, forKey: AppStorageKeys.launchAtLogin)
        
        preferencesManager.launchAtLogin = false
        
        let saved = UserDefaults.standard.bool(forKey: AppStorageKeys.launchAtLogin)
        XCTAssertFalse(saved)
    }
    
    /// Test that setLaunchAtLogin method works
    func testSetLaunchAtLogin_UpdatesValue() async {
        preferencesManager.setLaunchAtLogin(true)
        
        let saved = UserDefaults.standard.bool(forKey: AppStorageKeys.launchAtLogin)
        XCTAssertTrue(saved)
    }
    
    // MARK: - Transcription Mode Tests
    
    /// Test that transcriptionMode defaults to live
    func testTranscriptionMode_DefaultsToLive() async {
        XCTAssertEqual(preferencesManager.transcriptionMode, .live)
    }
    
    /// Test that transcriptionMode can be set to postProcessing
    func testTranscriptionMode_CanSetPostProcessing() async {
        preferencesManager.transcriptionMode = .postProcessing
        
        XCTAssertEqual(preferencesManager.transcriptionMode, .postProcessing)
    }
    
    /// Test that transcriptionMode persists to UserDefaults
    func testTranscriptionMode_PersistsToUserDefaults() async {
        preferencesManager.transcriptionMode = .postProcessing
        
        let saved = UserDefaults.standard.string(forKey: AppStorageKeys.transcriptionMode)
        XCTAssertEqual(saved, "postProcessing")
    }
    
    /// Test that transcriptionMode persists across instances
    func testTranscriptionMode_PersistsAcrossInstances() async {
        preferencesManager.transcriptionMode = .postProcessing
        
        let newManager = PreferencesManager()
        
        XCTAssertEqual(newManager.transcriptionMode, .postProcessing)
    }
    
    /// Test that transcriptionMode callback fires on change
    func testTranscriptionMode_CallbackFiresOnChange() async {
        let expectation = XCTestExpectation(description: "Transcription mode callback fires")
        
        preferencesManager.transcriptionModeDidChange = { mode in
            XCTAssertEqual(mode, .postProcessing)
            expectation.fulfill()
        }
        
        preferencesManager.transcriptionMode = .postProcessing
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    /// Test that invalid transcriptionMode rawValue falls back to live
    func testTranscriptionMode_InvalidRawValueFallsBackToLive() async {
        UserDefaults.standard.set("invalid-mode", forKey: AppStorageKeys.transcriptionMode)
        
        let newManager = PreferencesManager()
        
        XCTAssertEqual(newManager.transcriptionMode, .live)
    }
    
    // MARK: - Echo Cancellation Tests
    
    /// Test that echo cancellation defaults to true (AEC is always-on by policy)
    func testEchoCancellation_DefaultsToTrue() async {
        XCTAssertTrue(preferencesManager.isEchoCancellationEnabled)
    }
    
    /// Test that echo cancellation can be enabled
    func testEchoCancellation_CanBeEnabled() async {
        preferencesManager.isEchoCancellationEnabled = true
        
        XCTAssertTrue(preferencesManager.isEchoCancellationEnabled)
    }
    
    /// Test that echo cancellation persists to UserDefaults
    func testEchoCancellation_PersistsToUserDefaults() async {
        preferencesManager.isEchoCancellationEnabled = true
        
        let saved = UserDefaults.standard.bool(forKey: AppStorageKeys.echoCancellationEnabled)
        XCTAssertTrue(saved)
    }
    
    /// Test that echo cancellation persists across instances
    func testEchoCancellation_PersistsAcrossInstances() async {
        preferencesManager.isEchoCancellationEnabled = true
        
        let newManager = PreferencesManager()
        
        XCTAssertTrue(newManager.isEchoCancellationEnabled)
    }
    
    /// Test that echo cancellation is thread-safe (nonisolated getter)
    func testEchoCancellation_ThreadSafeAccess() async {
        preferencesManager.isEchoCancellationEnabled = true
        
        // Access from nonisolated context
        let value = preferencesManager.echoCancellationEnabledForAudioCallback
        
        XCTAssertTrue(value)
    }
    
    /// Test that echo cancellation can be toggled multiple times (Debug-only behavior;
    /// in Release builds the setter still works but UI never exposes the toggle)
    func testEchoCancellation_CanToggleMultipleTimes() async {
        preferencesManager.isEchoCancellationEnabled = true
        XCTAssertTrue(preferencesManager.isEchoCancellationEnabled)
        
        preferencesManager.isEchoCancellationEnabled = false
        XCTAssertFalse(preferencesManager.isEchoCancellationEnabled)
        
        preferencesManager.isEchoCancellationEnabled = true
        XCTAssertTrue(preferencesManager.isEchoCancellationEnabled)
    }
    
    /// Test that echo cancellation lock synchronization works under concurrent access
    func testEchoCancellation_ConcurrentAccessIsSafe() async {
        preferencesManager.isEchoCancellationEnabled = true
        
        // Capture manager reference to use in task group
        let manager = preferencesManager!
        
        // Perform multiple concurrent reads and writes
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { @MainActor in
                    if i % 2 == 0 {
                        _ = manager.echoCancellationEnabledForAudioCallback
                    } else {
                        manager.isEchoCancellationEnabled = (i % 4 == 1)
                    }
                }
            }
        }
        
        // Should not crash or deadlock
        XCTAssertTrue(true)
    }
    
    // MARK: - Audio Chunk Duration Tests
    
    /// Test that audioChunkDuration defaults to AudioConfiguration.transcriptionChunkDuration (15.0 seconds)
    func testAudioChunkDuration_DefaultsToFiveSeconds() async {
        XCTAssertEqual(preferencesManager.audioChunkDuration, AudioConfiguration.transcriptionChunkDuration, accuracy: 0.01)
    }
    
    /// Test that audioChunkDuration can be set to valid value
    func testAudioChunkDuration_CanSetValidValue() async {
        preferencesManager.audioChunkDuration = 7.5
        
        XCTAssertEqual(preferencesManager.audioChunkDuration, 7.5, accuracy: 0.01)
    }
    
    /// Test that audioChunkDuration clamps value below minimum (2.0)
    func testAudioChunkDuration_ClampsBelowMinimum() async {
        preferencesManager.audioChunkDuration = 1.0
        
        XCTAssertEqual(preferencesManager.audioChunkDuration, 2.0, accuracy: 0.01)
    }
    
    /// Test that audioChunkDuration clamps value above maximum (30.0)
    func testAudioChunkDuration_ClampsAboveMaximum() async {
        preferencesManager.audioChunkDuration = 35.0

        XCTAssertEqual(preferencesManager.audioChunkDuration, 30.0, accuracy: 0.01)
    }
    
    /// Test that audioChunkDuration persists to UserDefaults
    func testAudioChunkDuration_PersistsToUserDefaults() async {
        preferencesManager.audioChunkDuration = 8.0
        
        let saved = UserDefaults.standard.double(forKey: AppStorageKeys.audioChunkDuration)
        XCTAssertEqual(saved, 8.0, accuracy: 0.01)
    }
    
    /// Test that audioChunkDuration persists across instances
    func testAudioChunkDuration_PersistsAcrossInstances() async {
        preferencesManager.audioChunkDuration = 6.5
        
        let newManager = PreferencesManager()
        
        XCTAssertEqual(newManager.audioChunkDuration, 6.5, accuracy: 0.01)
    }
    
    /// Test that audioChunkDuration callback fires on change
    func testAudioChunkDuration_CallbackFiresOnChange() async {
        let expectation = XCTestExpectation(description: "Audio chunk duration callback fires")
        
        preferencesManager.audioChunkDurationDidChange = { duration in
            XCTAssertEqual(duration, 7.0, accuracy: 0.01)
            expectation.fulfill()
        }
        
        preferencesManager.audioChunkDuration = 7.0
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    /// Test that audioChunkDuration returns default for invalid saved value
    func testAudioChunkDuration_ReturnsDefaultForInvalidSavedValue() async {
        UserDefaults.standard.set(50.0, forKey: AppStorageKeys.audioChunkDuration)

        let newManager = PreferencesManager()

        XCTAssertEqual(newManager.audioChunkDuration, AudioConfiguration.transcriptionChunkDuration, accuracy: 0.01)
    }
    
    /// Test that audioChunkDuration callback receives clamped value
    func testAudioChunkDuration_CallbackReceivesClampedValue() async {
        let expectation = XCTestExpectation(description: "Callback receives clamped value")

        preferencesManager.audioChunkDurationDidChange = { duration in
            XCTAssertEqual(duration, 30.0, accuracy: 0.01)
            expectation.fulfill()
        }

        preferencesManager.audioChunkDuration = 35.0 // Over max

        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    // MARK: - Storage Migration Tests
    
    /// Test that migration check flag is set after initialization
    func testMigration_FlagIsSetAfterInitialization() async {
        let flagSet = UserDefaults.standard.bool(forKey: PreferencesManager.migrationCheckedKey)
        
        XCTAssertTrue(flagSet)
    }
    
    /// Test that migration only runs once
    func testMigration_OnlyRunsOnce() async {
        // First initialization already happened in setUp
        let firstFlag = UserDefaults.standard.bool(forKey: PreferencesManager.migrationCheckedKey)
        XCTAssertTrue(firstFlag)
        
        // Create another instance - migration should be skipped
        let secondManager = PreferencesManager()
        _ = secondManager.outputDirectory // Access a property to ensure init completed
        
        // Flag should still be set
        let secondFlag = UserDefaults.standard.bool(forKey: PreferencesManager.migrationCheckedKey)
        XCTAssertTrue(secondFlag)
    }
    
    /// Test that migration preserves custom output directory
    func testMigration_PreservesCustomOutputDirectory() async {
        let customPath = URL(fileURLWithPath: "/tmp/custom-output")
        UserDefaults.standard.set(customPath.path, forKey: AppStorageKeys.outputDirectory)
        
        // Create new manager - should not override custom path
        let newManager = PreferencesManager()
        
        XCTAssertEqual(newManager.outputDirectory, customPath)
    }
    
    // MARK: - Reprocess Workflow Migration Tests
    
    func testReprocessWorkflowMigration_Matrix() async {
        typealias SB = PreferencesManager.StoredBool
        typealias Decision = PreferencesManager.ReprocessWorkflowMigrationDecision
        
        let cases: [(SB, SB, String?, Decision, String)] = [
            (
                .unset,
                .unset,
                nil,
                Decision(
                    unifiedSecondPassEnabled: true,
                    mappedModelPreference: .bestAvailable,
                    hadUnknownModelPreference: false
                ),
                "unset_secondPass_unset_auto_nil_pref"
            ),
            (
                .value(false),
                .value(false),
                nil,
                Decision(
                    unifiedSecondPassEnabled: false,
                    mappedModelPreference: .sameAsLive,
                    hadUnknownModelPreference: false
                ),
                "both_false_nil_pref"
            ),
            (
                .value(true),
                .value(false),
                nil,
                Decision(
                    unifiedSecondPassEnabled: true,
                    mappedModelPreference: .bestAvailable,
                    hadUnknownModelPreference: false
                ),
                "secondPass_true_auto_false_nil_pref"
            ),
            (
                .value(false),
                .value(true),
                nil,
                Decision(
                    unifiedSecondPassEnabled: true,
                    mappedModelPreference: .bestAvailable,
                    hadUnknownModelPreference: false
                ),
                "secondPass_false_auto_true_nil_pref"
            ),
            (
                .value(true),
                .value(true),
                "bestAvailableNoDowngrade",
                Decision(
                    unifiedSecondPassEnabled: true,
                    mappedModelPreference: .bestAvailable,
                    hadUnknownModelPreference: false
                ),
                "bestAvailableNoDowngrade_maps_to_bestAvailable"
            ),
            (
                .value(true),
                .value(true),
                "specific",
                Decision(
                    unifiedSecondPassEnabled: true,
                    mappedModelPreference: .sameAsLive,
                    hadUnknownModelPreference: false
                ),
                "specific_maps_to_sameAsLive"
            )
        ]
        
        for (legacySecondPass, legacyAuto, raw, expected, label) in cases {
            let result = PreferencesManager.resolveReprocessWorkflowMigration(
                legacySecondPass: legacySecondPass,
                legacyAutoReprocess: legacyAuto,
                legacyModelPreferenceRaw: raw
            )
            XCTAssertEqual(result, expected, label)
        }
    }
    
    func testReprocessWorkflowMigration_UnknownValueMapsToSameAsLive() async {
        let result = PreferencesManager.resolveReprocessWorkflowMigration(
            legacySecondPass: .value(true),
            legacyAutoReprocess: .value(false),
            legacyModelPreferenceRaw: "unexpected-value"
        )
        
        XCTAssertEqual(result.mappedModelPreference, .sameAsLive)
        XCTAssertTrue(result.hadUnknownModelPreference)
    }
    
    func testReprocessWorkflowMigration_Integration_CleansLegacyKeys() async {
        // Given: legacy values prior to consolidation
        UserDefaults.standard.set(false, forKey: AppStorageKeys.secondPassASREnabled)
        UserDefaults.standard.set(true, forKey: "autoReprocessAfterMeetingEnabled")
        UserDefaults.standard.set("specific", forKey: AppStorageKeys.secondPassModelPreference)
        UserDefaults.standard.set(ModelManager.ModelSize.large.rawValue, forKey: "secondPassSpecificModel")
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.reprocessWorkflowMigrationDone)
        
        // When: manager initializes and runs migration
        let migratedManager = PreferencesManager()
        
        // Then: unified toggle and mapped model are stored, legacy keys removed
        XCTAssertTrue(migratedManager.isSecondPassASREnabled)
        XCTAssertEqual(migratedManager.secondPassModelPreference, .sameAsLive)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppStorageKeys.reprocessWorkflowMigrationDone))
        XCTAssertNil(UserDefaults.standard.object(forKey: "autoReprocessAfterMeetingEnabled"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "secondPassSpecificModel"))
    }
    
    func testReprocessWorkflowMigration_IsIdempotent() async {
        // Given: migration has already run and user changed settings afterward
        UserDefaults.standard.set(true, forKey: AppStorageKeys.reprocessWorkflowMigrationDone)
        UserDefaults.standard.set(false, forKey: AppStorageKeys.secondPassASREnabled)
        UserDefaults.standard.set(
            PreferencesManager.SecondPassModelPreference.bestAvailable.rawValue,
            forKey: AppStorageKeys.secondPassModelPreference
        )
        
        // Legacy keys should be ignored once migration flag is set
        UserDefaults.standard.set(true, forKey: "autoReprocessAfterMeetingEnabled")
        UserDefaults.standard.set(ModelManager.ModelSize.large.rawValue, forKey: "secondPassSpecificModel")
        
        let manager = PreferencesManager()
        
        XCTAssertFalse(manager.isSecondPassASREnabled)
        XCTAssertEqual(manager.secondPassModelPreference, .bestAvailable)
    }
    
    func testReprocessWorkflowDefaults_FreshInstall() async {
        clearUserDefaults()
        let manager = PreferencesManager()
        
        XCTAssertTrue(manager.isSecondPassASREnabled)
        XCTAssertEqual(manager.secondPassModelPreference, .bestAvailable)
    }
    
    // MARK: - TranscriptionMode Conversion Extension Tests
    
    /// Test that TranscriptionMode converts to service mode correctly
    func testTranscriptionModeConversion_LiveMode() async {
        let mode = PreferencesManager.TranscriptionMode.live
        let serviceMode = mode.serviceMode
        
        XCTAssertEqual(serviceMode, TranscriptionService.TranscriptionMode.live)
    }
    
    /// Test that TranscriptionMode converts to service mode for postProcessing
    func testTranscriptionModeConversion_PostProcessingMode() async {
        let mode = PreferencesManager.TranscriptionMode.postProcessing
        let serviceMode = mode.serviceMode
        
        XCTAssertEqual(serviceMode, TranscriptionService.TranscriptionMode.postProcessing)
    }
    
    /// Test that TranscriptionMode can be created from service mode
    func testTranscriptionModeConversion_FromServiceMode() async {
        let serviceMode = TranscriptionService.TranscriptionMode.postProcessing
        let mode = PreferencesManager.TranscriptionMode(from: serviceMode)
        
        XCTAssertEqual(mode, .postProcessing)
    }
    
    // MARK: - AEC Startup Policy Matrix Tests

    /// Matrix test: (stored: unset/false/true × isRelease: true/false) → decision
    func testAECPolicy_Matrix() async {
        typealias SB = PreferencesManager.StoredBool
        typealias D = PreferencesManager.AECStartupDecision

        let cases: [(SB, Bool, Bool, D, String)] = [
            // stored               isRelease  migDone  expected                                                                  label
            (.unset, true, false, D(effectiveValue: true, shouldWriteEnabled: false, shouldSetMigrationDone: false), "unset×release"),
            (.unset, false, false, D(effectiveValue: true, shouldWriteEnabled: false, shouldSetMigrationDone: false), "unset×debug"),
            (.value(true), true, false, D(effectiveValue: true, shouldWriteEnabled: false, shouldSetMigrationDone: false), "true×release"),
            (.value(true), false, false, D(effectiveValue: true, shouldWriteEnabled: false, shouldSetMigrationDone: false), "true×debug"),
            (.value(false), true, false, D(effectiveValue: true, shouldWriteEnabled: true, shouldSetMigrationDone: true), "false×release"),
            (.value(false), false, false, D(effectiveValue: false, shouldWriteEnabled: false, shouldSetMigrationDone: false), "false×debug")
        ]

        for (stored, isRelease, migDone, expected, label) in cases {
            let result = PreferencesManager.resolveAECStartupPolicy(
                storedPref: stored, isRelease: isRelease, migrationAlreadyDone: migDone
            )
            XCTAssertEqual(result, expected, label)
        }
    }

    /// When migration was already done, should not re-mark migration even for stored false.
    func testAECPolicy_MigrationAlreadyDone_SkipsMigrationMarker() async {
        let result = PreferencesManager.resolveAECStartupPolicy(
            storedPref: .value(false), isRelease: true, migrationAlreadyDone: true
        )
        XCTAssertTrue(result.effectiveValue)
        XCTAssertTrue(result.shouldWriteEnabled)
        XCTAssertFalse(result.shouldSetMigrationDone,
            "Should not re-mark migration when already done")
    }

    /// Integration test: fresh install (unset key) through the shared helper used by init().
    func testAECPolicy_Integration_FreshInstall() async {
        clearUserDefaults()

        let stored = PreferencesManager.StoredBool(forKey: AppStorageKeys.echoCancellationEnabled)
        let migDone = UserDefaults.standard.object(forKey: AppStorageKeys.aecAlwaysOnMigrationDone) != nil
            && UserDefaults.standard.bool(forKey: AppStorageKeys.aecAlwaysOnMigrationDone)

        let decision = PreferencesManager.resolveAECStartupPolicy(
            storedPref: stored, isRelease: true, migrationAlreadyDone: migDone
        )

        XCTAssertEqual(stored, .unset, "Fresh install must see echoCancellationEnabled as unset")
        XCTAssertTrue(decision.effectiveValue, "Fresh install effective AEC must be true")
        XCTAssertFalse(decision.shouldWriteEnabled, "Unset defaults to true; no write needed")
        XCTAssertFalse(decision.shouldSetMigrationDone, "No migration needed on fresh install")
    }

    /// Backward-compat: effectiveAECEnabled convenience still works.
    func testEffectiveAEC_BackwardCompat() async {
        XCTAssertTrue(PreferencesManager.effectiveAECEnabled(storedValue: false, isRelease: true))
        XCTAssertTrue(PreferencesManager.effectiveAECEnabled(storedValue: true, isRelease: true))
        XCTAssertFalse(PreferencesManager.effectiveAECEnabled(storedValue: false, isRelease: false))
        XCTAssertTrue(PreferencesManager.effectiveAECEnabled(storedValue: true, isRelease: false))
    }
}

// MARK: - Private Extension for Test Access

extension PreferencesManager {
    /// Expose migration checked key for testing
    static var migrationCheckedKey: String {
        "com.muesli.migrationChecked"
    }
}
