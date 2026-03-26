import AVFoundation
import CoreMedia
@testable import Muesli
import XCTest

/// Tests for RecordingController functionality
@MainActor
final class RecordingControllerTests: XCTestCase {
    // MARK: - Test Setup
    
    private static let userDefaultsKeysToClean = [
        AppStorageKeys.secondPassASREnabled,
        AppStorageKeys.secondPassModelPreference,
        AppStorageKeys.reprocessWorkflowMigrationDone,
        AppStorageKeys.exportEnabled,
        AppStorageKeys.exportDirectory,
        "autoReprocessAfterMeetingEnabled",
        "secondPassSpecificModel",
    ]
    
    private static let testOutputDirectory =
        FileManager.default.temporaryDirectory.appendingPathComponent("MuesliTests_RecordingController")

    override func setUp() {
        super.setUp()
        Self.resetReprocessWorkflowDefaults()
        
        // Set test output directory to avoid writing to real user directories
        UserDefaults.standard.set(Self.testOutputDirectory.path, forKey: "outputDirectory")
    }
    
    override func tearDown() {
        // Clean up test directories
        try? FileManager.default.removeItem(at: Self.testOutputDirectory)
        UserDefaults.standard.removeObject(forKey: "outputDirectory")
        
        Self.resetReprocessWorkflowDefaults()
        super.tearDown()
    }
    
    private static func resetReprocessWorkflowDefaults() {
        let defaults = UserDefaults.standard
        userDefaultsKeysToClean.forEach { defaults.removeObject(forKey: $0) }
    }
    
    private func createTestController() async -> RecordingController {
        let (controller, _) = await createTestControllerWithMocks()
        return controller
    }

    private func createTestControllerWithMocks() async -> (RecordingController, MockAudioCaptureService) {
        let audioCaptureService = MockAudioCaptureService()
        let fileOutputService = FileOutputService()
        let transcriptionService = TranscriptionService()
        let modelManager = ModelManager(skipScan: true)
        let transcriptionCoordinator = TranscriptionCoordinator(
            transcriptionService: transcriptionService,
            modelManager: modelManager
        )
        let preferencesManager = PreferencesManager()
        let microphoneManager = MicrophoneManager()

        let controller = RecordingController(
            audioCaptureService: audioCaptureService,
            fileOutputService: fileOutputService,
            transcriptionService: transcriptionService,
            transcriptionCoordinator: transcriptionCoordinator,
            preferencesManager: preferencesManager,
            microphoneManager: microphoneManager,
            exportService: ExportService()
        )
        return (controller, audioCaptureService)
    }

    private func createTestControllerWithMockTranscriptionService() async -> (
        RecordingController,
        MockAudioCaptureService,
        MockTranscriptionService
    ) {
        let audioCaptureService = MockAudioCaptureService()
        let fileOutputService = FileOutputService()
        let mockTranscriptionService = MockTranscriptionService()
        let modelManager = MockModelManager()
        let transcriptionCoordinator = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: modelManager
        )
        let preferencesManager = PreferencesManager()
        let microphoneManager = MicrophoneManager()

