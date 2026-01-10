import Foundation
@testable import Muesli_vmr

/// Mock implementation of TranscriptionService for testing
final class MockTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    
    // MARK: - State
    
    var transcriptionMode: TranscriptionService.TranscriptionMode = .live
    private(set) var isInitialized: Bool = false
    private(set) var isTranscribing: Bool = false
    
    // MARK: - Test Control Properties
    
    var shouldFailInitialize: Bool = false
    var initializeError: Error = NSError(domain: "MockTranscriptionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock initialization error"])
    var shouldFailPostProcessing: Bool = false
    var postProcessingError: Error = NSError(domain: "MockTranscriptionService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mock post-processing error"])
    
    // MARK: - Call Tracking
    
    var initializeCallCount: Int = 0
    var startTranscriptionCallCount: Int = 0
    var stopTranscriptionCallCount: Int = 0
    var appendSystemAudioCallCount: Int = 0
    var appendMicrophoneAudioCallCount: Int = 0
    var postProcessingCallCount: Int = 0
    var lastModelPath: URL?
    var lastRecordingStartTime: Date?
    
    // MARK: - Handlers
    
    private var transcriptHandler: TranscriptionService.TranscriptHandler?
    
    // MARK: - TranscriptionServiceProtocol
    
    func initialize(modelPath: URL) async throws {
        initializeCallCount += 1
        lastModelPath = modelPath
        
        if shouldFailInitialize {
            throw initializeError
        }
        
        isInitialized = true
    }
    
    func setTranscriptionMode(_ mode: TranscriptionService.TranscriptionMode) {
        transcriptionMode = mode
    }
    
    func setTranscriptHandler(_ handler: @escaping TranscriptionService.TranscriptHandler) {
        transcriptHandler = handler
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
    
    /// Simulate a transcript segment with given text and speaker
    func simulateTranscript(text: String, speaker: TranscriptionService.TranscriptSegment.Speaker, timestamp: TimeInterval = 0) {
        let segment = TranscriptionService.TranscriptSegment(text: text, timestamp: timestamp, speaker: speaker)
        transcriptHandler?(segment)
    }
    
    /// Reset all state for next test
    func reset() {
        transcriptionMode = .live
        isInitialized = false
        isTranscribing = false
        shouldFailInitialize = false
        shouldFailPostProcessing = false
        initializeCallCount = 0
        startTranscriptionCallCount = 0
        stopTranscriptionCallCount = 0
        appendSystemAudioCallCount = 0
        appendMicrophoneAudioCallCount = 0
        postProcessingCallCount = 0
        lastModelPath = nil
        lastRecordingStartTime = nil
        transcriptHandler = nil
    }
}
