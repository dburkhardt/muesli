import Foundation
import os.lock
import QuartzCore

// #region agent log - Debug file logging helper
private func debugLog(_ message: String, hypothesisId: String, data: [String: Any] = [:]) {
    let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    let location = "EchoCancellationServiceWebRTC.swift"
    var payload: [String: Any] = [
        "timestamp": timestamp,
        "location": location,
        "message": message,
        "sessionId": "debug-session",
        "hypothesisId": hypothesisId
    ]
    if !data.isEmpty {
        payload["data"] = data
    }
    if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        let line = jsonString + "\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }
}
// #endregion

/// WebRTC AEC3 implementation with hybrid synchronization:
/// - Swift handles coarse timing alignment (250-350ms offset)
/// - WebRTC handles fine-grained delay estimation and echo cancellation
///
/// CRITICAL: This implementation ACTUALLY USES the calculated offset to align
/// render/capture frames before feeding to WebRTC.
///
/// Architecture:
/// ```
/// Mic (AVAudioEngine):    ┃━━━━━━━━━━━━━━━━━━━━━━━━━━━┃
///                         ↑ Arrives first
///
/// System Audio (SCK):                 ┃━━━━━━━━━━━━━━━━┃
///                                     ↑ Arrives 250-350ms LATER
/// ```
///
/// WebRTC AEC3 expects render (system) before capture (mic) with max ~128ms offset.
/// The hybrid approach lets Swift handle the coarse alignment while WebRTC handles
/// fine-grained delay estimation and actual echo cancellation.
final class EchoCancellationServiceWebRTC: @unchecked Sendable, EchoCancellationServiceProtocol {
    
    // MARK: - Configuration
    
    private let sampleRate: Int = 48000
    private let frameSize: Int = 480  // 10ms at 48kHz (WebRTC requirement)
    private let maxBufferMs: Int = 500  // 500ms = 24000 samples
    private let maxBufferSamples: Int = 24000
    
    // ACOUSTIC ECHO DELAY: Time for sound to travel from speaker to mic
    // This is DIFFERENT from callback timing or sample count offsets!
    // Typical values: 30-100ms for laptop speakers/mic, 50-150ms for external speakers
    // This offset ensures we read OLDER render samples to match the echo in current mic
    private let acousticEchoDelayMs: Int = 60  // 60ms default - adjust if needed
    private var acousticEchoDelaySamples: Int { acousticEchoDelayMs * sampleRate / 1000 }
    
    // MARK: - State (Thread-Safe)
    
    private struct SyncState {
        // Ring buffers for coarse alignment (pre-allocated, no runtime allocations)
        var systemRingBuffer: AudioRingBuffer
        var micRingBuffer: AudioRingBuffer
        
        // Sample counters for alignment
        var totalSystemSamples: Int64 = 0
        var totalMicSamples: Int64 = 0
        var deliveryOffsetSamples: Int64 = 0
        var offsetCalculated: Bool = false
        
        // Warmup tracking
        var systemBufferTimes: [Double] = []
        var micBufferTimes: [Double] = []
        static let kBuffersToAverage = 12
        
        // Gap detection
        var lastSystemBufferTime: Double = 0
        var systemBufferCount: Int = 0
        var totalGapSamples: Int64 = 0
        var silenceScratch: [Float] = []
        
        // Offset validation (Lesson 7)
        var offsetValidationCount: Int = 0
        static let kOffsetValidationInterval = 100  // Every 100 frames (~1 second)
        
        init(bufferCapacity: Int) {
            systemRingBuffer = AudioRingBuffer(capacity: bufferCapacity)
            micRingBuffer = AudioRingBuffer(capacity: bufferCapacity)
            silenceScratch = [Float](repeating: 0, count: bufferCapacity / 4)
        }
    }
    
    private let state: OSAllocatedUnfairLock<SyncState>
    private var aecBridge: WebRTCAECBridge?
    private var initializationError: Error?
    
    // Pre-allocated frame buffers (avoid allocation in audio callback)
    // Note: These are class-level but only accessed from processMicrophoneAudio()
    // which is called from AVAudioEngine's serial audio render thread. No concurrent access.
    // Each call creates local copies (Swift copy-on-write) before mutation, so thread-safe.
    private var renderFrame = [Float](repeating: 0, count: 480)
    private var captureFrame = [Float](repeating: 0, count: 480)
    private var outputFrame = [Float](repeating: 0, count: 480)
    
