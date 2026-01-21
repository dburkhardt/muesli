import CoreMedia
import Foundation
@testable import Muesli

/// Mock implementation of EchoCancellationService for testing
final class MockEchoCancellationService: EchoCancellationServiceProtocol, @unchecked Sendable {
    // MARK: - Call Tracking
    
    var storeSystemAudioCallCount: Int = 0
    var processMicrophoneAudioCallCount: Int = 0
    var resetCallCount: Int = 0
    
    var lastStoredSamples: [Float]?
    var lastStoredTimestamp: CMTime?
    var lastProcessedSamples: [Float]?
    var lastProcessedTimestamp: CMTime?
    
    // MARK: - Test Control Properties
    
    /// If set, returns this instead of the input samples
    var processedAudioOverride: [Float]?
    
    // MARK: - EchoCancellationServiceProtocol
    
    func storeSystemAudio(samples: [Float], timestamp: CMTime) {
        storeSystemAudioCallCount += 1
        lastStoredSamples = samples
        lastStoredTimestamp = timestamp
    }
    
    func processMicrophoneAudio(microphoneSamples: [Float], micTimestamp: CMTime) -> [Float] {
        processMicrophoneAudioCallCount += 1
        lastProcessedSamples = microphoneSamples
        lastProcessedTimestamp = micTimestamp
        
        if let override = processedAudioOverride {
            return override
        }
        
        // Default: return input unmodified (no echo cancellation)
        return microphoneSamples
    }
    
    func reset() {
        resetCallCount += 1
    }
    
    // MARK: - Test Helpers
    
    /// Reset all tracking state for next test
    func resetTracking() {
        storeSystemAudioCallCount = 0
        processMicrophoneAudioCallCount = 0
        resetCallCount = 0
        lastStoredSamples = nil
        lastStoredTimestamp = nil
        lastProcessedSamples = nil
        lastProcessedTimestamp = nil
        processedAudioOverride = nil
    }
}
