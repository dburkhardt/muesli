import Foundation
import WhisperKit
@preconcurrency import AVFoundation
import CoreMedia
import os.lock

/// Service for real-time audio transcription using WhisperKit
/// Handles both system audio ("Them") and microphone audio ("Me")
final class TranscriptionService: @unchecked Sendable, TranscriptionServiceProtocol {
    
    // MARK: - Types
    
    /// Transcription mode: live (real-time) or post-processing (after recording)
    enum TranscriptionMode: String, Sendable {
        case live = "live"
        case postProcessing = "postProcessing"
    }
    
    /// Represents a transcribed segment with speaker info
    struct TranscriptSegment: Sendable {
        let text: String
        let timestamp: TimeInterval
        let speaker: Speaker
        
        enum Speaker: String, Sendable {
            case me = "Me"
            case them = "Them"
        }
    }
    
    /// Callback for new transcript segments
    typealias TranscriptHandler = @Sendable (TranscriptSegment) -> Void
    
    // MARK: - Properties
    
    private var whisperKit: WhisperKit?
    private var isInitialized = false
    private var transcriptHandler: TranscriptHandler?
    
    /// Current transcription mode
    var transcriptionMode: TranscriptionMode = .live
    
    // Audio buffers for chunked processing (protected state)
    private struct BufferState {
        var systemAudioBuffer: [Float] = []
        var micAudioBuffer: [Float] = []
        var isProcessing: Bool = false
        var recordingStartTime: Date?
        // Overlap tracking: track how many samples have been processed
        var systemProcessedSamples: Int = 0
        var micProcessedSamples: Int = 0
    }
    private let bufferState = OSAllocatedUnfairLock(initialState: BufferState())
    
    // Processing state
    private var processingTask: Task<Void, Never>?
    
    // Configuration (using centralized AudioConfiguration)
    private let chunkDuration: TimeInterval = AudioConfiguration.transcriptionChunkDuration
    private let overlapDuration: TimeInterval = AudioConfiguration.transcriptionOverlapDuration
    private let sampleRate: Int = AudioConfiguration.whisperSampleRate
    private let minSamplesForProcessing: Int  // Minimum samples before processing
    private let overlapSamples: Int  // Samples to overlap between chunks
    
    // VAD configuration
    private let vadThreshold: Float = AudioConfiguration.vadThreshold
    
    // MARK: - Initialization
    
    init() {
        minSamplesForProcessing = AudioConfiguration.minSamplesForProcessing
        overlapSamples = AudioConfiguration.overlapSamples
    }
    
    // MARK: - Setup
    
    /// Initialize WhisperKit with the specified model path
    /// - Parameter modelPath: Path to the WhisperKit model directory (required)
    @MainActor
    func initialize(modelPath: URL) async throws {
        guard !isInitialized else { return }
        
        // Use Application Support for all WhisperKit storage to avoid Documents folder prompts
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let muesliDir = appSupport.appendingPathComponent("Muesli", isDirectory: true)
        
        // Create config with explicit downloadBase and tokenizerFolder in Application Support
        // This prevents WhisperKit/Hub from defaulting to ~/Documents/huggingface
        let config = WhisperKitConfig(
            downloadBase: muesliDir,
            modelFolder: modelPath.path,
            tokenizerFolder: muesliDir.appendingPathComponent("Tokenizers"),
            verbose: false,
            download: false  // Don't download since we're using a local model
        )
        
        // Initialize WhisperKit with optimized configuration for Apple Silicon
        whisperKit = try await WhisperKit(config)
        isInitialized = true
    }
    
    /// Set transcription mode (live or post-processing)
    func setTranscriptionMode(_ mode: TranscriptionMode) {
        transcriptionMode = mode
    }
    
    /// Set the handler for new transcript segments
    func setTranscriptHandler(_ handler: @escaping TranscriptHandler) {
        transcriptHandler = handler
    }
    
    // MARK: - Recording Control
    