    // #region agent log - Debug log throttle counter
    private var debugLogCounter: Int = 0
    // #endregion
    
    // MARK: - Initialization
    
    init() {
        self.state = OSAllocatedUnfairLock(initialState: SyncState(bufferCapacity: 24000))
        
        // Initialize WebRTC bridge
        // In Swift, ObjC methods with NSError** are translated to throwing initializers
        do {
            self.aecBridge = try WebRTCAECBridge(sampleRate: Int32(sampleRate), channels: 1)
            Task { await DiagnosticLogger.shared.log(.aec,
                "WEBRTC_INIT_SUCCESS: AEC3 ready, frameSize=480") }
        } catch {
            self.aecBridge = nil
            self.initializationError = error as NSError
            Task { await DiagnosticLogger.shared.log(.aec,
                "WEBRTC_INIT_FAILED: \(error.localizedDescription)") }
        }
    }
    
    // MARK: - Public API
    
    /// Store system audio samples for echo cancellation reference
    /// Note: Input MUST be mono. RecordingController.extractSamples() performs stereo→mono conversion
    /// before calling storeSystemAudio(). ScreenCaptureKit delivers stereo, but by the time it
    /// reaches AEC service, it's already mono.
    func storeSystemAudio(samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard aecBridge?.isReady == true else { return }
        
        // Protocol signature matches existing protocol (no timestamps)
        // Implementation uses CACurrentMediaTime() internally for timing
        let monoSamples = samples
        let now = CACurrentMediaTime()
        
        // Extract data we need under lock, then process outside lock
        state.withLock { state in
            // Track timing for warmup offset calculation
            if state.systemBufferTimes.count < SyncState.kBuffersToAverage {
                state.systemBufferTimes.append(now)
            }
            
            // Gap detection (SCK drops buffers)
            if state.systemBufferCount > 0 {
                let elapsed = now - state.lastSystemBufferTime
                let expectedSamples = Int64(elapsed * Double(sampleRate))
                let actualSamples = Int64(monoSamples.count)
                let gapSamples = expectedSamples - actualSamples
                let gapThreshold: Int64 = 2400  // 50ms
                
                if gapSamples > gapThreshold {
                    // Fill gap with silence in ring buffer
                    let fillCount = min(Int(gapSamples), maxBufferSamples / 4)
                    // Use pre-allocated silence scratch buffer to avoid allocation in callback
                    let silence = state.silenceScratch.prefix(fillCount)
                    state.systemRingBuffer.push(Array(silence))
                    state.totalSystemSamples += Int64(fillCount)
                    state.totalGapSamples += Int64(fillCount)
                    
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_GAP: filled \(fillCount) samples of silence") }
                }
            }
            state.lastSystemBufferTime = now
            state.systemBufferCount += 1
            
            // Store in ring buffer
            state.systemRingBuffer.push(monoSamples)
            state.totalSystemSamples += Int64(monoSamples.count)
            
            // #region agent log (async, non-blocking) - periodic sample count tracking
            if state.systemBufferCount % 100 == 0 {
                let totalSys = state.totalSystemSamples
                let totalMic = state.totalMicSamples
                let sysAvail = state.systemRingBuffer.available
                let micAvail = state.micRingBuffer.available
                Task { await DiagnosticLogger.shared.log(.aec,
                    "AEC_SAMPLE_COUNTS: sysTotal=\(totalSys), micTotal=\(totalMic), diff=\(totalSys - totalMic), sysAvail=\(sysAvail), micAvail=\(micAvail)") }
            }
            // #endregion
        }
        
        // NOTE: We do NOT send render frames to WebRTC here anymore.
        // Instead, we find and send the ALIGNED frame in processMicrophoneAudio.
    }
    
