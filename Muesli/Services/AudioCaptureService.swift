import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Callback type for receiving audio buffers
/// Note: Buffers are processed synchronously in the callback - do not block
typealias AudioBufferHandler = @Sendable (CMSampleBuffer, AudioCaptureService.AudioType) -> Void

/// Callback type for when the stream is interrupted (e.g., captured app quits)
typealias StreamInterruptedHandler = @Sendable (Error?) -> Void

/// Callback type for audio level updates (0.0 to 1.0)
typealias AudioLevelHandler = @Sendable (Float, AudioCaptureService.AudioType) -> Void

/// Service responsible for capturing audio from meeting apps and microphone
/// Uses ScreenCaptureKit to capture system audio from selected applications
actor AudioCaptureService {
    
    // MARK: - Types
    
    enum AudioType: Sendable {
        case system  // Audio from the captured application
        case microphone  // User's microphone audio
    }
    
    enum CaptureError: Error, LocalizedError {
        case noContentToCapture
        case streamConfigurationFailed
        case permissionDenied
        case streamStartFailed(underlying: Error)
        case alreadyRecording
        case notRecording
        case streamInterrupted(underlying: Error?)
        
        var errorDescription: String? {
            switch self {
            case .noContentToCapture:
                return "No content available to capture"
            case .streamConfigurationFailed:
                return "Failed to configure audio stream"
            case .permissionDenied:
                return "Screen recording permission denied"
            case .streamStartFailed(let error):
                return "Failed to start stream: \(error.localizedDescription)"
            case .alreadyRecording:
                return "Already recording"
            case .notRecording:
                return "Not currently recording"
            case .streamInterrupted(let error):
                if let error = error {
                    return "Stream interrupted: \(error.localizedDescription)"
                }
                return "Stream was interrupted"
            }
        }
    }
    
    // MARK: - Properties
    
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var streamDelegate: StreamDelegate?
    private var bufferHandler: AudioBufferHandler?
    private var interruptedHandler: StreamInterruptedHandler?
    private var levelHandler: AudioLevelHandler?
    
    private(set) var isRecording = false
    
    // Audio configuration
    private let sampleRate: Int = 48000
    private let channelCount: Int = 2
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Public API
    
    /// Set a handler to receive audio buffers
    /// The handler is called synchronously from the audio queue - do not block
    func setBufferHandler(_ handler: @escaping AudioBufferHandler) {
        self.bufferHandler = handler
    }
    
    /// Set a handler to be called when the stream is interrupted (e.g., captured app quits)
    func setInterruptedHandler(_ handler: @escaping StreamInterruptedHandler) {
        self.interruptedHandler = handler
    }
    
    /// Set a handler to receive audio level updates (0.0 to 1.0)
    func setLevelHandler(_ handler: @escaping AudioLevelHandler) {
        self.levelHandler = handler
    }
    
    /// Start capturing ALL system audio (no app filter)
    /// This captures audio from all applications on the system
    func startCapture() async throws {
        guard !isRecording else {
            throw CaptureError.alreadyRecording
        }
        
        // Get available content - this is where TCC permission is checked
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        
        // Get the main display
        guard let display = content.displays.first else {
            throw CaptureError.noContentToCapture
        }
        
        // Create content filter for ALL applications (exclude none)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        
        try await startCaptureWithFilter(filter)
    }
    
    /// Start capturing audio from the specified application
    /// - Parameter bundleIdentifier: The bundle identifier of the application to capture audio from
    func startCapture(forBundleIdentifier bundleIdentifier: String) async throws {
        guard !isRecording else {
            throw CaptureError.alreadyRecording
        }
        
        // Get available content - this is where TCC permission is checked
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        
        // Find the target application
        guard let targetApp = content.applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw CaptureError.noContentToCapture
        }
        
        // Get the main display
        guard let display = content.displays.first else {
            throw CaptureError.noContentToCapture
        }
        
        // Create content filter for the specific application
        let filter = SCContentFilter(display: display, including: [targetApp], exceptingWindows: [])
        
        try await startCaptureWithFilter(filter)
    }
    
    /// Common capture logic with a given content filter
    private func startCaptureWithFilter(_ filter: SCContentFilter) async throws {
        // Configure stream for AUDIO-ONLY capture
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.channelCount = channelCount
        configuration.sampleRate = sampleRate
        
        // Minimal video config (required for display-based filter, but we ignore video output)
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum
        
        // Enable microphone capture on macOS 15+
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = true
        }
        
        // Create the stream delegate to handle errors/interruptions
        let delegate = StreamDelegate { [weak self] error in
            guard let self = self else { return }
            Task {
                await self.handleStreamInterrupted(error: error)
            }
        }
        
        // Create the stream
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        
        // Create and add stream output
        let output = StreamOutput(handler: bufferHandler, levelHandler: levelHandler)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        
        // Add microphone output on macOS 15+
        if #available(macOS 15.0, *) {
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: .global(qos: .userInteractive))
        }
        
        // Start the stream
        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.streamStartFailed(underlying: error)
        }
        
        self.stream = stream
        self.streamOutput = output
        self.streamDelegate = delegate
        self.isRecording = true
    }
    
    /// Handle stream interruption internally
    private func handleStreamInterrupted(error: Error?) {
        // Only process if we're still recording
        guard isRecording else { return }
        
        // Mark as not recording
        self.isRecording = false
        self.stream = nil
        self.streamOutput = nil
        self.streamDelegate = nil
        
        // Notify the handler
        interruptedHandler?(error)
    }
    
    /// Stop the current audio capture
    func stopCapture() async throws {
        guard isRecording, let stream = stream else {
            throw CaptureError.notRecording
        }
        
        try await stream.stopCapture()
        
        self.stream = nil
        self.streamOutput = nil
        self.streamDelegate = nil
        self.isRecording = false
    }
}

