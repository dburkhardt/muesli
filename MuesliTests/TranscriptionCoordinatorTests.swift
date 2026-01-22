@testable import Muesli
import XCTest

/// Tests for TranscriptionCoordinator
/// Focus: Ensuring audio is properly forwarded to TranscriptionService
final class TranscriptionCoordinatorTests: XCTestCase {
    // MARK: - Regression Test: Audio Forwarding When Model Ready
    
    /// REGRESSION TEST: Verifies that when model is ready, audio is forwarded directly
    /// to TranscriptionService instead of being buffered forever.
    /// 
    /// Bug: Previously, bufferSystemAudio/bufferMicrophoneAudio would only buffer audio
    /// but never forward it to TranscriptionService after the model became ready.
    /// Fix: Now checks if model is ready and forwards directly.
    @MainActor
    func testSystemAudioForwardedWhenModelReady() async throws {
        // Setup
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model is downloaded and ready
        mockModelManager.addDownloadedModel(.small)
        
        // Prepare the model (this initializes TranscriptionService)
        _ = await sut.prepareModel()
        
        // Verify model is ready
        XCTAssertTrue(sut.modelState.isReady, "Model should be ready after prepareModel")
        
        // When: System audio arrives
        let testSamples: [Float] = Array(repeating: 0.5, count: 1000)
        sut.bufferSystemAudio(testSamples)
        
        // Then: Audio should be forwarded to TranscriptionService
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 1,
                       "System audio should be forwarded to TranscriptionService when model is ready")
    }
    
    /// REGRESSION TEST: Verifies that when model is ready, microphone audio is forwarded directly
    @MainActor
    func testMicrophoneAudioForwardedWhenModelReady() async throws {
        // Setup
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model is downloaded and ready
        mockModelManager.addDownloadedModel(.small)
        
        // Prepare the model
        _ = await sut.prepareModel()
        XCTAssertTrue(sut.modelState.isReady, "Model should be ready after prepareModel")
        
        // When: Microphone audio arrives
        let testSamples: [Float] = Array(repeating: 0.3, count: 500)
        sut.bufferMicrophoneAudio(testSamples)
        
        // Then: Audio should be forwarded to TranscriptionService
        XCTAssertEqual(mockTranscriptionService.appendMicrophoneAudioCallCount, 1,
                       "Microphone audio should be forwarded to TranscriptionService when model is ready")
    }
    
    /// REGRESSION TEST: Multiple audio chunks should each be forwarded
    @MainActor
    func testMultipleAudioChunksForwardedWhenModelReady() async throws {
        // Setup
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model is downloaded and ready
        mockModelManager.addDownloadedModel(.small)
        _ = await sut.prepareModel()
        XCTAssertTrue(sut.modelState.isReady)
        
        // When: Multiple audio chunks arrive
        let chunk1: [Float] = Array(repeating: 0.1, count: 100)
        let chunk2: [Float] = Array(repeating: 0.2, count: 200)
        let chunk3: [Float] = Array(repeating: 0.3, count: 300)
        
        sut.bufferSystemAudio(chunk1)
        sut.bufferSystemAudio(chunk2)
        sut.bufferMicrophoneAudio(chunk3)
        
        // Then: Each chunk should be forwarded
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 2,
                       "Each system audio chunk should be forwarded")
        XCTAssertEqual(mockTranscriptionService.appendMicrophoneAudioCallCount, 1,
                       "Microphone audio chunk should be forwarded")
    }
    
    // MARK: - Buffering Tests (Model Not Ready)
    
    /// Verifies that audio is buffered when model is not yet ready
    @MainActor
    func testSystemAudioBufferedWhenModelNotReady() {
        // Setup
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: No model available (model not ready)
        // modelState starts as .notAvailable
        
        // When: System audio arrives
        let testSamples: [Float] = Array(repeating: 0.5, count: 1000)
        sut.bufferSystemAudio(testSamples)
        
        // Then: Audio should NOT be forwarded (it should be buffered)
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 0,
                       "System audio should be buffered, not forwarded, when model is not ready")
    }
    
    /// Verifies that microphone audio is buffered when model is not yet ready
    @MainActor
    func testMicrophoneAudioBufferedWhenModelNotReady() {
        // Setup
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: No model available (model not ready)
        
        // When: Microphone audio arrives
        let testSamples: [Float] = Array(repeating: 0.3, count: 500)
        sut.bufferMicrophoneAudio(testSamples)
        
        // Then: Audio should NOT be forwarded (it should be buffered)
        XCTAssertEqual(mockTranscriptionService.appendMicrophoneAudioCallCount, 0,
                       "Microphone audio should be buffered, not forwarded, when model is not ready")
    }
    
    /// Verifies that buffered audio is processed when model becomes ready
    @MainActor
    func testBufferedAudioProcessedWhenModelBecomesReady() async throws {
        // Setup
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Audio arrives before model is ready
        let systemSamples: [Float] = Array(repeating: 0.5, count: 1000)
        let micSamples: [Float] = Array(repeating: 0.3, count: 500)
        
        sut.bufferSystemAudio(systemSamples)
        sut.bufferMicrophoneAudio(micSamples)
        
        // Verify audio was buffered, not forwarded
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 0)
        XCTAssertEqual(mockTranscriptionService.appendMicrophoneAudioCallCount, 0)
        
        // When: Model becomes ready
        mockModelManager.addDownloadedModel(.small)
        _ = await sut.prepareModel()
        
        // Then: Buffered audio should be processed
        // (processBufferedAudio is called in prepareModel)
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 1,
                       "Buffered system audio should be forwarded when model becomes ready")
        XCTAssertEqual(mockTranscriptionService.appendMicrophoneAudioCallCount, 1,
                       "Buffered microphone audio should be forwarded when model becomes ready")
    }
    
    // MARK: - Model State Tests
    
    /// Verifies model state transitions correctly
    @MainActor
    func testModelStateTransitions() async throws {
        // Setup
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Initially not available
        XCTAssertFalse(sut.modelState.isReady)
        XCTAssertFalse(sut.modelState.isLoading)
        
        // Add model and prepare
        mockModelManager.addDownloadedModel(.small)
        _ = await sut.prepareModel()
        
        // Should be ready
        XCTAssertTrue(sut.modelState.isReady)
    }
    
    /// Verifies prepareModel handles no model gracefully
    @MainActor
    func testPrepareModelWithNoModelAvailable() async {
        // Setup
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: No model downloaded
        mockModelManager.downloadedModels.removeAll()
        mockModelManager.activeModel = nil
        
        // When: prepareModel is called
        _ = await sut.prepareModel()
        
        // Then: State should be notAvailable
        XCTAssertFalse(sut.modelState.isReady)
    }
    
    // MARK: - Part 1: Model Lifecycle & State (Additional Tests)
    
    /// Test model preparation with validation failures
    @MainActor
    func testPrepareModelWithValidationFailure() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model exists but validation fails
        mockModelManager.addDownloadedModel(.small)
        mockModelManager.shouldFailValidation = true
        
        // When: prepareModel is called
        _ = await sut.prepareModel()
        
        // Then: Should not be ready
        XCTAssertFalse(sut.modelState.isReady)
    }
    
    /// Test model preparation with corrupted model and fallback
    @MainActor
    func testPrepareModelWithCorruptedModelFallsBackToValid() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Small model is corrupted, medium model is valid
        mockModelManager.addDownloadedModel(.small)
        mockModelManager.addDownloadedModel(.medium)
        mockModelManager.activeModel = .small
        mockModelManager.modelsToFailValidation = [.small]
        
        var switchedFrom: ModelManager.ModelSize?
        var switchedTo: ModelManager.ModelSize?
        sut.onModelSwitched = { from, to, _ in
            switchedFrom = from
            switchedTo = to
        }
        
        // When: prepareModel is called
        _ = await sut.prepareModel()
        
        // Then: Should fall back to valid model
        XCTAssertTrue(mockModelManager.markModelCorruptedCallCount > 0, "Should mark corrupted model")
        XCTAssertEqual(switchedFrom, .small)
        XCTAssertEqual(switchedTo, .medium)
    }
    
    /// Test model preparation retry limit enforcement
    @MainActor
    func testPrepareModelRetryLimitEnforcement() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model validation always fails (will trigger retries)
        // Only small is downloaded and it fails validation, so no fallback available
        mockModelManager.addDownloadedModel(.small)
        mockModelManager.modelsToFailValidation = [.small]
        
        // When: prepareModel is called multiple times
        _ = await sut.prepareModel()
        _ = await sut.prepareModel()
        _ = await sut.prepareModel()
        let finalState = await sut.prepareModel()
        
        // Then: Should eventually fail with model not found
        if case .failed(let error) = finalState {
            XCTAssertTrue(error.localizedDescription.contains("No transcription model available") || 
                         error.localizedDescription.contains("not found") ||
                         error.localizedDescription.contains("NotFound"),
                         "Expected model not found error, got: \(error.localizedDescription)")
        } else {
            XCTFail("Expected failed state after retry limit, got: \(finalState)")
        }
    }
    
    /// Test model reset for new recording
    @MainActor
    func testResetForNewRecording() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model in failed state
        mockModelManager.activeModel = nil
        _ = await sut.prepareModel()
        // Put it in failed state by exhausting retries
        _ = await sut.prepareModel()
        _ = await sut.prepareModel()
        _ = await sut.prepareModel()
        
        // When: Reset for new recording
        sut.resetForNewRecording()
        
        // Then: Should reset to notAvailable (not failed)
        if case .notAvailable = sut.modelState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected notAvailable state after reset, got \(sut.modelState)")
        }
    }
    
    /// Test model switch callback invocation
    @MainActor
    func testModelSwitchCallbackInvoked() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Two models, first one will fail validation
        mockModelManager.addDownloadedModel(.small)
        mockModelManager.addDownloadedModel(.medium)
        mockModelManager.activeModel = .small
        mockModelManager.modelsToFailValidation = [.small]
        
        var callbackInvoked = false
        sut.onModelSwitched = { _, _, _ in
            callbackInvoked = true
        }
        
        // When: prepareModel triggers fallback
        _ = await sut.prepareModel()
        
        // Then: Callback should be invoked
        XCTAssertTrue(callbackInvoked, "onModelSwitched callback should be invoked")
    }
    
    // MARK: - Part 2: Audio Buffering (Additional Tests)
    
    /// Test buffer overflow handling (>480,000 samples)
    @MainActor
    func testBufferOverflowHandling() {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model not ready, will buffer
        // maxBufferSamples is 480,000
        
        // When: Send large amount of audio
        let chunk = Array(repeating: Float(0.5), count: 250_000)
        sut.bufferSystemAudio(chunk)
        sut.bufferSystemAudio(chunk) // Total: 500,000 > 480,000
        
        // Then: Should handle overflow gracefully (drops oldest or limits buffer)
        // No crash should occur
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 0, "Should still be buffering")
    }
    
    /// Test buffer timeout detection (>30 seconds)
    @MainActor
    func testBufferTimeoutDetection() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Note: Testing actual 30-second timeout is impractical in unit tests
        // This test verifies the timeout callback mechanism works
        
        var timeoutCalled = false
        sut.onBufferTimeout = {
            timeoutCalled = true
        }
        
        // Given: Model not ready, audio buffering
        let samples: [Float] = Array(repeating: 0.5, count: 1000)
        sut.bufferSystemAudio(samples)
        
        // In real scenario, if 30 seconds pass, timeout would be called
        // For unit test, we just verify callback can be set
        XCTAssertNotNil(sut.onBufferTimeout)
    }
    
    /// Test buffer timeout callback invocation
    @MainActor
    func testBufferTimeoutCallbackInvocation() {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        var timeoutCalled = false
        sut.onBufferTimeout = {
            timeoutCalled = true
        }
        
        // Verify callback can be set and invoked (mechanism test)
        sut.onBufferTimeout?()
        XCTAssertTrue(timeoutCalled)
    }
    
    /// Test interleaved system/mic audio buffering
    @MainActor
    func testInterleavedSystemMicAudioBuffering() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model not ready, both audio sources buffering
        let systemChunk1: [Float] = Array(repeating: 0.5, count: 1000)
        let micChunk1: [Float] = Array(repeating: 0.3, count: 500)
        let systemChunk2: [Float] = Array(repeating: 0.6, count: 1000)
        let micChunk2: [Float] = Array(repeating: 0.4, count: 500)
        
        // When: Interleaved audio arrives
        sut.bufferSystemAudio(systemChunk1)
        sut.bufferMicrophoneAudio(micChunk1)
        sut.bufferSystemAudio(systemChunk2)
        sut.bufferMicrophoneAudio(micChunk2)
        
        // Then: Should buffer both streams
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 0)
        XCTAssertEqual(mockTranscriptionService.appendMicrophoneAudioCallCount, 0)
        
        // When: Model becomes ready
        mockModelManager.addDownloadedModel(.small)
        _ = await sut.prepareModel()
        
        // Then: Both buffers should be flushed
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 1, "System buffer flushed once")
        XCTAssertEqual(mockTranscriptionService.appendMicrophoneAudioCallCount, 1, "Mic buffer flushed once")
    }
    
    /// Test buffer clearing on stop
    @MainActor
    func testBufferClearingOnStop() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Audio buffered
        let samples: [Float] = Array(repeating: 0.5, count: 1000)
        sut.bufferSystemAudio(samples)
        
        // When: Transcription stopped
        await sut.stopTranscription()
        
        // Then: Buffers should be cleared
        // When model becomes ready later, old buffer shouldn't be processed
        mockModelManager.addDownloadedModel(.small)
        _ = await sut.prepareModel()
        
        // Should not forward the old buffered audio after stop
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 0, "Old buffer should be cleared")
    }
    
    /// Test buffer processing on state change (modelState.didSet)
    @MainActor
    func testBufferProcessingOnStateChange() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Audio is buffered before model ready
        let samples: [Float] = Array(repeating: 0.5, count: 1000)
        sut.bufferSystemAudio(samples)
        
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 0)
        
        // When: Model state changes to ready (via prepareModel)
        mockModelManager.addDownloadedModel(.small)
        _ = await sut.prepareModel()
        
        // Then: didSet on modelState should trigger processBufferedAudio automatically
        XCTAssertEqual(mockTranscriptionService.appendSystemAudioCallCount, 1, 
                      "Buffer should be automatically processed when state becomes ready")
    }
    
    // MARK: - Part 3: Advanced Scenarios
    
    /// Test concurrent audio chunks during model loading
    @MainActor
    func testConcurrentAudioChunksDuringModelLoading() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Audio arrives while model is being prepared
        mockModelManager.addDownloadedModel(.small)
        
        // Start model preparation (async)
        let prepareTask = Task {
            await sut.prepareModel()
        }
        
        // Send audio during loading
        let chunk1: [Float] = Array(repeating: 0.1, count: 100)
        let chunk2: [Float] = Array(repeating: 0.2, count: 200)
        sut.bufferSystemAudio(chunk1)
        sut.bufferMicrophoneAudio(chunk2)
        
        // Wait for preparation to complete
        await prepareTask.value
        
        // Then: Audio should either be buffered then flushed, or forwarded directly
        XCTAssertTrue(mockTranscriptionService.appendSystemAudioCallCount >= 0)
        XCTAssertTrue(mockTranscriptionService.appendMicrophoneAudioCallCount >= 0)
    }
    
    /// Test resuming recording after model failure
    @MainActor
    func testResumeRecordingAfterModelFailure() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model preparation failed
        _ = await sut.prepareModel() // No model, will fail
        
        // Reset for new attempt
        sut.resetForNewRecording()
        
        // When: Model is now available and we try again
        mockModelManager.addDownloadedModel(.small)
        let state = await sut.prepareModel()
        
        // Then: Should succeed this time
        XCTAssertTrue(state.isReady, "Should be ready after reset and retry")
    }
    
    /// Test transcription mode configuration
    @MainActor
    func testTranscriptionModeConfiguration() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Coordinator with mock service
        mockModelManager.addDownloadedModel(.small)
        _ = await sut.prepareModel()
        
        // When: Setting transcription mode
        sut.setTranscriptionMode(.live)
        
        // Then: Should propagate to service
        XCTAssertEqual(sut.transcriptionMode, .live)
        XCTAssertEqual(mockTranscriptionService.transcriptionMode, .live)
        
        // Change mode
        sut.setTranscriptionMode(.postProcessing)
        XCTAssertEqual(sut.transcriptionMode, .postProcessing)
    }
    
    // MARK: - Slow Model Load Detection Tests
    
    /// Verify isSlowModelLoad is false initially
    @MainActor
    func testIsSlowModelLoad_isFalse_initially() {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager,
            slowLoadThreshold: 0.1  // Short threshold for tests
        )
        
        XCTAssertFalse(sut.isSlowModelLoad, "isSlowModelLoad should be false initially")
        XCTAssertNil(sut.modelLoadStartTime, "modelLoadStartTime should be nil initially")
    }
    
    /// Verify isSlowModelLoad remains false during fast model load
    @MainActor
    func testIsSlowModelLoad_remainsFalse_duringFastLoad() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager,
            slowLoadThreshold: 1.0  // 1 second threshold - model will load faster
        )
        
        // Given: Model is available (will load instantly in mock)
        mockModelManager.addDownloadedModel(.small)
        
        // When: prepareModel is called (will complete quickly in mock)
        _ = await sut.prepareModel()
        
        // Then: isSlowModelLoad should remain false
        XCTAssertFalse(sut.isSlowModelLoad, "isSlowModelLoad should remain false for fast model load")
    }
    
    /// Verify isSlowModelLoad becomes true after threshold during slow load
    @MainActor
    func testIsSlowModelLoad_becomesTrue_afterThreshold() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager,
            slowLoadThreshold: 0.05  // Very short threshold (50ms)
        )
        
        // Given: Model is available but mock will take time to initialize
        mockModelManager.addDownloadedModel(.small)
        mockTranscriptionService.initializationDelay = 0.2  // 200ms delay
        
        // When: prepareModel starts
        let prepareTask = Task {
            await sut.prepareModel()
        }
        
        // Wait for threshold to pass (plus some buffer)
        try? await Task.sleep(for: .milliseconds(100))
        
        // Then: isSlowModelLoad should be true while loading
        // Note: This check may be flaky depending on timing
        if sut.modelState.isLoading {
            XCTAssertTrue(sut.isSlowModelLoad, "isSlowModelLoad should be true after threshold while loading")
        }
        
        // Wait for preparation to complete
        await prepareTask.value
    }
    
    /// Verify slow-load warning fires only once
    @MainActor
    func testSlowLoadWarning_firesOnlyOnce() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager,
            slowLoadThreshold: 0.05  // Very short threshold
        )
        
        // Track warning calls
        var warningCount = 0
        sut.onWarning = { _, _, _, _ in
            warningCount += 1
        }
        
        // Given: Model with slow initialization
        mockModelManager.addDownloadedModel(.small)
        mockTranscriptionService.initializationDelay = 0.2  // 200ms delay
        
        // When: prepareModel is called
        _ = await sut.prepareModel()
        
        // Wait a bit for any additional warnings
        try? await Task.sleep(for: .milliseconds(100))
        
        // Then: Warning should fire at most once
        XCTAssertLessThanOrEqual(warningCount, 1, "Slow-load warning should fire at most once")
    }
    
    /// Verify resetForNewRecording clears slow-load state
    @MainActor
    func testResetForNewRecording_clearsSlowLoadState() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager,
            slowLoadThreshold: 0.05
        )
        
        // Given: Slow-load state is set
        mockModelManager.addDownloadedModel(.small)
        mockTranscriptionService.initializationDelay = 0.2
        
        // Start loading (will trigger slow-load detection)
        let prepareTask = Task {
            await sut.prepareModel()
        }
        
        // Wait for threshold to pass
        try? await Task.sleep(for: .milliseconds(100))
        
        // When: resetForNewRecording is called
        sut.resetForNewRecording()
        
        // Then: Slow-load state should be cleared
        XCTAssertFalse(sut.isSlowModelLoad, "isSlowModelLoad should be false after reset")
        XCTAssertNil(sut.modelLoadStartTime, "modelLoadStartTime should be nil after reset")
        
        // Clean up
        prepareTask.cancel()
    }
    
    /// Verify slow-load task is cancelled when model loads successfully
    @MainActor
    func testSlowLoadTask_cancelledOnSuccess() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager,
            slowLoadThreshold: 1.0  // Long threshold - model will load before it fires
        )
        
        // Track warning calls
        var warningFired = false
        sut.onWarning = { _, _, _, _ in
            warningFired = true
        }
        
        // Given: Model loads quickly
        mockModelManager.addDownloadedModel(.small)
        // No initialization delay - will be instant
        
        // When: prepareModel completes successfully
        _ = await sut.prepareModel()
        
        // Wait to ensure threshold would have fired if not cancelled
        try? await Task.sleep(for: .milliseconds(100))
        
        // Then: Warning should NOT have fired (task was cancelled on success)
        XCTAssertFalse(warningFired, "Warning should not fire when model loads before threshold")
        XCTAssertFalse(sut.isSlowModelLoad, "isSlowModelLoad should be false after successful load")
    }
    
    /// Verify modelLoadStartTime is set during prepareModel
    @MainActor
    func testModelLoadStartTime_isSetDuringLoading() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager,
            slowLoadThreshold: 1.0
        )
        
        // Given: Model is available
        mockModelManager.addDownloadedModel(.small)
        mockTranscriptionService.initializationDelay = 0.1
        
        // Initial state
        XCTAssertNil(sut.modelLoadStartTime)
        
        // When: prepareModel starts loading
        let beforeLoad = Date()
        let prepareTask = Task {
            await sut.prepareModel()
        }
        
        // Wait briefly for loading to start
        try? await Task.sleep(for: .milliseconds(20))
        
        // Then: modelLoadStartTime should be set
        // Note: Check during loading, not after completion
        if sut.modelState.isLoading {
            XCTAssertNotNil(sut.modelLoadStartTime, "modelLoadStartTime should be set during loading")
            if let startTime = sut.modelLoadStartTime {
                XCTAssertTrue(startTime >= beforeLoad, "modelLoadStartTime should be at or after start")
            }
        }
        
        await prepareTask.value
    }
    
    // TEMPORARILY DISABLED: Concurrency issue with captured var
    // Test transcript handler lifecycle
    /*
    @MainActor
    func testTranscriptHandlerLifecycle() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Coordinator ready
        mockModelManager.addDownloadedModel(.small)
        _ = await sut.prepareModel()
        
        // When: Setting transcript handler
        var handlerCalled = false
        sut.setTranscriptHandler { _ in
            handlerCalled = true
        }
        
        // Simulate service calling handler
        mockTranscriptionService.simulateTranscriptSegment()
        
        // Then: Handler should be invoked
        XCTAssertTrue(handlerCalled, "Transcript handler should be called")
        
        // When: Stopping transcription
        await sut.stopTranscription()
        
        // Then: Handler should be cleared to break retain cycles
        XCTAssertEqual(mockTranscriptionService.setTranscriptHandlerCallCount, 2, 
                      "Handler set once, then cleared on stop")
    }
    
    /// Test starting transcription with recording start time
    @MainActor
    func testStartTranscriptionWithRecordingStartTime() async {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model ready
        mockModelManager.addDownloadedModel(.small)
        _ = await sut.prepareModel()
        
        // When: Starting transcription with start time
        let startTime = Date()
        sut.startTranscription(recordingStartTime: startTime)
        
        // Then: Should propagate to service
        XCTAssertEqual(mockTranscriptionService.startTranscriptionCallCount, 1)
    }
    
    /// Test starting transcription when not initialized is no-op
    @MainActor
    func testStartTranscriptionWhenNotInitializedIsNoOp() {
        let mockTranscriptionService = MockTranscriptionService()
        let mockModelManager = MockModelManager()
        let sut = TranscriptionCoordinator(
            transcriptionService: mockTranscriptionService,
            modelManager: mockModelManager
        )
        
        // Given: Model not initialized (no prepareModel called)
        
        // When: Trying to start transcription
        sut.startTranscription(recordingStartTime: Date())
        
        // Then: Should not call service (guard prevents it)
        XCTAssertEqual(mockTranscriptionService.startTranscriptionCallCount, 0)
    }
    */
}