    /// Process microphone audio to remove echo
    /// Returns cleaned audio samples with echo removed
    func processMicrophoneAudio(microphoneSamples: [Float]) -> [Float] {
        guard !microphoneSamples.isEmpty else { return microphoneSamples }
        guard aecBridge?.isReady == true else { return microphoneSamples }
        
        // Protocol signature matches existing protocol (no timestamps)
        // Implementation uses CACurrentMediaTime() internally for timing
        let now = CACurrentMediaTime()
        
        // Step 1: Calculate offset if not yet done
        var currentOffset: Int64 = 0
        var offsetReady = false
        
        let offsetInfo = state.withLock { state in
            // Track timing for warmup
            if state.micBufferTimes.count < SyncState.kBuffersToAverage {
                state.micBufferTimes.append(now)
            }
            
            // Calculate offset once we have enough timing data
            // Using 12 buffers (~1 second) instead of 50 buffers for faster sync.
            if !state.offsetCalculated &&
               state.systemBufferTimes.count >= SyncState.kBuffersToAverage &&
               state.micBufferTimes.count >= SyncState.kBuffersToAverage {
                
                let avgSysTime = state.systemBufferTimes.reduce(0, +) / Double(SyncState.kBuffersToAverage)
                let avgMicTime = state.micBufferTimes.reduce(0, +) / Double(SyncState.kBuffersToAverage)
                let timingOffsetSeconds = avgSysTime - avgMicTime
                let timingOffsetSamples = Int64(timingOffsetSeconds * Double(sampleRate))
                
                // CRITICAL FIX (2026-01-27): Use SAMPLE-COUNT offset, not TIMING offset!
                //
                // The timing offset measures callback DELIVERY latency (~400ms), not audio timing.
                // Both streams capture "now" audio and deliver it with their own latency.
                // Sample counts being equal confirms the audio is temporally synchronized.
                //
                // Debug evidence:
                // - Timing offset: -422ms (callback delivery latency)
                // - Sample delta: ~0 (both streams delivered same amount = synchronized)
                // - Using timing offset reads audio from 433ms ago = WRONG alignment
                // - Using sample delta keeps streams aligned = WebRTC can find echo internally
                //
                // WebRTC AEC3 can handle up to ~500ms delay internally via its adaptive filter.
                // Our job is just to keep the streams sample-count synchronized.
                let actualDelta = state.totalSystemSamples - state.totalMicSamples
                state.deliveryOffsetSamples = max(-Int64(maxBufferSamples), min(Int64(maxBufferSamples), actualDelta))
                state.offsetCalculated = true
                
                // #region agent log - H1: Log offset calculation details
                debugLog("OFFSET_CALCULATED", hypothesisId: "H1", data: [
                    "avgSysTime": String(format: "%.6f", avgSysTime),
                    "avgMicTime": String(format: "%.6f", avgMicTime),
                    "timingOffsetMs": String(format: "%.1f", timingOffsetSeconds * 1000),
                    "timingOffsetSamples": timingOffsetSamples,
                    "sampleDelta": actualDelta,
                    "usedOffset": state.deliveryOffsetSamples,
                    "totalSystemSamples": state.totalSystemSamples,
                    "totalMicSamples": state.totalMicSamples
                ])
                // #endregion
                
                // Capture values before Task to avoid capturing inout state (Swift 6)
                let logOffset = state.deliveryOffsetSamples
                let logTimingMs = String(format: "%.1f", timingOffsetSeconds * 1000)
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_OFFSET: \(logOffset) samples (timing was \(logTimingMs)ms, using sample delta)") }
            }
            
            // LESSON 7: Periodic offset validation using sample-count delta
            state.offsetValidationCount += 1
            if state.offsetCalculated && state.offsetValidationCount >= SyncState.kOffsetValidationInterval {
                state.offsetValidationCount = 0
                let actualDelta = state.totalSystemSamples - state.totalMicSamples
                let newOffset = max(-Int64(maxBufferSamples), min(Int64(maxBufferSamples), actualDelta))
                if abs(newOffset - state.deliveryOffsetSamples) > 480 {  // >10ms drift
                    let oldOffset = state.deliveryOffsetSamples
                    state.deliveryOffsetSamples = newOffset
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_OFFSET_DRIFT: \(oldOffset)→\(newOffset) samples") }
                }
            }
            
            // Return values from withLock instead of mutating captured vars (Swift 6 compliance)
            return (state.deliveryOffsetSamples, state.offsetCalculated)
        }
        currentOffset = offsetInfo.0
        offsetReady = offsetInfo.1
        
        // #region agent log (async, non-blocking) - track offset usage
        if offsetReady {
            let logOffset = currentOffset
            let logOffsetReady = offsetReady
            Task { await DiagnosticLogger.shared.log(.aec,
                "AEC_OFFSET_USED: offset=\(logOffset) samples (\(String(format: "%.1f", Double(logOffset) / 48.0))ms), ready=\(logOffsetReady)") }
        }
        // #endregion
        
        // Step 2: Process in 10ms frames with ACTUAL ALIGNMENT
        // CRITICAL FIX: Push samples to buffer FIRST, then extract and process frames.
        // If we can't extract frames (buffer underrun), we must handle the samples we just pushed.
        let (micAvailBefore, sysAvailBefore, totalMicBefore, totalSysBefore) = state.withLock { state in
            let micAvail = state.micRingBuffer.available
            let sysAvail = state.systemRingBuffer.available
            state.micRingBuffer.push(microphoneSamples)
            state.totalMicSamples += Int64(microphoneSamples.count)
            return (micAvail, sysAvail, state.totalMicSamples, state.totalSystemSamples)
        }
        
        // #region agent log (async, non-blocking)
        Task { await DiagnosticLogger.shared.log(.aec,
            "AEC_MIC_INPUT: samples=\(microphoneSamples.count), micBufBefore=\(micAvailBefore), sysBuf=\(sysAvailBefore), totalMic=\(totalMicBefore), totalSys=\(totalSysBefore)") }
        // #endregion
        
        var outputSamples: [Float] = []
        outputSamples.reserveCapacity(microphoneSamples.count)
        
        // Process frames (outside lock to avoid blocking)
        // Try to extract and process all available frames from buffer
        var framesExtracted = 0
        while true {
            // Extract mic frame (Swift 6 compliant - returns new array or nil)
            guard let micFrameData = extractMicFrame() else {
                // #region agent log (async, non-blocking)
                if framesExtracted == 0 {
                    let micAvailNow = state.withLock { $0.micRingBuffer.available }
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "AEC_MIC_UNDERRUN: pushed=\(microphoneSamples.count), available=\(micAvailNow), framesExtracted=0") }
                }
                // #endregion
                break
            }
            framesExtracted += 1
            