    /// Start transcription processing
    func startTranscription(recordingStartTime: Date) {
        bufferState.withLock { state in
            state.recordingStartTime = recordingStartTime
            state.systemAudioBuffer.removeAll()
            state.micAudioBuffer.removeAll()
            state.systemProcessedSamples = 0
            state.micProcessedSamples = 0
            state.isProcessing = true
        }
        
        // Start background processing loop only for live mode
        if transcriptionMode == .live {
            startProcessingLoop()
        }
    }
    
    /// Stop transcription processing
    func stopTranscription() async {
        // Signal the processing loop to stop (it checks isProcessing each iteration)
        bufferState.withLock { state in
            state.isProcessing = false
        }
        
        // Wait for the processing task to complete gracefully instead of cancelling
        // This allows any in-flight WhisperKit transcription to finish
        if let task = processingTask {
            await task.value  // Wait for task to complete instead of cancelling
        }
        processingTask = nil
        
        // Process any remaining audio
        await processRemainingAudio()
    }
    
    // MARK: - Audio Input
    
    /// Append audio samples from system audio (meeting participants)
    /// - Parameter samples: Float32 audio samples at 16kHz mono
    func appendSystemAudio(_ samples: [Float]) {
        bufferState.withLock { state in
            guard state.isProcessing else { return }
            state.systemAudioBuffer.append(contentsOf: samples)
        }
    }
    
    /// Append audio samples from microphone (user's voice)
    /// - Parameter samples: Float32 audio samples at 16kHz mono
    func appendMicrophoneAudio(_ samples: [Float]) {
        bufferState.withLock { state in
            guard state.isProcessing else { return }
            state.micAudioBuffer.append(contentsOf: samples)
        }
    }
    
    // MARK: - Processing
    
    private func startProcessingLoop() {
        processingTask = Task.detached { [weak self] in
            while true {
                guard let self = self else { break }
                let isStillProcessing = self.bufferState.withLock { $0.isProcessing }
                guard isStillProcessing else { break }
                
                await self.processBuffers()
                try? await Task.sleep(nanoseconds: 500_000_000)  // Check every 0.5s
            }
        }
    }
    
    private func processBuffers() async {
        guard isInitialized, let whisperKit = whisperKit else { return }
        
        // Skip processing if in post-processing mode
        guard transcriptionMode == .live else { return }
        
        // Get chunks to process with overlap
        let (systemChunk, micChunk, startTime, systemOffset, micOffset) = bufferState.withLock { state -> ([Float]?, [Float]?, Date, Int, Int) in
            var sysChunk: [Float]?
            var micChunk: [Float]?
            let time = state.recordingStartTime ?? Date()
            var sysOffset = 0
            var micOffset = 0
            
            // Extract system audio chunk with overlap
            if state.systemAudioBuffer.count >= minSamplesForProcessing {
                // For first chunk, start at 0. For subsequent chunks, include overlap
                let startIndex = state.systemProcessedSamples > 0 ? max(0, state.systemProcessedSamples - overlapSamples) : 0
                let endIndex = startIndex + minSamplesForProcessing
                
                if endIndex <= state.systemAudioBuffer.count {
                    sysChunk = Array(state.systemAudioBuffer[startIndex..<endIndex])
                    sysOffset = startIndex
                    // Remove samples up to endIndex (but keep overlap for next chunk)
                    let samplesToRemove = endIndex - overlapSamples
                    if samplesToRemove > 0 {
                        state.systemAudioBuffer.removeFirst(samplesToRemove)
                        state.systemProcessedSamples = overlapSamples
                    } else {
                        state.systemAudioBuffer.removeFirst(endIndex)
                        state.systemProcessedSamples = 0
                    }
                }
            }
            
            // Extract mic audio chunk with overlap
            if state.micAudioBuffer.count >= minSamplesForProcessing {
                let startIndex = state.micProcessedSamples > 0 ? max(0, state.micProcessedSamples - overlapSamples) : 0
                let endIndex = startIndex + minSamplesForProcessing
                
                if endIndex <= state.micAudioBuffer.count {
                    micChunk = Array(state.micAudioBuffer[startIndex..<endIndex])
                    micOffset = startIndex
                    let samplesToRemove = endIndex - overlapSamples
                    if samplesToRemove > 0 {
                        state.micAudioBuffer.removeFirst(samplesToRemove)
                        state.micProcessedSamples = overlapSamples
                    } else {
                        state.micAudioBuffer.removeFirst(endIndex)
                        state.micProcessedSamples = 0
                    }
                }
            }
            
            return (sysChunk, micChunk, time, sysOffset, micOffset)
        }
        
        // Process system audio ("Them") with VAD check
        if let chunk = systemChunk, hasVoiceActivity(chunk) {
            await transcribeChunk(chunk, speaker: .them, whisperKit: whisperKit, startTime: startTime, offset: systemOffset)
        }
        
        // Process mic audio ("Me") with VAD check
        if let chunk = micChunk, hasVoiceActivity(chunk) {
            await transcribeChunk(chunk, speaker: .me, whisperKit: whisperKit, startTime: startTime, offset: micOffset)
        }
    }
    
