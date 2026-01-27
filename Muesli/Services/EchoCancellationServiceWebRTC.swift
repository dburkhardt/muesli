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
    
    // NOTE: Acoustic echo delay is now handled internally by WebRTC AEC3.
    // WebRTC uses frame arrival timing (from separate processRenderFrame/processCaptureFrame calls)
    // to estimate the acoustic delay automatically. No manual configuration needed.
    
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
    
    // Frame accumulation buffer for system audio (thread-safe via lock)
    // ScreenCaptureKit delivers variable-sized buffers; we accumulate until 480 samples (10ms)
    // Protected by its own lock since storeSystemAudio() runs on SCK's thread
    private let renderAccumulatorLock = OSAllocatedUnfairLock(initialState: [Float]())
    
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
        
        // TIMING FIX (2026-01-27): Send render frames to WebRTC IMMEDIATELY when system audio arrives.
        // This gives WebRTC the natural frame arrival timing it needs for delay estimation.
        // Previously we batched render+capture calls together in processMicrophoneAudio(), which
        // made WebRTC see delay ≈ 0ms (defeating its internal delay estimator).
        accumulateAndProcessRender(monoSamples)
    }
    
    /// Accumulate system audio samples and process complete 10ms frames through WebRTC
    /// This is called from storeSystemAudio() on the ScreenCaptureKit callback thread
    private func accumulateAndProcessRender(_ samples: [Float]) {
        guard aecBridge?.isReady == true else { return }
        
        // Accumulate samples until we have a full 10ms frame (480 samples)
        renderAccumulatorLock.withLock { accumulator in
            accumulator.append(contentsOf: samples)
            
            // Process all complete frames
            var framesProcessed = 0
            while accumulator.count >= frameSize {
                // Extract frame
                let frame = Array(accumulator.prefix(frameSize))
                accumulator.removeFirst(frameSize)
                
                // Send to WebRTC (outside of lock would be better but we need accumulator access)
                let success = frame.withUnsafeBufferPointer { ptr in
                    aecBridge?.processRenderFrame(ptr.baseAddress!) ?? false
                }
                
                if success {
                    framesProcessed += 1
                } else {
                    // Log error but continue - don't block audio callback
                    let errorCode = aecBridge?.lastError.rawValue ?? -1
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_RENDER_FAILED: error=\(errorCode)") }
                }
            }
            
            // Log timing for verification (every 100 frames ≈ 1 second)
            if framesProcessed > 0 {
                let timestamp = CACurrentMediaTime()
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_RENDER_SENT: frames=\(framesProcessed), time=\(String(format: "%.3f", timestamp))") }
            }
        }
    }
    
    /// Process microphone audio to remove echo
    /// Returns cleaned audio samples with echo removed
    func processMicrophoneAudio(microphoneSamples: [Float]) -> [Float] {
        guard !microphoneSamples.isEmpty else { return microphoneSamples }
        guard aecBridge?.isReady == true else { return microphoneSamples }
        
        // Protocol signature matches existing protocol (no timestamps)
        // Implementation uses CACurrentMediaTime() internally for timing
        let now = CACurrentMediaTime()
        
        // Step 1: Update stream timing statistics (for diagnostic logging and drift detection)
        // NOTE: Offset calculation is kept for drift monitoring, but no longer used for
        // render frame extraction. WebRTC handles delay estimation internally using
        // frame arrival timing from separate processRenderFrame/processCaptureFrame calls.
        state.withLock { state in
            // Track timing for warmup
            if state.micBufferTimes.count < SyncState.kBuffersToAverage {
                state.micBufferTimes.append(now)
            }
            
            // Calculate offset once we have enough timing data (for diagnostic logging)
            if !state.offsetCalculated &&
               state.systemBufferTimes.count >= SyncState.kBuffersToAverage &&
               state.micBufferTimes.count >= SyncState.kBuffersToAverage {
                
                let avgSysTime = state.systemBufferTimes.reduce(0, +) / Double(SyncState.kBuffersToAverage)
                let avgMicTime = state.micBufferTimes.reduce(0, +) / Double(SyncState.kBuffersToAverage)
                let timingOffsetSeconds = avgSysTime - avgMicTime
                let actualDelta = state.totalSystemSamples - state.totalMicSamples
                state.deliveryOffsetSamples = actualDelta
                state.offsetCalculated = true
                
                // Log offset for diagnostics (WebRTC handles this internally now)
                let logOffset = state.deliveryOffsetSamples
                let logTimingMs = String(format: "%.1f", timingOffsetSeconds * 1000)
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_STREAM_SYNC: sampleDelta=\(logOffset), callbackOffset=\(logTimingMs)ms (WebRTC handles delay internally)") }
            }
            
            // Periodic drift monitoring (for diagnostics)
            state.offsetValidationCount += 1
            if state.offsetCalculated && state.offsetValidationCount >= SyncState.kOffsetValidationInterval {
                state.offsetValidationCount = 0
                let actualDelta = state.totalSystemSamples - state.totalMicSamples
                if abs(actualDelta - state.deliveryOffsetSamples) > 480 {  // >10ms drift
                    let oldOffset = state.deliveryOffsetSamples
                    state.deliveryOffsetSamples = actualDelta
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_STREAM_DRIFT: \(oldOffset)→\(actualDelta) samples") }
                }
            }
        }
        
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
        // TIMING FIX (2026-01-27): Only call processCaptureFrame() here.
        // processRenderFrame() is now called in storeSystemAudio() when system audio arrives,
        // giving WebRTC the natural frame arrival timing it needs for delay estimation.
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
            
            // Pre-allocate output buffer
            var processedFrame = outputFrame
            
            // Calculate RMS for diagnostic logging
            let micRMSBefore = sqrt(micFrameData.map { $0 * $0 }.reduce(0, +) / Float(micFrameData.count))
            
            // Process capture (mic) frame through WebRTC AEC
            // NOTE: Render frames were already sent to WebRTC in storeSystemAudio()
            // with their natural arrival timing. WebRTC's internal delay estimator
            // uses the timing difference to find the echo.
            let captureSuccess = micFrameData.withUnsafeBufferPointer { inputPtr in
                processedFrame.withUnsafeMutableBufferPointer { outputPtr in
                    aecBridge?.processCaptureFrame(inputPtr.baseAddress!, outputSamples: outputPtr.baseAddress!) ?? false
                }
            }
            
            if captureSuccess {
                // Log AEC effect periodically (every ~1 second)
                if framesExtracted % 100 == 1 {
                    let outputRMS = sqrt(processedFrame.prefix(frameSize).map { $0 * $0 }.reduce(0, +) / Float(frameSize))
                    let inputDB = micRMSBefore > 0 ? 20 * log10(micRMSBefore) : -100
                    let outputDB = outputRMS > 0 ? 20 * log10(outputRMS) : -100
                    let reductionDB = inputDB - outputDB  // Positive = AEC reduced the signal
                    let erle = aecBridge?.getERLE() ?? 0
                    let delayMs = aecBridge?.getDelayMs() ?? -1
                    let timestamp = CACurrentMediaTime()
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_CAPTURE_SENT: time=\(String(format: "%.3f", timestamp)), ERLE=\(String(format: "%.1f", erle))dB, delay=\(delayMs)ms, reduction=\(String(format: "%.1f", reductionDB))dB") }
                }
                outputSamples.append(contentsOf: processedFrame.prefix(frameSize))
            } else {
                // Processing failed - log specific error and pass through original
                let errorCode = aecBridge?.lastError.rawValue ?? -1
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_CAPTURE_FAILED: error=\(errorCode)") }
                outputSamples.append(contentsOf: micFrameData.prefix(frameSize))
            }
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
        
        // Clear render accumulator
        renderAccumulatorLock.withLock { $0.removeAll() }
        
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
    
    // NOTE: extractRenderFrame() was removed in the timing fix (2026-01-27).
    // Render frames are now sent directly to WebRTC in storeSystemAudio() via
    // accumulateAndProcessRender(), giving WebRTC natural frame arrival timing
    // for its internal delay estimation.
    
    // MARK: - Diagnostics
    
    /// Current ERLE (Echo Return Loss Enhancement) in dB
    var currentERLE: Float { aecBridge?.getERLE() ?? 0 }
    
    /// Current delay estimate in milliseconds
    var currentDelayMs: Int { Int(aecBridge?.getDelayMs() ?? -1) }
    
    /// Whether the AEC bridge is initialized and ready
    var isReady: Bool { aecBridge?.isReady ?? false }
}
