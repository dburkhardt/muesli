@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os.lock
import os.log
@preconcurrency import ScreenCaptureKit

// MARK: - AVAudioEngine Microphone Capture Helper

/// Helper class to capture microphone audio via AVAudioEngine
/// This is used instead of ScreenCaptureKit's captureMicrophone because SCK
/// always uses the system default mic and ignores user device selection
private final class MicrophoneCaptureEngine: @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private var isRunning = false
    private let bufferHandler: ((CMSampleBuffer) -> Void)?
    private let levelHandler: ((Float) -> Void)?
    
    /// Counter for throttling mic diagnostic logging (every 100th buffer)
    /// nonisolated(unsafe) is acceptable here - worst case is slightly inaccurate count for diagnostics
    private nonisolated(unsafe) static var micBufferDiagCount = 0
    
    init(bufferHandler: ((CMSampleBuffer) -> Void)?, levelHandler: ((Float) -> Void)?) {
        self.bufferHandler = bufferHandler
        self.levelHandler = levelHandler
    }
    
    private let logger = LoggerFactory.logger(category: "MicrophoneCaptureEngine")
    
    func start(deviceID: String?) throws {
        guard !isRunning else { return }
        
        let inputNode = audioEngine.inputNode
        
        // Try to set the preferred device if specified
        if let deviceID = deviceID {
            // CRITICAL: Skip aggregate devices - they don't deliver real audio
            // ScreenCaptureKit creates these and they cause first-recording failures
            if deviceID.contains("Aggregate") {
                logger.warning("Skipping aggregate device, using system default real microphone")
                // Don't call setInputDevice - let AVAudioEngine find a real device
                selectFirstRealMicrophone()
            } else {
                setInputDevice(deviceID: deviceID)
            }
        } else {
            // No device specified - try to select a real microphone explicitly
            selectFirstRealMicrophone()
        }
        
        // Get the input format to determine hardware sample rate and channels
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        // CRITICAL FIX: Always request Float32 format for the tap
        // The hardware may deliver Int16 audio, which causes handleAudioBuffer to fail
        // (floatChannelData is nil for Int16 buffers)
        // By requesting Float32, AVAudioEngine automatically converts for us
        let tapSampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 48000
        let tapChannels = inputFormat.channelCount > 0 ? inputFormat.channelCount : 1
        
        guard let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapSampleRate,
            channels: tapChannels,
            interleaved: false
        ) else {
            logger.error("Failed to create Float32 tap format, using input format directly")
            // Fall back to input format (may not have floatChannelData)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat.sampleRate > 0 ? inputFormat : nil) { [weak self] buffer, time in
                self?.handleAudioBuffer(buffer, time: time)
            }
            try audioEngine.start()
            isRunning = true
            return
        }
        
        logger.debug("Installing tap with Float32 format: \(tapSampleRate)Hz, \(tapChannels) channels")
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, time in
            self?.handleAudioBuffer(buffer, time: time)
        }
        
        do {
            try audioEngine.start()
            isRunning = true
        } catch {
            throw error
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }
    
    /// Select the first real (non-aggregate) microphone device
    /// This is a fallback when no device is specified or an aggregate device was requested
    private func selectFirstRealMicrophone() {
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize)
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )
        
        for audioDeviceID in deviceIDs {
            // Check if device has input channels (is a microphone)
            var inputChannels: UInt32 = 0
            var inputSize = UInt32(MemoryLayout<UInt32>.size)
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            // Get buffer list size first
            var bufferListSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(audioDeviceID, &inputAddress, 0, nil, &bufferListSize)
            
            if bufferListSize > 0 {
                let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
                defer { bufferListPtr.deallocate() }
                
                if AudioObjectGetPropertyData(audioDeviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr) == noErr {
                    let bufferList = bufferListPtr.pointee
                    inputChannels = bufferList.mBuffers.mNumberChannels
                }
            }
            
            guard inputChannels > 0 else { continue }
            
            // Get device UID to check if it's an aggregate
            var deviceUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            let status = AudioObjectGetPropertyData(audioDeviceID, &uidAddress, 0, nil, &uidSize, &deviceUID)
            if status == noErr {
                let uid = deviceUID as String
                
                // Skip aggregate devices
                if uid.contains("Aggregate") {
                    continue
                }
                
                // Found a real microphone - use it!
                do {
                    try audioEngine.inputNode.auAudioUnit.setDeviceID(audioDeviceID)
                    logger.debug("Selected real microphone: \(audioDeviceID), UID: \(uid)")
                    return
                } catch {
                    logger.warning("Failed to set device \(audioDeviceID): \(error)")
                    continue
                }
            }
        }
        
        logger.warning("Could not find a real microphone device")
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
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )
        
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
    
    /// Track callback timing for diagnostics (thread-safe)
    private struct MicTapState {
        var lastMicTapTime: Double = 0
        var micTapCount: Int = 0
        var micTapGapTotal: Double = 0
    }
    private nonisolated(unsafe) static let micTapLock = OSAllocatedUnfairLock(
        initialState: MicTapState()
    )
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let tapStart = CACurrentMediaTime()
        
        // Track gap between tap callbacks (before any processing)
        var tapGap: Double = 0
        var tapCount: Int = 0
        var avgGap: Double = 0
        var shouldLog = false
        Self.micTapLock.withLock { state in
            tapGap = state.lastMicTapTime > 0 ? tapStart - state.lastMicTapTime : 0
            state.lastMicTapTime = tapStart
            state.micTapCount += 1
            state.micTapGapTotal += tapGap
            tapCount = state.micTapCount
            avgGap = state.micTapGapTotal / Double(state.micTapCount)
            shouldLog = state.micTapCount % 50 == 0
        }
        
        // Log tap timing every 50 callbacks
        if shouldLog {
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "MIC_TAP: count=\(tapCount), lastGap=\(String(format: "%.3f", tapGap))s, avgGap=\(String(format: "%.3f", avgGap))s")
            }
        }
        
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
        let convertStart = CACurrentMediaTime()
        if let sampleBuffer = createCMSampleBuffer(from: buffer, time: time) {
            let convertTime = CACurrentMediaTime() - convertStart
            
            // Log if conversion takes too long (>10ms)
            if convertTime > 0.01 {
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "MIC_CONVERT_SLOW: \(String(format: "%.1f", convertTime * 1000))ms")
                }
            }
            
            let handlerStart = CACurrentMediaTime()
            bufferHandler?(sampleBuffer)
            let handlerTime = CACurrentMediaTime() - handlerStart
            
            // Log if handler takes too long (>50ms)
            if handlerTime > 0.05 {
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "MIC_HANDLER_SLOW: \(String(format: "%.1f", handlerTime * 1000))ms")
                }
            }
        }
        
        let totalTime = CACurrentMediaTime() - tapStart
        // Log if total tap processing takes too long (>100ms)
        if totalTime > 0.1 {
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "MIC_TAP_SLOW: total=\(String(format: "%.1f", totalTime * 1000))ms")
            }
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
        
        // FIX: Use CACurrentMediaTime() for timestamps to match ScreenCaptureKit's clock domain
        // BEFORE (buggy): mHostTime ÷ 1e9 assumes nanoseconds, but Mach time uses hardware-
        // dependent timebase (~125:3 on Apple Silicon), giving timestamps ~41x off
        // This caused findMatchingSystemAudio() to always return nil (0% match rate)
        let timestamp = CACurrentMediaTime()
        
        // AEC Diagnostic: Log mic timestamps to verify fix
        // After fix: timestamps should match wall clock within ~100ms
        Self.micBufferDiagCount += 1
        if Self.micBufferDiagCount % 100 == 0 {
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "MIC: timestamp=\(String(format: "%.3f", timestamp))s (using CACurrentMediaTime)")
            }
        }
        
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: CMTimeScale(sampleRate)),
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