    private func processRemainingAudio() async {
        guard isInitialized, let whisperKit = whisperKit else { return }
        
        let (remainingSystem, remainingMic, startTime) = bufferState.withLock { state -> ([Float], [Float], Date) in
            let sys = state.systemAudioBuffer
            let mic = state.micAudioBuffer
            let time = state.recordingStartTime ?? Date()
            state.systemAudioBuffer.removeAll()
            state.micAudioBuffer.removeAll()
            return (sys, mic, time)
        }
        
        // Process remaining system audio
        if !remainingSystem.isEmpty {
            await transcribeChunk(remainingSystem, speaker: .them, whisperKit: whisperKit, startTime: startTime)
        }
        
        // Process remaining mic audio
        if !remainingMic.isEmpty {
            await transcribeChunk(remainingMic, speaker: .me, whisperKit: whisperKit, startTime: startTime)
        }
    }
    
    private func transcribeChunk(_ samples: [Float], speaker: TranscriptSegment.Speaker, whisperKit: WhisperKit, startTime: Date, offset: Int = 0) async {
        do {
            // Transcribe the audio chunk
            let results = try await whisperKit.transcribe(audioArray: samples)
            
            guard let result = results.first, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            
            // Calculate timestamp relative to recording start, accounting for offset
            let offsetTime = Double(offset) / Double(sampleRate)
            let timestamp = Date().timeIntervalSince(startTime) + offsetTime
            
            let segment = TranscriptSegment(
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: timestamp,
                speaker: speaker
            )
            
            // Notify handler
            transcriptHandler?(segment)
            
        } catch {
            print("[TranscriptionService] Transcription error: \(error)")
        }
    }
    
    // MARK: - Voice Activity Detection
    
    /// Check if audio chunk has voice activity (not silent)
    private func hasVoiceActivity(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        
        // Calculate RMS (Root Mean Square) energy
        let sumSquares = samples.reduce(0.0) { $0 + ($1 * $1) }
        let rms = sqrt(sumSquares / Float(samples.count))
        
        // Return true if RMS exceeds threshold
        return rms > vadThreshold
    }
    
    // MARK: - Post-Processing Transcription
    
    /// Transcribe entire audio files after recording (post-processing mode)
    /// - Parameters:
    ///   - systemAudioURL: URL to system audio file
    ///   - micAudioURL: URL to microphone audio file
    ///   - startTime: Recording start time for timestamp calculation
    func transcribePostProcessing(systemAudioURL: URL?, micAudioURL: URL?, startTime: Date) async throws {
        guard isInitialized, let whisperKit = whisperKit else {
            throw NSError(domain: "TranscriptionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit not initialized"])
        }
        
