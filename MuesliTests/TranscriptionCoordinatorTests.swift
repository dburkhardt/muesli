import XCTest
@testable import Muesli

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
        mockModelManager.addDownloadedModel(.base)
        
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
        mockModelManager.addDownloadedModel(.base)
        
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
        mockModelManager.addDownloadedModel(.base)
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
        mockModelManager.addDownloadedModel(.base)
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
        mockModelManager.addDownloadedModel(.base)
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
}