// MARK: - Stream Output Handler

/// Handles incoming audio samples from ScreenCaptureKit
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    
    private let handler: AudioBufferHandler?
    private let levelHandler: AudioLevelHandler?
    
    init(handler: AudioBufferHandler?, levelHandler: AudioLevelHandler?) {
        self.handler = handler
        self.levelHandler = levelHandler
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only process valid audio samples
        guard sampleBuffer.isValid else { return }
        
        let audioType: AudioCaptureService.AudioType
        
        switch type {
        case .audio:
            audioType = .system
        case .microphone:
            audioType = .microphone
        case .screen:
            // Ignore video frames - we only need audio
            return
        @unknown default:
            return
        }
        
        // Call buffer handler
        handler?(sampleBuffer, audioType)
        
        // Calculate and report audio level
        if let levelHandler = levelHandler {
            let level = calculateRMSLevel(from: sampleBuffer, audioType: audioType)
            levelHandler(level, audioType)
        }
    }
    
    /// Calculate RMS (root mean square) audio level from sample buffer
    /// Returns a value between 0.0 and 1.0
    private func calculateRMSLevel(from sampleBuffer: CMSampleBuffer, audioType: AudioCaptureService.AudioType) -> Float {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0.0
        }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == noErr, let data = dataPointer else {
            return 0.0
        }
        
        // Get audio format info to determine sample type
        var isInt16 = false
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
            isInt16 = asbd.mBitsPerChannel == 16
        }
        
        var rms: Float = 0.0
        
        if isInt16 {
            // Microphone audio is Int16 format
            let int16Pointer = UnsafeRawPointer(data).assumingMemoryBound(to: Int16.self)
            let sampleCount = length / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { return 0.0 }
            
            var sumOfSquares: Float = 0.0
            for i in 0..<sampleCount {
                // Convert Int16 to normalized float (-1.0 to 1.0)
                let sample = Float(int16Pointer[i]) / Float(Int16.max)
                sumOfSquares += sample * sample
            }
            rms = sqrt(sumOfSquares / Float(sampleCount))
        } else {
            // System audio is Float32 format
            let floatPointer = UnsafeRawPointer(data).assumingMemoryBound(to: Float32.self)
            let sampleCount = length / MemoryLayout<Float32>.size
            guard sampleCount > 0 else { return 0.0 }
            
            var sumOfSquares: Float = 0.0
            for i in 0..<sampleCount {
                let sample = floatPointer[i]
                sumOfSquares += sample * sample
            }
            rms = sqrt(sumOfSquares / Float(sampleCount))
        }
        
        // Convert to 0-1 range with aggressive scaling for visual feedback
        // Higher multiplier = more responsive to quiet sounds
        let normalizedLevel = min(rms * 16.0, 1.0)
        
        return normalizedLevel
    }
}

// MARK: - Stream Delegate

/// Handles stream lifecycle events like errors and interruptions
private final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    
    private let onInterrupted: (Error?) -> Void
    
    init(onInterrupted: @escaping (Error?) -> Void) {
        self.onInterrupted = onInterrupted
        super.init()
    }
    
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // Stream stopped unexpectedly (e.g., captured app quit)
        onInterrupted(error)
    }
}