        // Transcribe system audio if available
        if let systemURL = systemAudioURL {
            if let samples = await loadAudioFile(url: systemURL) {
                let results = try await whisperKit.transcribe(audioArray: samples)
                
                for result in results where !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let segment = TranscriptSegment(
                        text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        timestamp: 0, // Will be updated based on result timestamps if available
                        speaker: .them
                    )
                    transcriptHandler?(segment)
                }
            }
        }
        
        // Transcribe mic audio if available
        if let micURL = micAudioURL {
            if let samples = await loadAudioFile(url: micURL) {
                let results = try await whisperKit.transcribe(audioArray: samples)
                
                for result in results where !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let segment = TranscriptSegment(
                        text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        timestamp: 0,
                        speaker: .me
                    )
                    transcriptHandler?(segment)
                }
            }
        }
    }
    
    /// Load audio file and convert to Float32 samples at 16kHz mono
    ///
    /// - Warning: AVAudioConverter returns different status codes that must be handled correctly:
    ///   - `.haveData` (rawValue 0): Output buffer has data, more input available
    ///   - `.inputRanDry` (rawValue 1): Input exhausted BUT output buffer has valid data - THIS IS SUCCESS!
    ///   - `.endOfStream` (rawValue 2): End of stream reached
    ///   - `.error` (rawValue 3): An error occurred
    ///   See: https://developer.apple.com/documentation/avfaudio/avaudioconverteroutputstatus
    private func loadAudioFile(url: URL) async -> [Float]? {
        do {
            let file = try AVAudioFile(forReading: url)
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            
            guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
                print("[TranscriptionService] Failed to create audio converter")
                return nil
            }
            
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: inputBuffer)
            
            let outputFrameCount = Int(Double(inputBuffer.frameLength) * targetFormat.sampleRate / file.processingFormat.sampleRate)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(outputFrameCount)) else {
                return nil
            }
            
            var error: NSError?
            let inputBufferRef = inputBuffer  // Capture for closure
            var inputProvided = OSAllocatedUnfairLock(initialState: false)
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                let wasProvided = inputProvided.withLock { provided in
                    if !provided {
                        provided = true
                        return false
                    }
                    return true
                }
                if !wasProvided {
                    outStatus.pointee = .haveData
                    return inputBufferRef
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            
            // IMPORTANT: Accept both .haveData AND .inputRanDry as valid statuses!
            // .inputRanDry (rawValue 1) means input was exhausted but output buffer contains valid data.
            // This is a SUCCESSFUL conversion - the output is ready to use.
            // Bug fix: Previously only checked for .haveData, which incorrectly rejected valid conversions.
            let isValidStatus = (status == .haveData || status == .inputRanDry)
            guard isValidStatus, let floatChannelData = outputBuffer.floatChannelData else {
                print("[TranscriptionService] Conversion failed: \(error?.localizedDescription ?? "unknown error")")
                return nil
            }
            
            let frameLength = Int(outputBuffer.frameLength)
            return Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
            
        } catch {
            print("[TranscriptionService] Failed to load audio file: \(error)")
            return nil
        }
    }
}

// MARK: - Audio Resampling Utilities

extension TranscriptionService {
    
    /// Convert Int16 CMSampleBuffer (microphone) to Float32 samples at 16kHz mono
    /// Handles stereo to mono conversion if needed
    /// - Parameter sampleBuffer: The audio sample buffer containing Int16 samples
    /// - Returns: Float32 samples at 16kHz mono, or nil if conversion fails
    static func convertInt16ToWhisperFormat(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        // Get format info
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let bitsPerChannel = Int(asbd.pointee.mBitsPerChannel)
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }
        
        // Calculate sample count
        let bytesPerSample = bitsPerChannel / 8
        let totalSamples = length / bytesPerSample
        let frameCount = totalSamples / channelCount
        
        var floatSamples: [Float]
        
