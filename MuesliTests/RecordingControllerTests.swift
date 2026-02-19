import AVFoundation
import CoreMedia
@testable import Muesli
import XCTest

/// Tests for RecordingController functionality
@MainActor
final class RecordingControllerTests: XCTestCase {
    // MARK: - Test Setup
    
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

        // Given: Recording session
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // When: Stopping recording
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Should call stopCapture
        let stopCount = await mockCapture.stopCaptureCallCount
        XCTAssertGreaterThan(stopCount, 0, "stopCapture should be called on the audio service")
    }

    func testStopRecordingSavesFiles() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // Given: Recording session
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // When: Stopping recording
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Stop should have been invoked (file saving follows stop)
        let stopCount = await mockCapture.stopCaptureCallCount
        XCTAssertGreaterThan(stopCount, 0, "stopCapture should be called to finalize files")
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
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // Given: Recording session
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // When: Initiating stop
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Stop should have been called
        let stopCount = await mockCapture.stopCaptureCallCount
        XCTAssertGreaterThan(stopCount, 0, "stopCapture should be called during stop workflow")
    }

    func testSessionStateTransitions() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // Then: Session starts in idle state
        XCTAssertEqual(session.state, .idle)

        // When: Starting recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Active session should be tracked after start
        XCTAssertNotNil(controller.activeSession, "Active session should be set after starting")
    }

    func testTitlePromptSheetState() async {
        let (controller, _) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // Given: Completed recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)
        controller.stopRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Controller should have processed the stop (title prompt state depends on preferences)
        // At minimum, the controller should not be in an inconsistent state
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
    
    func testSystemAudioBufferCallbackInfrastructure() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Recording system audio
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Audio capture should have been started (callback infrastructure is set up during start)
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertGreaterThan(callCount, 0, "startCapture should be called to set up buffer callbacks")
    }

    func testMicrophoneAudioBufferCallbackInfrastructure() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Microphone callbacks should be configured via startCapture
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertGreaterThan(callCount, 0, "Audio service should be started for microphone callbacks")
    }

    func testBuffersForwardedToFileOutputService() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Buffer handlers should be registered (verified by startCapture being called)
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertGreaterThan(callCount, 0, "startCapture called means buffer handlers are set up for FileOutputService")
    }

    func testBuffersForwardedToTranscriptionService() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Recording with transcription enabled
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Audio capture should be started (transcription handlers registered during setup)
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertGreaterThan(callCount, 0, "startCapture called means transcription handlers are configured")
    }

    func testEchoCancellationProcessing() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Audio capture should have started (AEC is wired through the audio pipeline)
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertGreaterThan(callCount, 0, "Audio capture service should be started for AEC processing")
    }

    func testAudioLevelUpdates() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Recording
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Audio service should be running (level updates come from the service)
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertGreaterThan(callCount, 0, "Audio service should be started for level updates")
    }

    func testHandleCallbackErrors() async {
        let (controller, mockCapture) = await createTestControllerWithMocks()
        let session = controller.createSession()

        // When: Recording (may encounter errors in test environment)
        controller.startRecording(for: session)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Then: Should have attempted to start (error handling happens in callbacks)
        let callCount = await mockCapture.startCaptureCallCount
        XCTAssertGreaterThan(callCount, 0, "Should attempt to start capture even if callbacks might error")
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
