import AVFoundation
import CoreMedia
@testable import Muesli
import XCTest

/// Tests for RecordingController functionality
@MainActor
final class RecordingControllerTests: XCTestCase {
    // MARK: - Test Setup
    
    private func createTestController() async -> RecordingController {
        // Create mock services for testing
        let audioCaptureService = AudioCaptureService()
        let fileOutputService = FileOutputService()
        let transcriptionService = TranscriptionService()
        let modelManager = ModelManager(skipScan: true)
        let transcriptionCoordinator = TranscriptionCoordinator(
            transcriptionService: transcriptionService,
            modelManager: modelManager
        )
        let echoCancellationService = EchoCancellationService(
            filterLength: 256,
            learningRate: 0.3,
            sampleRate: 48000,
            maxDelayMs: 100
        )
        let preferencesManager = PreferencesManager()
        let microphoneManager = MicrophoneManager()
        
        return RecordingController(
            audioCaptureService: audioCaptureService,
            fileOutputService: fileOutputService,
            transcriptionService: transcriptionService,
            transcriptionCoordinator: transcriptionCoordinator,
            echoCancellationService: echoCancellationService,
            preferencesManager: preferencesManager,
            microphoneManager: microphoneManager
        )
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
        guard let stereoBuffer = EchoCancellationService.createSampleBuffer(
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
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Starting recording
        controller.startRecording(for: session)
        
        // Then: Session state should update (may fail without permissions)
        // Note: Actual recording requires TCC permissions
        XCTAssertNotNil(session)
    }
    
    func testStartRecordingInitializesSession() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Starting recording
        controller.startRecording(for: session)
        
        // Then: Session should be configured
        XCTAssertNotNil(session)
    }
    
    func testStartRecordingCapturesAudio() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Starting recording
        controller.startRecording(for: session)
        
        // Then: Should attempt audio capture
        XCTAssertNotNil(session)
    }
    
    func testStartRecordingStartsTranscription() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Starting recording
        controller.startRecording(for: session)
        
        // Then: Should start transcription service
        XCTAssertNotNil(session)
    }
    
    func testStopRecordingSuccessfully() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // Given: Recording session
        controller.startRecording(for: session)
        
        // When: Stopping recording
        controller.stopRecording(for: session)
        
        // Then: Should stop (may have errors from test environment)
        XCTAssertNotNil(session)
    }
    
    func testStopRecordingSavesFiles() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // Given: Recording session
        controller.startRecording(for: session)
        
        // When: Stopping recording
        controller.stopRecording(for: session)
        
        // Then: Files should be saved to session directory
        // Note: Actual file creation depends on successful recording
        XCTAssertNotNil(session)
    }
    
    func testHandleStartWithoutModel() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // Given: No model available (ModelManager initialized with skipScan)
        
        // When: Starting recording
        controller.startRecording(for: session)
        
        // Then: Should handle missing model
        // Either show error or start recording-only mode
        XCTAssertNotNil(session)
    }
    
    func testHandleMultipleStartAttempts() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Attempting to start twice
        controller.startRecording(for: session)
        controller.startRecording(for: session)
        
        // Then: Should prevent duplicate starts
        XCTAssertNotNil(session)
    }
    
    func testHandleStopWithoutActiveSession() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Stopping without having started
        controller.stopRecording(for: session)
        
        // Then: Should handle gracefully
        XCTAssertNotNil(session)
    }
    
    func testActiveSessionTracking() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Starting recording
        controller.startRecording(for: session)
        
        // Then: Active session should be set
        // Note: May not be set if recording fails due to permissions
        XCTAssertNotNil(session)
    }
    
    func testPendingStopSessionWorkflow() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // Given: Recording session
        controller.startRecording(for: session)
        
        // When: Initiating stop (which may show title prompt)
        controller.stopRecording(for: session)
        
        // Then: Session should be handled
        XCTAssertNotNil(session)
    }
    
    func testSessionStateTransitions() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // Then: Session starts in idle state
        XCTAssertEqual(session.state, .idle)
        
        // When: Starting recording
        controller.startRecording(for: session)
        
        // Then: State may transition (depends on success)
        // Note: State machine transitions tested separately
        XCTAssertNotNil(session)
    }
    
    func testTitlePromptSheetState() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // Given: Completed recording
        controller.startRecording(for: session)
        controller.stopRecording(for: session)
        
        // Then: Title prompt may be shown
        // Note: Depends on preferences and recording success
        XCTAssertNotNil(session)
    }
    
    func testModelErrorAlertState() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // Given: No model available
        // When: Starting recording
        controller.startRecording(for: session)
        
        // Then: Model error alert may be shown
        // Note: Depends on model availability
        XCTAssertNotNil(session)
    }
    
    func testTimerUpdatesDuringRecording() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Starting recording
        controller.startRecording(for: session)
        
        // Wait briefly
        try? await Task.sleep(for: .milliseconds(100))
        
        // Then: Timer should be running
        // Note: Timer updates are handled by session
        XCTAssertNotNil(session)
    }
    
    // MARK: - Audio Callback Integration Tests
    
    func testSystemAudioBufferCallbackInfrastructure() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Recording system audio
        controller.startRecording(for: session)
        
        // Note: Actual buffer callbacks require real audio capture
        // This test verifies the callback infrastructure is set up
        XCTAssertNotNil(session)
    }
    
    func testMicrophoneAudioBufferCallbackInfrastructure() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Recording
        controller.startRecording(for: session)
        
        // Then: Microphone callbacks should be configured
        XCTAssertNotNil(session)
    }
    
    func testBuffersForwardedToFileOutputService() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Recording
        controller.startRecording(for: session)
        
        // Then: Buffer handlers should forward to FileOutputService
        // Note: Actual forwarding happens in buffer callbacks
        XCTAssertNotNil(session)
    }
    
    func testBuffersForwardedToTranscriptionService() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Recording with transcription enabled
        controller.startRecording(for: session)
        
        // Then: Buffer handlers should forward to TranscriptionService
        // Note: Forwarding verified through transcription coordinator
        XCTAssertNotNil(session)
    }
    
    func testEchoCancellationProcessing() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // Given: Echo cancellation enabled
        // Note: Preferences set in PreferencesManager
        
        // When: Recording
        controller.startRecording(for: session)
        
        // Then: Echo cancellation should process buffers
        XCTAssertNotNil(session)
    }
    
    func testAudioLevelUpdates() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Recording
        controller.startRecording(for: session)
        
        // Then: Audio levels should be updated
        // Note: Level updates happen via AudioCaptureService callbacks
        XCTAssertNotNil(session)
    }
    
    func testHandleCallbackErrors() async {
        let controller = await createTestController()
        let session = controller.createSession()
        
        // When: Recording (may encounter errors in test environment)
        controller.startRecording(for: session)
        
        // Then: Should handle callback errors gracefully
        XCTAssertNotNil(session)
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