            // Find MATCHING system audio using offset (THIS IS THE KEY FIX)
            let renderFrameData: [Float]?
            if offsetReady {
                renderFrameData = extractRenderFrame(offset: currentOffset)
            } else {
                renderFrameData = nil
            }
            
            // LESSON 7: Bounds check fallback - pass through if no matching system audio
            guard let renderFrame = renderFrameData else {
                // No matching system audio - pass through original mic audio
                // #region agent log (async, non-blocking)
                let logOffset = currentOffset
                let logOffsetReady = offsetReady
                let logFrame = framesExtracted
                Task { await DiagnosticLogger.shared.log(.aec,
                    "AEC_NO_RENDER: offset=\(logOffset), offsetReady=\(logOffsetReady), frame=\(logFrame)") }
                // #endregion
                outputSamples.append(contentsOf: micFrameData.prefix(frameSize))
                continue
            }
            
            // Feed ALIGNED frames to WebRTC (render BEFORE capture)
            var processedFrame = outputFrame
            
            // #region agent log - H3: Calculate RMS BEFORE WebRTC processing
            let renderRMSBefore = sqrt(renderFrame.map { $0 * $0 }.reduce(0, +) / Float(renderFrame.count))
            let micRMSBefore = sqrt(micFrameData.map { $0 * $0 }.reduce(0, +) / Float(micFrameData.count))
            // #endregion
            
            // Process render (system) frame first
            let renderSuccess = renderFrame.withUnsafeBufferPointer { ptr in
                aecBridge?.processRenderFrame(ptr.baseAddress!) ?? false
            }
            
            if !renderSuccess {
                // Render processing failed - log error and pass through
                let logError = aecBridge?.lastError.rawValue ?? -1
                let logOffset = currentOffset
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_RENDER_FAILED: error=\(logError), offset=\(logOffset)") }
                outputSamples.append(contentsOf: micFrameData.prefix(frameSize))
                continue
            }
            
            // #region agent log (async, non-blocking) - track successful frame pairs with RMS levels
            if framesExtracted % 100 == 1 {  // Log first frame of every 100 (every ~1 second)
                let logFrame = framesExtracted
                let logOffset = currentOffset
                let acousticDelayMs = acousticEchoDelayMs
                let renderRMS = sqrt(renderFrame.map { $0 * $0 }.reduce(0, +) / Float(renderFrame.count))
                let micRMS = sqrt(micFrameData.map { $0 * $0 }.reduce(0, +) / Float(micFrameData.count))
                // Convert to dB for easier interpretation (0 dB = full scale, -60 dB = very quiet)
                let renderDB = renderRMS > 0 ? 20 * log10(renderRMS) : -100
                let micDB = micRMS > 0 ? 20 * log10(micRMS) : -100
                Task { await DiagnosticLogger.shared.log(.aec,
                    "AEC_FRAME_RMS: renderRMS=\(String(format: "%.4f", renderRMS)) (\(String(format: "%.1f", renderDB))dB), micRMS=\(String(format: "%.4f", micRMS)) (\(String(format: "%.1f", micDB))dB), offset=\(logOffset), acousticDelay=\(acousticDelayMs)ms") }
            }
            // #endregion
            