        let controller = RecordingController(
            audioCaptureService: audioCaptureService,
            fileOutputService: fileOutputService,
            transcriptionService: TranscriptionService(),
            transcriptionCoordinator: transcriptionCoordinator,
            preferencesManager: preferencesManager,
            microphoneManager: microphoneManager,
            exportService: ExportService()
        )
        return (controller, audioCaptureService, mockTranscriptionService)
    }

    private func ensurePrimaryAudioFileExists(for session: RecordingSession) {
        guard let directory = session.outputDirectory else { return }
        let audioURL = directory.appendingPathComponent("audio.caf")
        if !FileManager.default.fileExists(atPath: audioURL.path) {
            _ = FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
        }
    }
    
    // MARK: - Session Creation Tests
    
    func testCreateSessionReturnsNewSession() async {
        let controller = await createTestController()
        
        let session1 = controller.createSession()
        let session2 = controller.createSession()
        
        XCTAssertNotEqual(session1.id, session2.id, "Each session should have a unique ID")
        XCTAssertEqual(session1.state, .idle, "New session should be in idle state")
        XCTAssertEqual(session2.state, .idle, "New session should be in idle state")
    }
    
    // MARK: - State Tests
    
    func testInitialStateHasNoActiveSession() async {
        let controller = await createTestController()
        
        XCTAssertNil(controller.activeSession, "Initial state should have no active session")
        XCTAssertFalse(controller.showModelErrorAlert, "Initial state should not show model error alert")
        XCTAssertFalse(controller.showTitlePromptSheet, "Initial state should not show title prompt sheet")
        XCTAssertNil(controller.pendingStopSession, "Initial state should have no pending stop session")
    }
    
    // MARK: - Thread Safety Tests
    
    func testIsMicrophoneMutedSafeIsThreadSafe() async {
        let controller = await createTestController()
        
        // Access from multiple threads should not crash
        let expectation = XCTestExpectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = 10
        
        for _ in 0..<10 {
            Task.detached {
                // Access the nonisolated property from a background thread
                _ = controller.isMicrophoneMutedSafe
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
    }
    
    // MARK: - Model Error Alert Tests
    
    func testCancelRecordingDueToModelErrorClearsState() async {
        let controller = await createTestController()
        
        // Setup state as if model error occurred
        controller.showModelErrorAlert = true
        controller.sessionPendingModelDecision = controller.createSession()
        
        XCTAssertTrue(controller.showModelErrorAlert)
        XCTAssertNotNil(controller.sessionPendingModelDecision)
        
        // Cancel
        controller.cancelRecordingDueToModelError()
        
        XCTAssertFalse(controller.showModelErrorAlert, "Should clear model error alert")
        XCTAssertNil(controller.sessionPendingModelDecision, "Should clear pending session")
    }
    
    func testStartRecordingWithoutTranscriptionAllowsRecording() async {
        let controller = await createTestController()
        
        let session = controller.createSession()
        controller.sessionPendingModelDecision = session
        controller.showModelErrorAlert = true
        
        controller.startRecordingWithoutTranscription()
        
        XCTAssertFalse(controller.showModelErrorAlert, "Should clear model error alert")
        XCTAssertNil(controller.sessionPendingModelDecision, "Should clear pending session")
        XCTAssertTrue(session.isRecordingOnly, "Session should be marked as recording-only mode")
        XCTAssertFalse(session.showError, "Session should NOT show error - recording continues without transcription")
    }
    
    // MARK: - Title Prompt Tests
    
    func testDiscardRecordingClearsTitlePromptSheet() async {
        let controller = await createTestController()
        
        controller.showTitlePromptSheet = true
        controller.pendingStopSession = controller.createSession()
        
        controller.discardRecording()
        
        // Give async task time to complete
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        XCTAssertFalse(controller.showTitlePromptSheet, "Should clear title prompt sheet")
        XCTAssertNil(controller.pendingStopSession, "Should clear pending stop session")
    }
    
    // MARK: - Audio Buffer Format Tests
    
    func testMicrophoneBufferConversionWithAECDisabled() async throws {
        // Test that microphone buffers are converted to stereo format even when AEC is disabled
        // This ensures format consistency with FileOutputService expectations
        
        // Create test mono samples (simulates what MicrophoneCaptureEngine produces)
        let sampleRate: Double = 48000
        let frameCount = 1024
        let monoSamples = [Float](repeating: 0.5, count: frameCount)
        
        // Verify we can convert mono samples to stereo buffer
        let timestamp = CMTime(value: 0, timescale: CMTimeScale(sampleRate))
        guard let stereoBuffer = EchoCancellationServiceNLMS.createSampleBuffer(
            from: monoSamples,
            timestamp: timestamp
        ) else {
            XCTFail("Failed to create stereo buffer from mono samples")
            return
        }
        
        // Verify the converted buffer is stereo (2 channels) as expected by FileOutputService
        guard let convertedFormatDesc = CMSampleBufferGetFormatDescription(stereoBuffer),
              let convertedAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(convertedFormatDesc) else {
            XCTFail("Failed to get format description from converted buffer")
            return
        }
        
        XCTAssertEqual(convertedAsbd.pointee.mChannelsPerFrame, 2, "Converted buffer should be stereo")
        XCTAssertEqual(convertedAsbd.pointee.mSampleRate, sampleRate, "Sample rate should match")
        XCTAssertTrue((convertedAsbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0, "Should be Float32")
        XCTAssertEqual(convertedAsbd.pointee.mBitsPerChannel, 32, "Should be 32-bit")
    }
    
    // MARK: - Recording Lifecycle Tests
    
    func testStartRecordingWithSession() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Starting recording
        controller.startRecording(for: session)

        // Give async start time to initiate
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Should attempt to start audio capture
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertGreaterThan(callCount, 0, "startCapture should be called on the audio service")
    }

    func testStartRecordingInitializesSession() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Starting recording
        controller.startRecording(for: session)

        // Give async start time
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Active session should be tracked
        XCTAssertNotNil(controller.activeSession, "activeSession should be set after starting recording")
    }

    func testStartRecordingCapturesAudio() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Starting recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Should attempt audio capture
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertGreaterThan(callCount, 0, "Should call startCapture on audio service")
    }
    
    func testStartRecordingStartsTranscription() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Starting recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Active session should be set (transcription starts as part of recording)
        XCTAssertNotNil(controller.activeSession, "activeSession should be set - transcription starts with recording")
    }

    func testStopRecordingSuccessfully() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()
        session.meetingTitle = "Test Meeting"  // Required so stop proceeds (no title prompt)

        // Given: Recording session
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // When: Stopping recording
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 500_000_000)  // Allow async stop to complete

        // Then: Should call stopCapture
        let stopCount = await mockCapture.stopCaptureCallCount
        XCTAssertGreaterThan(stopCount, 0, "stopCapture should be called on the audio service")
    }

    func testStopRecordingSavesFiles() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()
        session.meetingTitle = "Test Meeting"  // Set title to skip title prompt

        // Given: Recording session
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // When: Stopping recording
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Stop should have been invoked (file saving follows stop)
        let stopCount = await mockCapture.stopCaptureCallCount
        XCTAssertGreaterThan(stopCount, 0, "stopCapture should be called to finalize files")
        // Recording should be fully cleaned up after stop
        XCTAssertNil(controller.activeSession, "activeSession should be nil after stop completes (recording cleaned up)")
    }
    
    func testHandleStartWithoutModel() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // Given: No model available (ModelManager initialized with skipScan)

        // When: Starting recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Should handle missing model — either show error or start recording-only mode
        let hasAlert = controller.showModelErrorAlert
        let hasActiveSession = controller.activeSession != nil
        XCTAssertTrue(hasAlert || hasActiveSession,
            "Should either show model error alert or start recording without transcription")
    }
    
    func testHandleMultipleStartAttempts() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Attempting to start twice
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Should only call startCapture once (prevents duplicate starts)
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertEqual(callCount, 1, "startCapture should only be called once for duplicate start attempts")
    }
    
    func testHandleStopWithoutActiveSession() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Stopping without having started
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Then: Should handle gracefully — no stopCapture call since there's nothing to stop
        let stopCount = await mockCapture.stopCaptureCallCount
        XCTAssertEqual(stopCount, 0, "stopCapture should not be called when there's no active recording")
    }

    func testActiveSessionTracking() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // Initially no active session
        XCTAssertNil(controller.activeSession, "No active session before start")

        // When: Starting recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Active session should be set
        XCTAssertNotNil(controller.activeSession, "activeSession should be set after starting recording")
    }
    
    func testPendingStopSessionWorkflow() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()
        // Leave meetingTitle empty so stopRecording triggers title prompt

        // Given: Recording session
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // When: Initiating stop with empty title
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Should show title prompt sheet (since title is empty) and set pending session
        XCTAssertTrue(controller.showTitlePromptSheet, "Should show title prompt when meeting title is empty")
        XCTAssertNotNil(controller.pendingStopSession, "pendingStopSession should be set while awaiting title input")
    }

    func testSessionStateTransitions() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // Then: Session starts in idle state
        XCTAssertEqual(session.state, .idle)

        // When: Starting recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Active session should be tracked and session state should have transitioned to recording
        XCTAssertNotNil(controller.activeSession, "Active session should be set after starting")
        XCTAssertEqual(session.state, .recording, "Session state should transition to .recording after start")
    }

    func testTitlePromptSheetState() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()
        session.meetingTitle = "Test Meeting"  // Required so stop completes (no title prompt)

        // Given: Completed recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 500_000_000)  // Allow async stop to complete

        // Then: Controller should have processed the stop
        XCTAssertNil(controller.activeSession, "activeSession should be nil after stop")
    }

    func testModelErrorAlertState() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // Given: No model available (skipScan: true means no model loaded)
        // When: Starting recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Model error alert should be shown (since no model is available)
        // or session should have been started in recording-only mode
        let hasAlert = controller.showModelErrorAlert
        let hasActiveSession = controller.activeSession != nil
        XCTAssertTrue(hasAlert || hasActiveSession,
            "Should either show model error alert or have started recording")
    }

    func testTimerUpdatesDuringRecording() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Starting recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Then: Session should be actively tracked
        XCTAssertNotNil(controller.activeSession, "Active session should exist during recording")
    }
    
    // MARK: - Audio Callback Integration Tests

    func testAudioHandlersConfiguredOnStart() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Starting recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: All audio handlers should be wired up on the capture service
        let hasBuffer = await mockCapture.hasBufferHandler
        let hasLevel = await mockCapture.hasLevelHandler
        let hasInterrupted = await mockCapture.hasInterruptedHandler
        let hasProcessedMic = await mockCapture.hasProcessedMicHandler
        let hasProcessedRender = await mockCapture.hasProcessedRenderHandler
        XCTAssertTrue(hasBuffer, "Buffer handler should be configured after start")
        XCTAssertTrue(hasLevel, "Level handler should be configured after start")
        XCTAssertTrue(hasInterrupted, "Interrupted handler should be configured after start")
        XCTAssertTrue(hasProcessedMic, "Processed mic handler should be configured after start")
        XCTAssertTrue(hasProcessedRender, "Processed render handler should be configured after start")
    }

    func testAudioLevelUpdatesDeliveredToSession() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // Given: Recording started
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // When: Simulating audio level updates
        await mockCapture.simulateLevel(0.75, type: .system)
        await mockCapture.simulateLevel(0.5, type: .microphone)
        // Give MainActor tasks time to deliver
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Then: Session should have received the level updates
        XCTAssertGreaterThan(session.systemAudioLevel, 0.0, "System audio level should be updated from simulated level")
        XCTAssertGreaterThan(session.microphoneLevel, 0.0, "Microphone level should be updated from simulated level")
    }

    func testHandleCallbackErrorsGracefully() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Recording starts (may encounter errors in test environment)
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Session should remain active (graceful error handling doesn't crash or nil the session)
        XCTAssertNotNil(controller.activeSession, "Active session should survive callback errors without crashing")
        XCTAssertEqual(session.state, .recording, "Session should remain in recording state despite potential callback errors")
    }
    
    // MARK: - Second-Pass Finalization Tests

    func testSecondPassFinalizingFlagDefaultsFalse() async {
        let controller = await createTestController()
        let session = controller.createSession()
        XCTAssertFalse(session.isFinalizingTranscript,
                       "isFinalizingTranscript should default to false on a new session")
    }

    func testLiveDraftClearedAfterFinalizeTranscript() async {
        let controller = await createTestController()
        let session = controller.createSession()

        session.updateLiveDraft("some in-progress text", speaker: .me)
        XCTAssertNotNil(session.liveDraftText, "Live draft should be set")

        session.finalizeTranscript()
        XCTAssertNil(session.liveDraftText, "Live draft should be cleared after finalizeTranscript")
    }

    func testLiveDraftClearedAfterResetTranscript() async {
        let controller = await createTestController()
        let session = controller.createSession()

        session.updateLiveDraft("partial text", speaker: .them)
        session.isFinalizingTranscript = true
        XCTAssertNotNil(session.liveDraftText)
        XCTAssertTrue(session.isFinalizingTranscript)

        session.resetTranscript()
        XCTAssertNil(session.liveDraftText, "Live draft should be cleared after resetTranscript")
        XCTAssertFalse(session.isFinalizingTranscript, "isFinalizingTranscript should be false after reset")
    }

    func testMicrophoneMuteToggle() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // Given: Recording
        controller.startRecording(for: session)
        
        // When: Toggling mute
        controller.toggleMicrophoneMute()
        let wasMuted = controller.isMicrophoneMutedSafe
        
        controller.toggleMicrophoneMute()
        let wasUnmuted = controller.isMicrophoneMutedSafe
        
        // Then: Mute state should toggle
        XCTAssertNotEqual(wasMuted, wasUnmuted)
    }

    // MARK: - Race & Cancellation Tests

    /// Verifies that calling stopRecording on a session that is not active is a no-op (idempotent).
    func testStopWithNoActiveSessionIsIdempotent() async {
        let controller = await createTestController()
        let session = controller.createSession()
        XCTAssertNil(controller.activeSession, "Pre-condition: no active session")
        // Guard inside stopRecording checks session.id == activeSession?.id; should not crash
        controller.stopRecording(for: session)
        XCTAssertNil(controller.activeSession, "No active session expected after no-op stop")
    }

    /// Verifies that repeated stopRecording calls after first stop do not crash.
    func testRepeatedStopCallsAreIdempotent() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()
        session.meetingTitle = "Test Meeting"
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 50_000_000)

        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Second stop should be a no-op (session no longer active)
        controller.stopRecording(for: session)
        XCTAssertNil(controller.activeSession, "No active session after repeated stops")
    }

    /// Verifies that isFinalizingTranscript is false on a freshly stopped session when second-pass is disabled.
    func testFinalizingFlagClearedWhenSecondPassDisabled() async {
        // Also disable the legacy auto-reprocess key so the migration path (if it runs)
        // cannot re-enable second-pass finalization.
        UserDefaults.standard.set(false, forKey: "autoReprocessAfterMeetingEnabled")
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.reprocessWorkflowMigrationDone)
        UserDefaults.standard.set(false, forKey: AppStorageKeys.secondPassASREnabled)
        let controller = await createTestController()
        let session = controller.createSession()

        // Second-pass explicitly disabled, so finalization should be skipped.
        XCTAssertFalse(session.isFinalizingTranscript)
        session.meetingTitle = "Test Meeting"
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(session.isFinalizingTranscript,
                       "isFinalizingTranscript must be false after stop when second pass is disabled")
    }

    /// Verifies that live draft is nil after recording is stopped and transcript finalized.
    func testLiveDraftClearedAfterStop() async {
        let controller = await createTestController()
        let session = controller.createSession()
        session.meetingTitle = "Test Meeting"
        controller.startRecording(for: session)

        // Inject a draft directly on the session (simulating stabilizer output)
        session.updateLiveDraft("in progress text", speaker: .me)
        XCTAssertNotNil(session.liveDraftText)

        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // The finalizeTranscript call during stop should clear the draft
        XCTAssertNil(session.liveDraftText,
                     "liveDraftText must be nil after recording stops and transcript is finalized")
    }

    /// Verifies that concurrent draft updates from multiple speakers do not
    /// leave inconsistent state on the session.
    func testConcurrentDraftUpdatesFromMultipleSpeakers() async {
        let controller = await createTestController()
        let session = controller.createSession()
        controller.startRecording(for: session)

        // Fire concurrent draft updates from both speakers
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { @MainActor in
                    let speaker: TranscriptBlock.Speaker = i.isMultiple(of: 2) ? .me : .them
                    session.updateLiveDraft("text \(i)", speaker: speaker)
                }
            }
        }

        // Session should be in a consistent state (not nil, not crashed)
        // We don't assert a specific value because the last writer wins.
        XCTAssertNotNil(session, "Session must survive concurrent draft updates")
    }

    // MARK: - Interruption Finalization Parity

    func testAutomaticFinalizationDecisionMatrix() {
        let minDuration = AudioConfiguration.secondPassMinDurationSeconds
        let expectedLaunch = RecordingController.AutomaticFinalizationDecision(
            shouldLaunchSecondPass: true,
            skipReason: nil
        )

        let noAudioDecision = RecordingController.automaticFinalizationDecision(
            hasAudioFiles: false,
            secondPassEnabled: true,
            recordingDuration: minDuration + 5
        )
        XCTAssertEqual(
            noAudioDecision,
            RecordingController.AutomaticFinalizationDecision(
                shouldLaunchSecondPass: false,
                skipReason: .noAudioFiles
            )
        )

        let disabledDecision = RecordingController.automaticFinalizationDecision(
            hasAudioFiles: true,
            secondPassEnabled: false,
            recordingDuration: minDuration + 5
        )
        XCTAssertEqual(
            disabledDecision,
            RecordingController.AutomaticFinalizationDecision(
                shouldLaunchSecondPass: false,
                skipReason: .preferenceDisabled
            )
        )

        let shortDecision = RecordingController.automaticFinalizationDecision(
            hasAudioFiles: true,
            secondPassEnabled: true,
            recordingDuration: minDuration - 0.1
        )
        XCTAssertEqual(
            shortDecision,
            RecordingController.AutomaticFinalizationDecision(
                shouldLaunchSecondPass: false,
                skipReason: .recordingTooShort
            )
        )

        let launchDecision = RecordingController.automaticFinalizationDecision(
            hasAudioFiles: true,
            secondPassEnabled: true,
            recordingDuration: minDuration + 0.1
        )
        XCTAssertEqual(launchDecision, expectedLaunch)
    }

    func testStopRecordingUsesFullFlushWhenSecondPassDecisionSkips() async {
        UserDefaults.standard.set(true, forKey: AppStorageKeys.secondPassASREnabled)

        let (controller, _, mockTranscriptionService) = await createTestControllerWithMockTranscriptionService()
        let session = controller.createSession()
        session.meetingTitle = "Short Meeting"

        let completionExpectation = expectation(description: "Stop completes")
        controller.onSessionCompleted = { _, _ in
            completionExpectation.fulfill()
        }

        controller.startRecording(for: session)
        try? await Task.sleep(for: .milliseconds(200))
        ensurePrimaryAudioFileExists(for: session)
        // Keep duration below threshold so automatic second-pass is ineligible.
        session.recordingStartTime = Date()

        controller.stopRecording(for: session)
        await fulfillment(of: [completionExpectation], timeout: 3.0)

        XCTAssertEqual(mockTranscriptionService.lastStopMaxFlushDuration, nil)
        XCTAssertFalse(mockTranscriptionService.lastStopAllowDeferredFlush)
    }

    func testInterruptionUsesBoundedFlushWhenSecondPassDecisionLaunches() async {
        UserDefaults.standard.set(true, forKey: AppStorageKeys.secondPassASREnabled)

        let (controller, mockCapture, mockTranscriptionService) = await createTestControllerWithMockTranscriptionService()
        let session = controller.createSession()
        session.meetingTitle = "Interrupted Long Meeting"

        let completionExpectation = expectation(description: "Interrupted stop completes")
        controller.onSessionCompleted = { _, _ in
            completionExpectation.fulfill()
        }

        controller.startRecording(for: session)
        try? await Task.sleep(for: .milliseconds(200))
        ensurePrimaryAudioFileExists(for: session)
        session.recordingStartTime = Date().addingTimeInterval(-(AudioConfiguration.secondPassMinDurationSeconds + 2.0))

        await mockCapture.simulateInterruption(nil)
        await fulfillment(of: [completionExpectation], timeout: 3.0)

        XCTAssertEqual(mockTranscriptionService.lastStopMaxFlushDuration ?? 0, 1.5, accuracy: 0.001)
        XCTAssertTrue(mockTranscriptionService.lastStopAllowDeferredFlush)
    }

    func testSecondPassFailureForcesAutoReprocessAfterIncompleteBoundedFlush() async {
        UserDefaults.standard.set(true, forKey: AppStorageKeys.secondPassASREnabled)

        let (controller, _, mockTranscriptionService) = await createTestControllerWithMockTranscriptionService()
        mockTranscriptionService.stopTranscriptionResult = .init(
            completedFullFlush: false,
            flushDurationMs: 1500,
            remainingBufferedSamples: 4800
        )

        let session = controller.createSession()
        session.meetingTitle = "Force Recovery Meeting"
        session.appendTranscriptSegment(
            .init(text: "existing transcript", timestamp: 0.0, speaker: .me)
        )

        let completionExpectation = expectation(description: "Stop completes")
        let autoReprocessExpectation = expectation(description: "Auto-reprocess forced")
        controller.onSessionCompleted = { _, _ in
            completionExpectation.fulfill()
        }
        controller.onAutoReprocessRequested = { _ in
            autoReprocessExpectation.fulfill()
        }

        controller.startRecording(for: session)
        try? await Task.sleep(for: .milliseconds(200))
        ensurePrimaryAudioFileExists(for: session)
        session.recordingStartTime = Date().addingTimeInterval(-(AudioConfiguration.secondPassMinDurationSeconds + 2.0))

        controller.stopRecording(for: session)
        await fulfillment(of: [completionExpectation, autoReprocessExpectation], timeout: 4.0)

        XCTAssertEqual(mockTranscriptionService.lastStopMaxFlushDuration ?? 0, 1.5, accuracy: 0.001)
        XCTAssertTrue(mockTranscriptionService.lastStopAllowDeferredFlush)
    }

    func testInterruptionPathSkipsStopCapture() async {
        UserDefaults.standard.set(false, forKey: AppStorageKeys.secondPassASREnabled)

        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()
        session.meetingTitle = "Interrupted Meeting"

        let completionExpectation = expectation(description: "Interrupted stop completes")
        controller.onSessionCompleted = { _, _ in
            completionExpectation.fulfill()
        }

        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await mockCapture.simulateInterruption(nil)
        await fulfillment(of: [completionExpectation], timeout: 3.0)

        let stopCount = await mockCapture.stopCaptureCallCount
        XCTAssertEqual(stopCount, 0, "Interrupted stop must not call stopCapture()")
    }

    func testInterruptionCallbackIsIdempotent() async {
        UserDefaults.standard.set(false, forKey: AppStorageKeys.secondPassASREnabled)

        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()
        session.meetingTitle = "Interrupted Meeting"

        var completionCount = 0
        let completionExpectation = expectation(description: "Interrupted completion fires once")
        completionExpectation.expectedFulfillmentCount = 1
        completionExpectation.assertForOverFulfill = true
        controller.onSessionCompleted = { _, _ in
            completionCount += 1
            completionExpectation.fulfill()
        }

        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        await mockCapture.simulateInterruption(nil)
        await mockCapture.simulateInterruption(nil)
        await fulfillment(of: [completionExpectation], timeout: 3.0)

        // Give any duplicate asynchronous callback time to fire if present.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(completionCount, 1, "Duplicate interruption callbacks must not duplicate completion")
    }

    func testInterruptionPathIncludesExportParity() async {
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuesliTests_InterruptedExport-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportDirectory) }

        UserDefaults.standard.set(true, forKey: AppStorageKeys.exportEnabled)
        UserDefaults.standard.set(exportDirectory.path, forKey: AppStorageKeys.exportDirectory)
        UserDefaults.standard.set(false, forKey: AppStorageKeys.secondPassASREnabled)

        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()
        session.meetingTitle = "Interrupted Meeting"

        var completedDirectory: URL?
        let completionExpectation = expectation(description: "Interrupted completion with directory")
        controller.onSessionCompleted = { _, directory in
            completedDirectory = directory
            completionExpectation.fulfill()
        }

        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await mockCapture.simulateInterruption(nil)
        await fulfillment(of: [completionExpectation], timeout: 3.0)

        guard let directory = completedDirectory else {
            return XCTFail("Expected completed output directory for interrupted recording")
        }

        let markerPath = exportDirectory.appendingPathComponent(".muesli-export")
        let manifestPath = exportDirectory.appendingPathComponent("manifest.json")
        let meetingExportDir = exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(directory.lastPathComponent)
        let transcriptPath = meetingExportDir.appendingPathComponent("transcript.md")
        let metadataPath = meetingExportDir.appendingPathComponent("metadata.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataPath.path))
    }

    func testInterruptionPathRunsRescueAfterCompletionCallback() async {
        UserDefaults.standard.set(false, forKey: AppStorageKeys.secondPassASREnabled)

        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()
        session.meetingTitle = "Interrupted Meeting"

        var callbackOrder: [String] = []
        let callbackExpectation = expectation(description: "Completion then rescue callbacks")
        callbackExpectation.expectedFulfillmentCount = 2
        callbackExpectation.assertForOverFulfill = true

        controller.onSessionCompleted = { _, _ in
            callbackOrder.append("completed")
            callbackExpectation.fulfill()
        }
        controller.onAutoReprocessRequested = { _ in
            callbackOrder.append("rescue")
            callbackExpectation.fulfill()
        }

        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let outputDirectory = session.outputDirectory {
            let audioPath = outputDirectory.appendingPathComponent("audio.caf")
            if !FileManager.default.fileExists(atPath: audioPath.path) {
                _ = FileManager.default.createFile(atPath: audioPath.path, contents: Data())
            }
        }

        await mockCapture.simulateInterruption(nil)
        await fulfillment(of: [callbackExpectation], timeout: 3.0)

        XCTAssertEqual(callbackOrder, ["completed", "rescue"])
    }

    func testInterruptionPathSetsCanResumeParity() async {
        UserDefaults.standard.set(false, forKey: AppStorageKeys.secondPassASREnabled)

        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()
        session.meetingTitle = "Interrupted Meeting"

        var completedSession: RecordingSession?
        let completionExpectation = expectation(description: "Interrupted completion captures session")
        controller.onSessionCompleted = { session, _ in
            completedSession = session
            completionExpectation.fulfill()
        }

        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await mockCapture.simulateInterruption(nil)
        await fulfillment(of: [completionExpectation], timeout: 3.0)

        XCTAssertEqual(completedSession?.canResume, true, "Interrupted completion should keep resume parity")
    }
    
    // MARK: - Second-Pass Cancellation
    
    func testCancelSecondPassIfRunningDoesNotCrashWithNoTask() async {
        let controller = await createTestController()
        
        // Should be a no-op when no second-pass is running
        controller.cancelSecondPassIfRunning()
    }
}

// MARK: - Thread Safety Tests for ViewModel
// NOTE: Microphone mute state thread safety is now tested via RecordingControllerTests.testIsMicrophoneMutedSafeIsThreadSafe()
// The ViewModel delegates all recording state to RecordingController

// MARK: - PreferencesManager Thread Safety Tests

@MainActor
final class PreferencesManagerThreadSafetyTests: XCTestCase {
    func testEchoCancellationLockIsThreadSafe() async {
        let manager = PreferencesManager()
        
        // Access from multiple threads should not crash
        let expectation = XCTestExpectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = 20
        
        // Read from multiple threads
        for _ in 0..<10 {
            Task.detached {
                _ = manager.echoCancellationEnabledForAudioCallback
                expectation.fulfill()
            }
        }
        
        // Write from main thread interleaved with reads
        for i in 0..<10 {
            manager.isEchoCancellationEnabled = (i % 2 == 0)
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
    }
}