/// Callback type for service warnings (message, details, canRetry)
/// Used to propagate non-fatal errors to the UI
typealias AudioWarningHandler = @Sendable (String, String, Bool) -> Void

/// Service responsible for capturing audio from meeting apps and microphone
/// Uses ScreenCaptureKit to capture system audio from selected applications
actor AudioCaptureService: AudioCaptureServiceProtocol {
    // MARK: - Types
    
    private nonisolated let logger = LoggerFactory.logger(category: "AudioCaptureService")
    
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
    private var warningHandler: AudioWarningHandler?
    
    // AVAudioEngine-based microphone capture (replaces SCK's captureMicrophone)
    private var microphoneEngine: MicrophoneCaptureEngine?
    private var pendingMicrophoneEngine: MicrophoneCaptureEngine?
    
    /// Selected microphone device ID (set before starting capture)
    private var selectedMicrophoneDeviceID: String?
    
    private(set) var isRecording = false

    // MARK: - Startup Sync (System-first gating)
    // ScreenCaptureKit can take hundreds of ms to deliver its first audio buffer.
    // To guarantee render arrives before capture for WebRTC AEC, we start the mic
    // ONLY after the first system buffer arrives (with a timeout fallback).
    private var didStartMicrophone = false
    private var didSeeSystemBuffer = false
    private var micStartFallbackTask: Task<Void, Never>?
    private var firstSystemBufferTime: Double?
    private var firstMicStartTime: Double?
    
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
    
    /// Set a handler to receive non-fatal warnings (e.g., microphone unavailable)
    /// Warnings are informational - recording continues despite the issue
    func setWarningHandler(_ handler: @escaping AudioWarningHandler) {
        self.warningHandler = handler
    }
    
    /// Start capturing ALL system audio (no app filter)
    /// This captures audio from all applications on the system
    func startCapture() async throws {
        guard !isRecording else {
            throw CaptureError.alreadyRecording
        }
        
        // Pre-check permission to avoid triggering a prompt via SCShareableContent
        // NOTE: CGPreflightScreenCaptureAccess() is reliable when using stable code signing
        // (DEVELOPMENT_TEAM configured). With ad-hoc signing, it may return false incorrectly.
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
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
        
        // Pre-check permission to avoid triggering a prompt via SCShareableContent
        // NOTE: CGPreflightScreenCaptureAccess() is reliable when using stable code signing
        // (DEVELOPMENT_TEAM configured). With ad-hoc signing, it may return false incorrectly.
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
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
        
        // Create a wrapped handler to detect first system audio buffer
        let captureHandler = bufferHandler
        let wrappedHandler: AudioBufferHandler = { [weak self] buffer, type in
            if type == .system {
                Task { await self?.handleFirstSystemBuffer() }
            }
            captureHandler?(buffer, type)
        }
        
        // Create and add stream output for system audio
        let output = StreamOutput(handler: wrappedHandler, levelHandler: levelHandler)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        
        // Start the ScreenCaptureKit stream FIRST
        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.streamStartFailed(underlying: error)
        }
        
        // Prepare microphone engine but DO NOT start until system audio arrives
        let micHandler = captureHandler
        let micLevelHandler = levelHandler
        let micEngine = MicrophoneCaptureEngine(
            bufferHandler: { buffer in
                micHandler?(buffer, .microphone)
            },
            levelHandler: { level in
                micLevelHandler?(level, .microphone)
            }
        )
        pendingMicrophoneEngine = micEngine
        didStartMicrophone = false
        didSeeSystemBuffer = false
        firstSystemBufferTime = nil
        firstMicStartTime = nil
        
        // Fallback: start mic after 2s if no system audio arrives
        micStartFallbackTask?.cancel()
        micStartFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.startMicrophoneIfNeeded(reason: "timeout")
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
        pendingMicrophoneEngine = nil
        didStartMicrophone = false
        didSeeSystemBuffer = false
        firstSystemBufferTime = nil
        firstMicStartTime = nil
        micStartFallbackTask?.cancel()
        micStartFallbackTask = nil
        
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
        pendingMicrophoneEngine = nil
        didStartMicrophone = false
        didSeeSystemBuffer = false
        firstSystemBufferTime = nil
        firstMicStartTime = nil
        micStartFallbackTask?.cancel()
        micStartFallbackTask = nil
        
        try await stream.stopCapture()
        
        self.stream = nil
        self.streamOutput = nil
        self.streamDelegate = nil
        self.isRecording = false
    }

    // MARK: - Startup Sync Helpers
    
    private func handleFirstSystemBuffer() async {
        guard !didSeeSystemBuffer else { return }
        didSeeSystemBuffer = true
        firstSystemBufferTime = CACurrentMediaTime()
        Task { await DiagnosticLogger.shared.log(.aec,
            "SYSTEM_FIRST_BUFFER: time=\(String(format: "%.3f", firstSystemBufferTime ?? 0))") }
        logger.info("System audio first buffer arrived; starting mic capture")
        await startMicrophoneIfNeeded(reason: "system-first-buffer")
    }
    
    private func startMicrophoneIfNeeded(reason: String) async {
        guard !didStartMicrophone else { return }
        guard let micEngine = pendingMicrophoneEngine else { return }
        
        didStartMicrophone = true
        micStartFallbackTask?.cancel()
        micStartFallbackTask = nil
        firstMicStartTime = CACurrentMediaTime()
        let systemTime = firstSystemBufferTime
        let deltaMs = systemTime != nil ? (firstMicStartTime! - systemTime!) * 1000 : nil
        let deltaText = deltaMs != nil ? String(format: "%.1f", deltaMs!) : "n/a"
        Task { await DiagnosticLogger.shared.log(.aec,
            "MIC_START: reason=\(reason), time=\(String(format: "%.3f", firstMicStartTime ?? 0)), deltaMs=\(deltaText)") }
        
        do {
            try micEngine.start(deviceID: selectedMicrophoneDeviceID)
            self.microphoneEngine = micEngine
            logger.info("Microphone capture started (\(reason))")
        } catch {
            // Continue without mic capture - system audio will still work
            logger.warning("Microphone capture failed to start: \(error.localizedDescription)")
            
            // Propagate warning to UI via callback
            let details = """
                Microphone capture failed to start.
                Error: \(error.localizedDescription)
                Device ID: \(selectedMicrophoneDeviceID ?? "system default")
                
                System audio is still being recorded.
                You can select a different microphone in preferences and try again.
                """
            warningHandler?("Microphone unavailable", details, true)
        }
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
    private func calculateRMSLevel(
        from sampleBuffer: CMSampleBuffer,
        audioType: AudioCaptureService.AudioType
    ) -> Float {
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
