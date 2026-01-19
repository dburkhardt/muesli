@preconcurrency import AVFoundation
import CoreMedia
import Foundation
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
    
    init(bufferHandler: ((CMSampleBuffer) -> Void)?, levelHandler: ((Float) -> Void)?) {
        self.bufferHandler = bufferHandler
        self.levelHandler = levelHandler
        
        // #region agent log
        struct InstanceCounter { nonisolated(unsafe) static var count = 0 }
        InstanceCounter.count += 1
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let initEntry = "{\"hypothesisId\":\"F\",\"location\":\"MicrophoneCaptureEngine.init\",\"message\":\"New instance created\",\"data\":{\"instanceNum\":\(InstanceCounter.count),\"bufferHandlerNil\":\(bufferHandler == nil)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
        if let initData = initEntry.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
            if let initHandle = FileHandle(forWritingAtPath: logPath) { initHandle.seekToEndOfFile(); initHandle.write(initData); initHandle.closeFile() }
        }
        // #endregion
    }
    
    func start(deviceID: String?) throws {
        guard !isRunning else { return }
        
        // #region agent log
        print("[MUESLI_DEBUG] MicrophoneCaptureEngine.start() called with deviceID: \(deviceID ?? "nil")")
        // #endregion
        
        let inputNode = audioEngine.inputNode
        
        // Try to set the preferred device if specified
        if let deviceID = deviceID {
            // CRITICAL: Skip aggregate devices - they don't deliver real audio
            // ScreenCaptureKit creates these and they cause first-recording failures
            if deviceID.contains("Aggregate") {
                print("[MUESLI_DEBUG] WARNING: Skipping aggregate device, will use system default real microphone")
                // Don't call setInputDevice - let AVAudioEngine find a real device
                selectFirstRealMicrophone()
            } else {
                setInputDevice(deviceID: deviceID)
            }
        } else {
            // No device specified - try to select a real microphone explicitly
            selectFirstRealMicrophone()
        }
        
        // Get both input and output formats for diagnostics
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = inputNode.outputFormat(forBus: 0)
        
        // #region agent log
        print("[MUESLI_DEBUG] inputFormat: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount), commonFormat=\(inputFormat.commonFormat.rawValue)")
        print("[MUESLI_DEBUG] outputFormat: sampleRate=\(outputFormat.sampleRate), channels=\(outputFormat.channelCount), commonFormat=\(outputFormat.commonFormat.rawValue)")
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let logEntry = "{\"hypothesisId\":\"A\",\"location\":\"MicrophoneCaptureEngine.start\",\"message\":\"AVAudioEngine formats\",\"data\":{\"inputSampleRate\":\(inputFormat.sampleRate),\"inputChannels\":\(inputFormat.channelCount),\"outputSampleRate\":\(outputFormat.sampleRate),\"outputChannels\":\(outputFormat.channelCount),\"deviceID\":\"\(deviceID ?? "nil")\"},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
        if let data = logEntry.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
            if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
        }
        // #endregion
        
        // Use the output format but check if it's valid
        // If sampleRate is 0 or invalid, the tap won't receive callbacks
        var recordingFormat = outputFormat
        if recordingFormat.sampleRate == 0 {
            // Fallback: Create a standard format
            print("[MUESLI_DEBUG] WARNING: outputFormat has 0 sample rate, using fallback format")
            recordingFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        }
        
        // CRITICAL FIX: Use the INPUT format when installing the tap
        // Using nil or output format causes error -10868 when input/output formats don't match
        // The input format reflects what the hardware is actually delivering
        let tapFormat = inputFormat.sampleRate > 0 ? inputFormat : nil
        
        // #region agent log
        let tapLogEntry = "{\"hypothesisId\":\"D\",\"location\":\"MicrophoneCaptureEngine.start\",\"message\":\"Installing tap on inputNode\",\"data\":{\"bufferSize\":4096,\"tapFormatSampleRate\":\(tapFormat?.sampleRate ?? 0),\"tapFormatChannels\":\(tapFormat?.channelCount ?? 0)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
        if let tapData = tapLogEntry.data(using: .utf8) {
            if let tapHandle = FileHandle(forWritingAtPath: logPath) { tapHandle.seekToEndOfFile(); tapHandle.write(tapData); tapHandle.closeFile() }
        }
        // #endregion
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, time in
            // #region agent log
            struct TapCallbackTracker { nonisolated(unsafe) static var count = 0; nonisolated(unsafe) static var firstLogged = false }
            TapCallbackTracker.count += 1
            if !TapCallbackTracker.firstLogged || TapCallbackTracker.count <= 5 {
                TapCallbackTracker.firstLogged = true
                let selfIsNil = self == nil
                let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
                let logEntry = "{\"hypothesisId\":\"F\",\"location\":\"MicrophoneCaptureEngine.tapCallback\",\"message\":\"Tap callback fired\",\"data\":{\"selfIsNil\":\(selfIsNil),\"callCount\":\(TapCallbackTracker.count),\"frameLength\":\(buffer.frameLength)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
                if let data = logEntry.data(using: .utf8) {
                    if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
                    if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
                }
            }
            // #endregion
            self?.handleAudioBuffer(buffer, time: time)
        }
        
        // #region agent log
        let preStartEntry = "{\"hypothesisId\":\"D\",\"location\":\"MicrophoneCaptureEngine.start\",\"message\":\"About to start audioEngine\",\"data\":{},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
        if let preStartData = preStartEntry.data(using: .utf8) {
            if let preStartHandle = FileHandle(forWritingAtPath: logPath) { preStartHandle.seekToEndOfFile(); preStartHandle.write(preStartData); preStartHandle.closeFile() }
        }
        // #endregion
        
        do {
            try audioEngine.start()
            isRunning = true
            
            // #region agent log
            print("[MUESLI_DEBUG] AVAudioEngine started successfully")
            let engineIsRunning = audioEngine.isRunning
            let logEntry2 = "{\"hypothesisId\":\"G\",\"location\":\"MicrophoneCaptureEngine.start\",\"message\":\"AVAudioEngine started\",\"data\":{\"isRunning\":true,\"engineActuallyRunning\":\(engineIsRunning)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let data2 = logEntry2.data(using: .utf8) {
                if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
                if let handle2 = FileHandle(forWritingAtPath: logPath) { handle2.seekToEndOfFile(); handle2.write(data2); handle2.closeFile() }
            }
            // #endregion
        } catch {
            // #region agent log
            print("[MUESLI_DEBUG] AVAudioEngine FAILED to start: \(error)")
            let errorEntry = "{\"hypothesisId\":\"G\",\"location\":\"MicrophoneCaptureEngine.start\",\"message\":\"AVAudioEngine FAILED to start\",\"data\":{\"error\":\"\(error.localizedDescription)\"},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let errorData = errorEntry.data(using: .utf8) {
                if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
                if let errorHandle = FileHandle(forWritingAtPath: logPath) { errorHandle.seekToEndOfFile(); errorHandle.write(errorData); errorHandle.closeFile() }
            }
            // #endregion
            throw error
        }
        
        // #region agent log
        // Schedule a delayed check to see if tap is firing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let checkEntry = "{\"hypothesisId\":\"H\",\"location\":\"MicrophoneCaptureEngine.start\",\"message\":\"Delayed tap check (1s after start)\",\"data\":{\"engineRunning\":\(self.audioEngine.isRunning),\"isRunningFlag\":\(self.isRunning)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let checkData = checkEntry.data(using: .utf8) {
                if let checkHandle = FileHandle(forWritingAtPath: logPath) { checkHandle.seekToEndOfFile(); checkHandle.write(checkData); checkHandle.closeFile() }
            }
        }
        // #endregion
    }
    
    func stop() {
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let wasRunning = isRunning
        let stopEntry = "{\"hypothesisId\":\"F\",\"location\":\"MicrophoneCaptureEngine.stop\",\"message\":\"Stop called\",\"data\":{\"wasRunning\":\(wasRunning)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
        if let stopData = stopEntry.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
            if let stopHandle = FileHandle(forWritingAtPath: logPath) { stopHandle.seekToEndOfFile(); stopHandle.write(stopData); stopHandle.closeFile() }
        }
        // #endregion
        
        guard isRunning else { return }
        
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
        
        // #region agent log
        let stoppedEntry = "{\"hypothesisId\":\"F\",\"location\":\"MicrophoneCaptureEngine.stop\",\"message\":\"Engine stopped\",\"data\":{\"isRunning\":\(isRunning)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
        if let stoppedData = stoppedEntry.data(using: .utf8) {
            if let stoppedHandle = FileHandle(forWritingAtPath: logPath) { stoppedHandle.seekToEndOfFile(); stoppedHandle.write(stoppedData); stoppedHandle.closeFile() }
        }
        // #endregion
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
                    print("[MUESLI_DEBUG] Selected real microphone with ID: \(audioDeviceID), UID: \(uid)")
                    return
                } catch {
                    print("[MUESLI_DEBUG] Failed to set device \(audioDeviceID): \(error)")
                    continue
                }
            }
        }
        
        print("[MUESLI_DEBUG] WARNING: Could not find a real microphone device")
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
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // #region agent log
        struct FirstCallTracker { nonisolated(unsafe) static var firstCallLogged = false }
        if !FirstCallTracker.firstCallLogged {
            FirstCallTracker.firstCallLogged = true
            let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
            let logEntry = "{\"hypothesisId\":\"D\",\"location\":\"MicrophoneCaptureEngine.handleAudioBuffer\",\"message\":\"FIRST tap callback invoked\",\"data\":{\"frameLength\":\(buffer.frameLength),\"channelCount\":\(buffer.format.channelCount),\"sampleRate\":\(buffer.format.sampleRate)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let data = logEntry.data(using: .utf8) {
                if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
                if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
            }
        }
        // #endregion
        
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
        
        // #region agent log
        struct MicBufferLogCounter { nonisolated(unsafe) static var count = 0 }
        MicBufferLogCounter.count += 1
        if MicBufferLogCounter.count <= 5 || MicBufferLogCounter.count % 500 == 0 {
            print("[MUESLI_DEBUG] Mic buffer #\(MicBufferLogCounter.count): frameLength=\(frameLength), rms=\(rms), level=\(level)")
            let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
            let logEntry = "{\"hypothesisId\":\"B\",\"location\":\"handleAudioBuffer\",\"message\":\"Mic buffer\",\"data\":{\"bufferNum\":\(MicBufferLogCounter.count),\"frameLength\":\(frameLength),\"rms\":\(rms),\"level\":\(level)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let data = logEntry.data(using: .utf8) {
                if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
                else if FileManager.default.createFile(atPath: logPath, contents: data, attributes: nil) { /* created */ }
            }
        }
        // #endregion
        
        levelHandler?(level)
        
        // Convert AVAudioPCMBuffer to CMSampleBuffer for compatibility
        if let sampleBuffer = createCMSampleBuffer(from: buffer, time: time) {
            // #region agent log
            if MicBufferLogCounter.count <= 5 || MicBufferLogCounter.count % 500 == 0 {
                let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
                let logEntry = "{\"hypothesisId\":\"C\",\"location\":\"MicrophoneCaptureEngine.handleAudioBuffer\",\"message\":\"CMSampleBuffer created successfully\",\"data\":{\"bufferNum\":\(MicBufferLogCounter.count),\"frameLength\":\(frameLength)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
                if let data = logEntry.data(using: .utf8) {
                    if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
                }
            }
            // #endregion
            bufferHandler?(sampleBuffer)
        } else {
            // #region agent log
            print("[MUESLI_DEBUG] createCMSampleBuffer returned nil, frameLength=\(frameLength)")
            let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
            let logEntry = "{\"hypothesisId\":\"C\",\"location\":\"MicrophoneCaptureEngine.handleAudioBuffer\",\"message\":\"createCMSampleBuffer returned nil\",\"data\":{\"bufferNum\":\(MicBufferLogCounter.count),\"frameLength\":\(frameLength)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let data = logEntry.data(using: .utf8) {
                if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
            }
            // #endregion
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
        let hostTime = time.audioTimeStamp.mHostTime
        let timestamp = hostTime > 0 ? Double(hostTime) / 1_000_000_000.0 : CACurrentMediaTime()
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
        
        // #region agent log
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
        
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let bufferHandlerIsNil = bufferHandler == nil
        let logEntry0 = "{\"hypothesisId\":\"B\",\"location\":\"AudioCaptureService.startCaptureWithFilter\",\"message\":\"About to create MicrophoneCaptureEngine\",\"data\":{\"bufferHandlerIsNil\":\(bufferHandlerIsNil)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
        if let data0 = logEntry0.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
            if let handle0 = FileHandle(forWritingAtPath: logPath) { handle0.seekToEndOfFile(); handle0.write(data0); handle0.closeFile() }
        }
        // #endregion
        
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
                // #region agent log
                struct MicHandlerLogCounter { nonisolated(unsafe) static var count = 0 }
                MicHandlerLogCounter.count += 1
                if MicHandlerLogCounter.count <= 5 || MicHandlerLogCounter.count % 200 == 0 {
                    let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
                    let handlerIsNil = micHandler == nil
                    let logEntry = "{\"hypothesisId\":\"B\",\"location\":\"MicrophoneCaptureEngine.bufferHandler\",\"message\":\"Mic buffer callback invoked\",\"data\":{\"bufferNum\":\(MicHandlerLogCounter.count),\"handlerIsNil\":\(handlerIsNil)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
                    if let data = logEntry.data(using: .utf8) {
                        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
                        if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
                    }
                }
                // #endregion
                micHandler?(buffer, .microphone)
            },
            levelHandler: { level in
                micLevelHandler?(level, .microphone)
            }
        )
        
        do {
            // #region agent log
            print("[MUESLI_DEBUG] About to start MicrophoneCaptureEngine with deviceID: \(selectedMicrophoneDeviceID ?? "nil")")
            // #endregion
            try micEngine.start(deviceID: selectedMicrophoneDeviceID)
            self.microphoneEngine = micEngine
            // #region agent log
            print("[MUESLI_DEBUG] MicrophoneCaptureEngine started successfully")
            // #endregion
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
            
            // #region agent log
            print("[MUESLI_DEBUG] MicrophoneCaptureEngine FAILED: \(error.localizedDescription)")
            let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
            let failEntry = "{\"hypothesisId\":\"CRITICAL\",\"location\":\"AudioCaptureService.startCaptureWithFilter\",\"message\":\"MicrophoneCaptureEngine FAILED to start\",\"data\":{\"error\":\"\(error.localizedDescription)\"},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let failData = failEntry.data(using: .utf8) {
                if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
                if let failHandle = FileHandle(forWritingAtPath: logPath) { failHandle.seekToEndOfFile(); failHandle.write(failData); failHandle.closeFile() }
            }
            // #endregion
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
        
        // #region agent log
        // Check raw SCK buffer for non-zero data
        struct SCKLogCounter { nonisolated(unsafe) static var count = 0 }
        SCKLogCounter.count += 1
        if SCKLogCounter.count <= 3 || SCKLogCounter.count % 100 == 0 {
            var maxSample: Float = 0.0
            var bufferLength = 0
            var formatInfo = ""
            if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
                bufferLength = length
                if status == noErr, let data = dataPointer {
                    let floatPointer = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
                    let floatCount = length / 4
                    for i in 0..<min(floatCount, 100) {
                        let absVal = abs(floatPointer[i])
                        if absVal > maxSample { maxSample = absVal }
                    }
                }
            }
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
                formatInfo = "sr=\(asbd.mSampleRate),ch=\(asbd.mChannelsPerFrame),bits=\(asbd.mBitsPerChannel)"
            }
            let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
            let typeStr = type == .audio ? "system" : "other"
            let logEntry = "{\"hypothesisId\":\"E\",\"location\":\"StreamOutput.didOutputSampleBuffer\",\"message\":\"SCK buffer received\",\"data\":{\"type\":\"\(typeStr)\",\"maxSample\":\(maxSample),\"bufferLength\":\(bufferLength),\"format\":\"\(formatInfo)\",\"bufferNum\":\(SCKLogCounter.count)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let data = logEntry.data(using: .utf8) {
                if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
                if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
            }
        }
        // #endregion
        
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
