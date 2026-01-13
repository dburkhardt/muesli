import XCTest
@testable import Muesli

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
                let _ = controller.isMicrophoneMutedSafe
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
    
    func testStartRecordingWithoutTranscriptionShowsError() async {
        let controller = await createTestController()
        
        let session = controller.createSession()
        controller.sessionPendingModelDecision = session
        controller.showModelErrorAlert = true
        
        controller.startRecordingWithoutTranscription()
        
        XCTAssertFalse(controller.showModelErrorAlert, "Should clear model error alert")
        XCTAssertNil(controller.sessionPendingModelDecision, "Should clear pending session")
        XCTAssertTrue(session.showError, "Session should show error")
        XCTAssertNotNil(session.errorMessage, "Session should have error message")
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
}

// MARK: - Thread Safety Tests for ViewModel

@MainActor
final class ViewModelThreadSafetyTests: XCTestCase {
    
    func testMicrophoneMutedLockIsThreadSafe() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Access from multiple threads should not crash
        let expectation = XCTestExpectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = 10
        
        for _ in 0..<10 {
            Task.detached {
                // Access the nonisolated property from a background thread
                let _ = viewModel.isMicrophoneMutedSafe
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
    }
}

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
                let _ = manager.echoCancellationEnabledForAudioCallback
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
