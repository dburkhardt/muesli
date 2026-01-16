import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia


// MARK: - AVAudioEngine Microphone Capture Helper

/// Helper class to capture microphone audio via AVAudioEngine
/// This is used instead of ScreenCaptureKit's captureMicrophone because SCK
/// always uses the system default mic and ignores user device selection
private final class MicrophoneCaptureEngine: @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private var isRunning = false
    private let bufferHandler: ((CMSampleBuffer) -> Void)?
    private let levelHandler: ((Float) -> Void)?
    
    init(bufferHandler: ((CMSampleBuffer) -> Void)?, levelHandler: ((Float) -> Void)?) {
        self.bufferHandler = bufferHandler
        self.levelHandler = levelHandler
    }
    
    func start(deviceID: String?) throws {
        guard !isRunning else { return }
        
        let inputNode = audioEngine.inputNode
        
        // Try to set the preferred device if specified
        if let deviceID = deviceID {
            setInputDevice(deviceID: deviceID)
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, time in
            self?.handleAudioBuffer(buffer, time: time)
        }
        
        try audioEngine.start()
        isRunning = true
        
    }
    
    func stop() {
        guard isRunning else { return }
        
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
        
    }
    
    private func setInputDevice(deviceID: String) {
        // Find the audio device with matching UID
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize)
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceIDs)
        
        for audioDeviceID in deviceIDs {
            // Get device UID
            var deviceUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            let status = AudioObjectGetPropertyData(audioDeviceID, &uidAddress, 0, nil, &uidSize, &deviceUID)
            if status == noErr && (deviceUID as String) == deviceID {
                // Found the device, set it as input
                do {
                    try audioEngine.inputNode.auAudioUnit.setDeviceID(audioDeviceID)
                } catch {
                }
                return
            }
        }
    }
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let floatChannelData = buffer.floatChannelData else { return }
        
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        // Calculate RMS for level meter
        var sumOfSquares: Float = 0.0
        let samples = UnsafeBufferPointer(start: floatChannelData[0], count: frameLength)
        for sample in samples {
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(frameLength))
        let level = min(rms * 16.0, 1.0)
        levelHandler?(level)
        
        
        // Convert AVAudioPCMBuffer to CMSampleBuffer for compatibility
        if let sampleBuffer = createCMSampleBuffer(from: buffer, time: time) {
            bufferHandler?(sampleBuffer)
        }
    }
    
    private func createCMSampleBuffer(from buffer: AVAudioPCMBuffer, time: AVAudioTime) -> CMSampleBuffer? {
        guard let floatChannelData = buffer.floatChannelData else { return nil }
        
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        
        // Create mono Float32 data
        var monoData: [Float]
        if channelCount == 1 {
            monoData = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
        } else {
            // Average channels for mono
            monoData = [Float](repeating: 0, count: frameLength)
            for i in 0..<frameLength {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += floatChannelData[ch][i]
                }
                monoData[i] = sum / Float(channelCount)
            }
        }
        
        // Create AudioStreamBasicDescription for mono Float32
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        // Create format description
        var formatDesc: CMFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let format = formatDesc else { return nil }
        
        // Create block buffer
        let dataSize = monoData.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let block = blockBuffer else { return nil }
        
        // Copy data
        status = monoData.withUnsafeBufferPointer { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        guard status == noErr else { return nil }
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(seconds: time.audioTimeStamp.mHostTime > 0 ? Double(time.audioTimeStamp.mHostTime) / 1_000_000_000.0 : CACurrentMediaTime(), preferredTimescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        
        status = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: monoData.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        return status == noErr ? sampleBuffer : nil
    }
}

/// Callback type for receiving audio buffers
/// Note: Buffers are processed synchronously in the callback - do not block
typealias AudioBufferHandler = @Sendable (CMSampleBuffer, AudioCaptureService.AudioType) -> Void

/// Callback type for when the stream is interrupted (e.g., captured app quits)
typealias StreamInterruptedHandler = @Sendable (Error?) -> Void

/// Callback type for audio level updates (0.0 to 1.0)
typealias AudioLevelHandler = @Sendable (Float, AudioCaptureService.AudioType) -> Void

/// Service responsible for capturing audio from meeting apps and microphone
/// Uses ScreenCaptureKit to capture system audio from selected applications
actor AudioCaptureService: AudioCaptureServiceProtocol {
    
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
        case bufferHandlerNotSet
        
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
            case .bufferHandlerNotSet:
                return "Buffer handler must be set before starting capture. Call setBufferHandler() first."
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
    
    // AVAudioEngine-based microphone capture (replaces SCK's captureMicrophone)
    private var microphoneEngine: MicrophoneCaptureEngine?
    
    /// Selected microphone device ID (set before starting capture)
    private var selectedMicrophoneDeviceID: String?
    
    private(set) var isRecording = false
    
    // Audio configuration (using centralized AudioConfiguration)
    private let sampleRate: Int = AudioConfiguration.captureSampleRate
    private let channelCount: Int = AudioConfiguration.captureChannelCount
    
    // MARK: - Initialization
    
    init() {}
    
    /// Set the microphone device to use for capture
    func setMicrophoneDevice(_ deviceID: String?) {
        selectedMicrophoneDeviceID = deviceID
    }
    
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
        
        // PRECONDITION: Buffer handler must be set before starting capture
        // This prevents race conditions where audio starts flowing before the handler is configured
        guard bufferHandler != nil else {
            throw CaptureError.bufferHandlerNotSet
        }
        
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
        
        // NOTE: We do NOT use ScreenCaptureKit's captureMicrophone because it:
        // 1. Always uses system default mic, ignoring user selection
        // 2. Has been observed to return all-zero samples in some configurations
        // Instead, we use AVAudioEngine for microphone capture below
        
        
        // Create the stream delegate to handle errors/interruptions
        let delegate = StreamDelegate { [weak self] error in
            guard let self = self else { return }
            Task {
                await self.handleStreamInterrupted(error: error)
            }
        }
        
        // Create the stream
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        
        // Create and add stream output for system audio
        let output = StreamOutput(handler: bufferHandler, levelHandler: levelHandler)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        
        // Start AVAudioEngine for microphone capture (instead of SCK's captureMicrophone)
        let micHandler = bufferHandler
        let micLevelHandler = levelHandler
        let micEngine = MicrophoneCaptureEngine(
            bufferHandler: { buffer in
                micHandler?(buffer, .microphone)
            },
            levelHandler: { level in
                micLevelHandler?(level, .microphone)
            }
        )
        
        do {
            try micEngine.start(deviceID: selectedMicrophoneDeviceID)
            self.microphoneEngine = micEngine
        } catch {
            // Continue without mic capture - system audio will still work
            print("[AudioCaptureService] Warning: Microphone capture failed to start: \(error)")
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
        
        // Stop microphone engine
        microphoneEngine?.stop()
        microphoneEngine = nil
        
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
        
        // Stop microphone engine first
        microphoneEngine?.stop()
        microphoneEngine = nil
        
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