        if isFloat && bitsPerChannel == 32 {
            // Already Float32 - just extract and convert stereo to mono
            let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: totalSamples)
            if channelCount == 2 {
                floatSamples = (0..<frameCount).map { i in
                    (floatPointer[i * 2] + floatPointer[i * 2 + 1]) / 2.0
                }
            } else {
                floatSamples = Array(UnsafeBufferPointer(start: floatPointer, count: frameCount))
            }
        } else if !isFloat && bitsPerChannel == 16 {
            // Int16 - convert to Float32 and optionally stereo to mono
            let int16Pointer = UnsafeRawPointer(data).bindMemory(to: Int16.self, capacity: totalSamples)
            
            if channelCount == 2 {
                // Stereo to mono: average left and right channels
                floatSamples = (0..<frameCount).map { i in
                    let left = Float(int16Pointer[i * 2]) / Float(Int16.max)
                    let right = Float(int16Pointer[i * 2 + 1]) / Float(Int16.max)
                    return (left + right) / 2.0
                }
            } else {
                // Mono: just convert
                floatSamples = (0..<frameCount).map { i in
                    Float(int16Pointer[i]) / Float(Int16.max)
                }
            }
        } else {
            return nil
        }
        
        return floatSamples
    }
    
    /// Convert CMSampleBuffer to Float32 samples at 16kHz mono using AVAudioConverter for high-quality resampling
    /// - Parameters:
    ///   - sampleBuffer: The audio sample buffer
    ///   - sourceSampleRate: Original sample rate (e.g., 48000 or 24000)
    ///   - sourceChannels: Number of source channels (1 or 2)
    /// - Returns: Resampled Float32 samples at 16kHz mono, or nil if conversion fails
    static func resampleToWhisperFormat(
        _ sampleBuffer: CMSampleBuffer,
        sourceSampleRate: Double,
        sourceChannels: Int
    ) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }
        
        // Convert bytes to Float32 samples
        // Note: CMSampleBuffer from ScreenCaptureKit provides interleaved audio
        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        let rawSamples = Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))
        
        // Use AVAudioConverter for high-quality resampling
        // Note: rawSamples are interleaved if stereo, so we need to handle that
        return resampleWithAVAudioConverter(
            samples: rawSamples,
            sourceSampleRate: sourceSampleRate,
            sourceChannels: sourceChannels,
            targetSampleRate: 16000,
            targetChannels: 1,
            isInterleaved: true  // CMSampleBuffer provides interleaved audio
        )
    }
    
    /// Resample audio samples using AVAudioConverter
    /// - Parameters:
    ///   - samples: Input samples (mono or stereo, interleaved or not)
    ///   - sourceSampleRate: Source sample rate
    ///   - sourceChannels: Number of source channels
    ///   - targetSampleRate: Target sample rate
    ///   - targetChannels: Number of target channels
    ///   - isInterleaved: Whether input samples are interleaved
    /// - Returns: Resampled samples, or nil if conversion fails
    static func resampleSamples(
        samples: [Float],
        sourceSampleRate: Double,
        sourceChannels: Int,
        targetSampleRate: Double,
        targetChannels: Int,
        isInterleaved: Bool = false
    ) -> [Float]? {
        return resampleWithAVAudioConverter(
            samples: samples,
            sourceSampleRate: sourceSampleRate,
            sourceChannels: sourceChannels,
            targetSampleRate: targetSampleRate,
            targetChannels: targetChannels,
            isInterleaved: isInterleaved
        )
    }
    
    /// High-quality resampling using AVAudioConverter
    private static func resampleWithAVAudioConverter(
        samples: [Float],
        sourceSampleRate: Double,
        sourceChannels: Int,
        targetSampleRate: Double,
        targetChannels: Int,
        isInterleaved: Bool = false
    ) -> [Float]? {
        // If no conversion needed, return as-is (but convert stereo to mono if needed)
        if sourceSampleRate == targetSampleRate && sourceChannels == targetChannels {
            return samples
        }
        
        // Create source format (non-interleaved for AVAudioPCMBuffer)
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: AVAudioChannelCount(sourceChannels),
            interleaved: false
        ) else {
            return fallbackResample(samples: samples, sourceSampleRate: sourceSampleRate, sourceChannels: sourceChannels, targetSampleRate: targetSampleRate, targetChannels: targetChannels)
        }
        
        // Create target format
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannels),
            interleaved: false
        ) else {
            return fallbackResample(samples: samples, sourceSampleRate: sourceSampleRate, sourceChannels: sourceChannels, targetSampleRate: targetSampleRate, targetChannels: targetChannels)
        }
        
        // Create converter
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return fallbackResample(samples: samples, sourceSampleRate: sourceSampleRate, sourceChannels: sourceChannels, targetSampleRate: targetSampleRate, targetChannels: targetChannels)
        }
        
        // Create input buffer
        let frameCount = samples.count / sourceChannels
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return fallbackResample(samples: samples, sourceSampleRate: sourceSampleRate, sourceChannels: sourceChannels, targetSampleRate: targetSampleRate, targetChannels: targetChannels)
        }
        
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Copy samples to input buffer (deinterleave if needed)
        guard let channelData = inputBuffer.floatChannelData else {
            return fallbackResample(samples: samples, sourceSampleRate: sourceSampleRate, sourceChannels: sourceChannels, targetSampleRate: targetSampleRate, targetChannels: targetChannels)
        }
        
        if sourceChannels == 1 {
            samples.withUnsafeBufferPointer { ptr in
                channelData[0].update(from: ptr.baseAddress!, count: frameCount)
            }
        } else {
            // Deinterleave stereo samples
            if isInterleaved {
                // Samples are interleaved: L R L R L R...
                for i in 0..<frameCount {
                    channelData[0][i] = samples[i * 2]
                    channelData[1][i] = samples[i * 2 + 1]
                }
            } else {
                // Samples are already deinterleaved (unlikely but handle it)
                let halfCount = samples.count / 2
                samples.withUnsafeBufferPointer { ptr in
                    channelData[0].update(from: ptr.baseAddress!, count: halfCount)
                }
                samples[halfCount...].withUnsafeBufferPointer { ptr in
                    channelData[1].update(from: ptr.baseAddress!, count: halfCount)
                }
            }
        }
        
        // Calculate output buffer size
        let outputFrameCount = Int(Double(frameCount) * targetSampleRate / sourceSampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(outputFrameCount)) else {
            return fallbackResample(samples: samples, sourceSampleRate: sourceSampleRate, sourceChannels: sourceChannels, targetSampleRate: targetSampleRate, targetChannels: targetChannels)
        }
        
        // Convert
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        guard status == .haveData, let outputChannelData = outputBuffer.floatChannelData else {
            return fallbackResample(samples: samples, sourceSampleRate: sourceSampleRate, sourceChannels: sourceChannels, targetSampleRate: targetSampleRate, targetChannels: targetChannels)
        }
        
        // Extract mono output
        let outputFrames = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: outputChannelData[0], count: outputFrames))
    }
    
    /// Fallback resampling using simple linear interpolation (used if AVAudioConverter fails)
    private static func fallbackResample(
        samples: [Float],
        sourceSampleRate: Double,
        sourceChannels: Int,
        targetSampleRate: Double,
        targetChannels: Int
    ) -> [Float] {
        var processed = samples
        
        // Convert stereo to mono if needed
        if sourceChannels == 2 && targetChannels == 1 {
            processed = stereoToMono(processed)
        }
        
        // Resample if needed
        if sourceSampleRate != targetSampleRate {
            processed = simpleResample(processed, from: sourceSampleRate, to: targetSampleRate)
        }
        
        return processed
    }
    
    /// Convert stereo samples to mono by averaging channels
    private static func stereoToMono(_ samples: [Float]) -> [Float] {
        var mono: [Float] = []
        mono.reserveCapacity(samples.count / 2)
        
        for i in stride(from: 0, to: samples.count - 1, by: 2) {
            let avg = (samples[i] + samples[i + 1]) / 2.0
            mono.append(avg)
        }
        
        return mono
    }
    
    /// Simple linear interpolation resampling (fallback)
    private static func simpleResample(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        let ratio = sourceSampleRate / targetSampleRate
        let targetCount = Int(Double(samples.count) / ratio)
        
        var resampled: [Float] = []
        resampled.reserveCapacity(targetCount)
        
        for i in 0..<targetCount {
            let sourceIndex = Double(i) * ratio
            let lowerIndex = Int(sourceIndex)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourceIndex - Double(lowerIndex))
            
            let interpolated = samples[lowerIndex] * (1 - fraction) + samples[upperIndex] * fraction
            resampled.append(interpolated)
        }
        
        return resampled
    }
}
