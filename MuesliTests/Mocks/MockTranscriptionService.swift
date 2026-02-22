import Foundation
@testable import Muesli

/// Mock implementation of TranscriptionService for testing
final class MockTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    // MARK: - State
    
    var transcriptionMode: TranscriptionService.TranscriptionMode = .live
    private(set) var isInitialized: Bool = false
    private(set) var isTranscribing: Bool = false
    
    // MARK: - Test Control Properties
    
    var shouldFailInitialize: Bool = false
    var initializeError: Error = NSError(
        domain: "MockTranscriptionService",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Mock initialization error"]
    )
    var shouldFailPostProcessing: Bool = false
    var postProcessingError: Error = NSError(
        domain: "MockTranscriptionService",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Mock post-processing error"]
    )
    
    /// Simulated delay during initialization (for testing slow model loading)
    var initializationDelay: TimeInterval = 0
    
    // MARK: - Call Tracking
    
    var initializeCallCount: Int = 0
    var startTranscriptionCallCount: Int = 0
    var stopTranscriptionCallCount: Int = 0
    var appendSystemAudioCallCount: Int = 0
    var appendMicrophoneAudioCallCount: Int = 0
    var postProcessingCallCount: Int = 0
    var setTranscriptHandlerCallCount: Int = 0
    var setDraftHandlerCallCount: Int = 0
    var lastModelPath: URL?
    var lastRecordingStartTime: Date?
    
    // MARK: - Handlers
    
    private var transcriptHandler: TranscriptionService.TranscriptHandler?
    private var draftHandler: TranscriptionDraftHandler?
    
    // MARK: - TranscriptionServiceProtocol
    
    func initialize(modelPath: URL) async throws {
        initializeCallCount += 1
        lastModelPath = modelPath
        
        // Simulate initialization delay (for testing slow model loading)
        if initializationDelay > 0 {
            try await Task.sleep(for: .seconds(initializationDelay))
        }
        
        if shouldFailInitialize {
            throw initializeError
        }
        
        isInitialized = true
    }
    
    func setTranscriptionMode(_ mode: TranscriptionService.TranscriptionMode) {
        transcriptionMode = mode
    }
    
    func setTranscriptHandler(_ handler: @escaping TranscriptionService.TranscriptHandler) {
        setTranscriptHandlerCallCount += 1
        transcriptHandler = handler
    }
    
    func setDraftHandler(_ handler: @escaping TranscriptionDraftHandler) {
        setDraftHandlerCallCount += 1
        draftHandler = handler
    }
    
    func startTranscription(recordingStartTime: Date) {
        startTranscriptionCallCount += 1
        lastRecordingStartTime = recordingStartTime
        isTranscribing = true
    }
    
    func stopTranscription() async {
        stopTranscriptionCallCount += 1
        isTranscribing = false
    }
    
    func appendSystemAudio(_ samples: [Float]) {
        appendSystemAudioCallCount += 1
    }
    
    func appendMicrophoneAudio(_ samples: [Float]) {
        appendMicrophoneAudioCallCount += 1
    }
    
    func transcribePostProcessing(systemAudioURL: URL?, micAudioURL: URL?, startTime: Date) async throws {
        postProcessingCallCount += 1
        
        if shouldFailPostProcessing {
            throw postProcessingError
        }
    }
    
    // MARK: - Test Helpers
    
    /// Simulate a transcript segment being generated
    func simulateTranscriptSegment(_ segment: TranscriptionService.TranscriptSegment) {
        transcriptHandler?(segment)
    }
    
    /// Simulate a transcript segment being generated with default values
    func simulateTranscriptSegment() {
        let segment = TranscriptionService.TranscriptSegment(text: "Test segment", timestamp: 0.0, speaker: .me)
        transcriptHandler?(segment)
    }
    
    /// Simulate a transcript segment with given text and speaker
    func simulateTranscript(
        text: String,
        speaker: TranscriptionService.TranscriptSegment.Speaker,
        timestamp: TimeInterval = 0
    ) {
        let segment = TranscriptionService.TranscriptSegment(text: text, timestamp: timestamp, speaker: speaker)
        transcriptHandler?(segment)
    }

    /// Simulate a live draft update (as if the stabilizer emitted one)
    func simulateDraft(text: String, speaker: TranscriptionService.TranscriptSegment.Speaker) {
        draftHandler?(text, speaker)
    }
    
    /// Reset all state for next test
    func reset() {
        transcriptionMode = .live
        isInitialized = false
        isTranscribing = false
        shouldFailInitialize = false
        shouldFailPostProcessing = false
        initializationDelay = 0
        initializeCallCount = 0
        startTranscriptionCallCount = 0
        stopTranscriptionCallCount = 0
        appendSystemAudioCallCount = 0
        appendMicrophoneAudioCallCount = 0
        postProcessingCallCount = 0
        setTranscriptHandlerCallCount = 0
        lastModelPath = nil
        lastRecordingStartTime = nil
        transcriptHandler = nil
        draftHandler = nil
        setDraftHandlerCallCount = 0
    }
}
