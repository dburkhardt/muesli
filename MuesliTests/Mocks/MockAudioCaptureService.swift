import CoreMedia
import Foundation
@testable import Muesli

/// Mock implementation of AudioCaptureServiceProtocol for testing
actor MockAudioCaptureService: AudioCaptureServiceProtocol {
    // MARK: - State
    
    private(set) var isRecording: Bool = false
    
    // MARK: - Test Control Properties
    
    var shouldFailStartCapture: Bool = false
    var startCaptureError: Error = AudioCaptureError.permissionDenied
    var shouldFailStopCapture: Bool = false
    var stopCaptureError: Error = AudioCaptureError.notRecording
    
    // MARK: - Call Tracking
    
    var startCaptureCallCount: Int = 0
    var startCaptureWithBundleIDCallCount: Int = 0
    var stopCaptureCallCount: Int = 0
    var setMicrophoneDeviceCallCount: Int = 0
    var lastBundleIdentifier: String?
    var lastMicrophoneDeviceID: String?
    
    // MARK: - Handlers
    
    private var bufferHandler: AudioBufferHandler?
    private var interruptedHandler: StreamInterruptedHandler?
    private var levelHandler: AudioLevelHandler?
    private var warningHandler: AudioWarningHandler?
    private var processedMicHandler: ProcessedMicHandler?
    private var processedRenderHandler: ProcessedRenderHandler?
    
    // MARK: - AudioCaptureServiceProtocol
    
    func setBufferHandler(_ handler: @escaping AudioBufferHandler) {
        bufferHandler = handler
    }
    
    func setInterruptedHandler(_ handler: @escaping StreamInterruptedHandler) {
        interruptedHandler = handler
    }
    
    func setLevelHandler(_ handler: @escaping AudioLevelHandler) {
        levelHandler = handler
    }
    
    func setWarningHandler(_ handler: @escaping AudioWarningHandler) {
        warningHandler = handler
    }

    func setProcessedMicHandler(_ handler: @escaping ProcessedMicHandler) {
        processedMicHandler = handler
    }

    func setProcessedRenderHandler(_ handler: @escaping ProcessedRenderHandler) {
        processedRenderHandler = handler
    }
    
    func setMicrophoneDevice(_ deviceID: String?) {
        lastMicrophoneDeviceID = deviceID
        setMicrophoneDeviceCallCount += 1
    }
    
    func startCapture() async throws {
        startCaptureCallCount += 1
        
        if shouldFailStartCapture {
            throw startCaptureError
        }
        
        isRecording = true
    }
    
    func startCapture(forBundleIdentifier bundleIdentifier: String) async throws {
        startCaptureWithBundleIDCallCount += 1
        lastBundleIdentifier = bundleIdentifier
        
        if shouldFailStartCapture {
            throw startCaptureError
        }
        
        isRecording = true
    }
    
    func stopCapture() async throws {
        stopCaptureCallCount += 1
        
        if shouldFailStopCapture {
            throw stopCaptureError
        }
        
        isRecording = false
    }
    
    // MARK: - Test Helpers
    
    /// Simulate receiving an audio buffer
    func simulateBuffer(_ buffer: CMSampleBuffer, type: AudioStreamType) {
        bufferHandler?(buffer, type)
    }
    
    /// Simulate stream interruption
    func simulateInterruption(_ error: Error?) {
        interruptedHandler?(error)
    }
    
    /// Simulate audio level update
    func simulateLevel(_ level: Float, type: AudioStreamType) {
        levelHandler?(level, type)
    }

    /// Simulate processed audio delivery for microphone stream
    func simulateProcessedMicAudio(
        samples: [Float],
        sampleRate: Int = 48000,
        hostTime: UInt64 = 0,
        startSampleIndex: Int64 = 0
    ) {
        processedMicHandler?(AudioFrame(
            samples: samples,
            sampleRate: sampleRate,
            hostTime: hostTime,
            startSampleIndex: startSampleIndex
        ))
    }

    /// Simulate processed audio delivery for render stream
    func simulateProcessedRenderAudio(
        samples: [Float],
        sampleRate: Int = 48000,
        hostTime: UInt64 = 0,
        startSampleIndex: Int64 = 0
    ) {
        processedRenderHandler?(AudioFrame(
            samples: samples,
            sampleRate: sampleRate,
            hostTime: hostTime,
            startSampleIndex: startSampleIndex
        ))
    }
    
    /// Reset all state for next test
    func reset() {
        isRecording = false
        shouldFailStartCapture = false
        shouldFailStopCapture = false
        startCaptureCallCount = 0
        startCaptureWithBundleIDCallCount = 0
        stopCaptureCallCount = 0
        setMicrophoneDeviceCallCount = 0
        lastBundleIdentifier = nil
        lastMicrophoneDeviceID = nil
        bufferHandler = nil
        interruptedHandler = nil
        levelHandler = nil
        processedMicHandler = nil
        processedRenderHandler = nil
    }
}