            // Then process capture (mic) frame
            let captureSuccess = micFrameData.withUnsafeBufferPointer { inputPtr in
                processedFrame.withUnsafeMutableBufferPointer { outputPtr in
                    aecBridge?.processCaptureFrame(inputPtr.baseAddress!, outputSamples: outputPtr.baseAddress!) ?? false
                }
            }
            
            if captureSuccess {
                // #region agent log - Log AEC effect (input vs output RMS)
                let outputRMS = sqrt(processedFrame.prefix(frameSize).map { $0 * $0 }.reduce(0, +) / Float(frameSize))
                if framesExtracted % 100 == 1 {  // Log every ~1 second
                    let inputDB = micRMSBefore > 0 ? 20 * log10(micRMSBefore) : -100
                    let outputDB = outputRMS > 0 ? 20 * log10(outputRMS) : -100
                    let reductionDB = inputDB - outputDB  // Positive = AEC reduced the signal
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "AEC_OUTPUT: inputRMS=\(String(format: "%.4f", micRMSBefore)) (\(String(format: "%.1f", inputDB))dB) → outputRMS=\(String(format: "%.4f", outputRMS)) (\(String(format: "%.1f", outputDB))dB), reduction=\(String(format: "%.1f", reductionDB))dB") }
                }
                // #endregion
                outputSamples.append(contentsOf: processedFrame.prefix(frameSize))
            } else {
                // Processing failed - log specific error and pass through original
                let errorCode = aecBridge?.lastError.rawValue ?? -1
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_CAPTURE_FAILED: error=\(errorCode)") }
                outputSamples.append(contentsOf: micFrameData.prefix(frameSize))
            }
            
            // DON'T consume system audio here! (Consensus from v5 reviewers)
            // The ring buffer's overflow behavior (overwrite oldest when full) naturally
            // evicts old samples. We always read at a fixed offset from the head, and
            // the buffer maintains itself as a sliding window.
        }
        
        // CRITICAL FIX: Always return processed samples from buffer.
        // If outputSamples is empty, it means extractMicFrame returned nil immediately,
        // which shouldn't happen if we just pushed samples (unless microphoneSamples.count < frameSize).
        // In that case, return the original samples - they're in the buffer and will be
        // processed when combined with samples from the next callback.
        // NOTE: This could cause slight timing issues but ensures no samples are lost.
        let result = outputSamples.isEmpty ? microphoneSamples : outputSamples
        
        // #region agent log (async, non-blocking)
        let logInputCount = microphoneSamples.count
        let logOutputCount = result.count
        let logFramesExtracted = framesExtracted
        if outputSamples.isEmpty {
            Task { await DiagnosticLogger.shared.log(.aec,
                "AEC_MIC_PASSTHROUGH: input=\(logInputCount), output=\(logOutputCount), framesExtracted=\(logFramesExtracted)") }
        } else {
            Task { await DiagnosticLogger.shared.log(.aec,
                "AEC_MIC_PROCESSED: input=\(logInputCount), output=\(logOutputCount), framesExtracted=\(logFramesExtracted)") }
        }
        // #endregion
        
        return result
    }
    
    /// Reset the AEC state (call when starting new recording)
    func reset() {
        // Log stats before reset
        let (gapSamples, erle, delayMs, totalSys, totalMic, offset) = state.withLock { state in
            (state.totalGapSamples, aecBridge?.getERLE() ?? 0, aecBridge?.getDelayMs() ?? -1,
             state.totalSystemSamples, state.totalMicSamples, state.deliveryOffsetSamples)
        }
        
        // #region agent log - Final stats at reset
        debugLog("AEC_RESET_STATS", hypothesisId: "ALL", data: [
            "gapSamples": gapSamples,
            "ERLE_dB": String(format: "%.1f", erle),
            "delayMs": delayMs,
            "totalSystemSamples": totalSys,
            "totalMicSamples": totalMic,
            "finalOffset": offset,
            "sampleDiff": totalSys - totalMic
        ])
        // #endregion
        
        Task { await DiagnosticLogger.shared.log(.aec,
            "WEBRTC_RESET: gaps=\(gapSamples), ERLE=\(String(format: "%.1f", erle))dB, delay=\(delayMs)ms") }
        
        // Reset state
        state.withLock { state in
            state.systemRingBuffer.clear()
            state.micRingBuffer.clear()
            state.totalSystemSamples = 0
            state.totalMicSamples = 0
            state.deliveryOffsetSamples = 0
            state.offsetCalculated = false
            state.systemBufferTimes.removeAll()
            state.micBufferTimes.removeAll()
            state.lastSystemBufferTime = 0
            state.systemBufferCount = 0
            state.totalGapSamples = 0
            state.offsetValidationCount = 0
        }
        
        aecBridge?.reset()
    }
    
    /// Start drift monitoring - no-op for WebRTC (we do periodic offset validation in processMicrophoneAudio)
    func startDriftMonitoring() {
        // No-op - offset validation is built into the processing loop
    }
    
    // MARK: - Private Helpers
    
    /// Extract mic frame (returns nil if not enough data)
    private func extractMicFrame() -> [Float]? {
        return state.withLock { state in
            guard state.micRingBuffer.available >= frameSize else { return nil }
            var buffer = [Float](repeating: 0, count: frameSize)
            let success = buffer.withUnsafeMutableBufferPointer { ptr in
                state.micRingBuffer.popInto(ptr, count: frameSize)
            }
            return success ? buffer : nil
        }
    }
    
    /// Extract render frame from system buffer at given offset (returns nil if not enough data)
    ///
    /// CRITICAL FIX (2026-01-27): We need to account for TWO different delays:
    /// 1. Sample-count offset: synchronization between streams (typically ~0)
    /// 2. Acoustic echo delay: time for sound to travel speaker → room → mic (~30-100ms)
    ///
    /// When processing mic audio, we need render audio from EARLIER in time:
    /// - Mic captures echo at time T
    /// - That echo came from audio played at time T - acousticEchoDelay
    /// - We need to read render samples from that earlier time
    ///
    /// Formula: targetOffset = available - sampleCountOffset - acousticEchoDelay - frameSize
    private func extractRenderFrame(offset: Int64) -> [Float]? {
        return state.withLock { state in
            let available = state.systemRingBuffer.available
            
            // Total offset = sample-count offset + acoustic echo delay
            // Both push us toward reading OLDER samples
            let totalOffset = Int(offset) + acousticEchoDelaySamples
            
            // Calculate position to read from (older samples = smaller targetOffset)
            let targetOffset: Int
            if totalOffset >= 0 {
                // Normal case: read from position that accounts for both offsets
                targetOffset = max(0, available - totalOffset - frameSize)
            } else {
                // Unusual case: mic significantly ahead of system (shouldn't happen normally)
                targetOffset = max(0, available - frameSize)
            }
            
            let requiredSamples = targetOffset + frameSize
            
            guard available >= requiredSamples else {
                // #region agent log - Log buffer underrun
                debugLog("extractRenderFrame_UNDERRUN", hypothesisId: "H4", data: [
                    "sampleOffset": offset,
                    "acousticDelay": acousticEchoDelaySamples,
                    "totalOffset": totalOffset,
                    "targetOffset": targetOffset,
                    "available": available,
                    "requiredSamples": requiredSamples
                ])
                // #endregion
                return nil
            }
            
            var buffer = [Float](repeating: 0, count: frameSize)
            let success = buffer.withUnsafeMutableBufferPointer { ptr in
                state.systemRingBuffer.read(at: targetOffset, count: frameSize, into: ptr)
            }
            return success ? buffer : nil
        }
    }
    
    // MARK: - Diagnostics
    
    /// Current ERLE (Echo Return Loss Enhancement) in dB
    var currentERLE: Float { aecBridge?.getERLE() ?? 0 }
    
    /// Current delay estimate in milliseconds
    var currentDelayMs: Int { Int(aecBridge?.getDelayMs() ?? -1) }
    
    /// Whether the AEC bridge is initialized and ready
    var isReady: Bool { aecBridge?.isReady ?? false }
}
