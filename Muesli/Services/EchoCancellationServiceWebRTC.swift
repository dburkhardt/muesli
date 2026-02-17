import Foundation
import os.lock
import QuartzCore

/// WebRTC AEC3 implementation for acoustic echo cancellation.
///
/// Architecture (after startup order fix 2026-01-27):
/// ```
/// System Audio (SCK):     ┃━━━━━━━━━━━━━━━━━━━━━━━━━━━┃
///                         ↑ Starts FIRST (AudioCaptureService ensures this)
///
/// Mic (AVAudioEngine):        ┃━━━━━━━━━━━━━━━━━━━━━━━━┃
///                             ↑ Starts ~50ms later
/// ```
///
/// WebRTC AEC3 expects render (system) before capture (mic), which is now guaranteed
/// by starting ScreenCaptureKit before AVAudioEngine in AudioCaptureService.
/// This allows WebRTC's internal delay estimation to work correctly.
final class EchoCancellationServiceWebRTC: @unchecked Sendable, EchoCancellationServiceProtocol {
    
    // MARK: - Configuration
    
    private let sampleRate: Int = 48000
    private let frameSize: Int = 480  // 10ms at 48kHz (WebRTC requirement)
    private let maxBufferMs: Int = 1500  // 1500ms = 72000 samples (increased for SCK latency)
    private let maxBufferSamples: Int = 72000
    
    // NOTE: Acoustic echo delay is now handled internally by WebRTC AEC3.
    // WebRTC uses frame arrival timing (from separate processRenderFrame/processCaptureFrame calls)
    // to estimate the acoustic delay automatically. No manual configuration needed.
    
    // MARK: - State (Thread-Safe)
    
    private struct SyncState {
        // Ring buffers for coarse alignment (pre-allocated, no runtime allocations)
        var systemRingBuffer: AudioRingBuffer
        var micRingBuffer: AudioRingBuffer
        var processedMicRingBuffer: AudioRingBuffer
        
        // Sample counters for alignment
        var totalSystemSamples: Int64 = 0
        var totalMicSamples: Int64 = 0
        var deliveryOffsetSamples: Int64 = 0
        var offsetCalculated: Bool = false

        // Frame counters for diagnostics
        var totalRenderFrames: Int64 = 0
        var totalCaptureFrames: Int64 = 0
        
        // Warmup tracking
        var systemBufferTimes: [Double] = []
        var micBufferTimes: [Double] = []
        static let kBuffersToAverage = 12
        
        // Gap detection
        var lastSystemBufferTime: Double = 0
        var systemBufferCount: Int = 0
        var totalGapSamples: Int64 = 0
        var silenceScratch: [Float] = []
        var sweepScratch: [Float] = []
        
        // Offset validation (Lesson 7)
        var offsetValidationCount: Int = 0
        static let kOffsetValidationInterval = 100  // Every 100 frames (~1 second)
        
        init(bufferCapacity: Int, frameSize: Int) {
            systemRingBuffer = AudioRingBuffer(capacity: bufferCapacity)
            micRingBuffer = AudioRingBuffer(capacity: bufferCapacity)
            processedMicRingBuffer = AudioRingBuffer(capacity: bufferCapacity)
            silenceScratch = [Float](repeating: 0, count: bufferCapacity / 4)
            lastRenderFrame = [Float](repeating: 0, count: frameSize)
            sweepScratch = [Float](repeating: 0, count: frameSize)
        }

        // Last processed render frame for correlation diagnostics
        var lastRenderFrame: [Float]
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
    
    // Flag to track whether system audio has started (for diagnostic logging)
    // With the AudioCaptureService startup order fix, system audio should arrive first now.
    private let systemHasStartedLock = OSAllocatedUnfairLock(initialState: false)

    private struct CadenceState {
        var lastTime: Double?
        var logCount: Int = 0
    }
    private let renderCadenceState = OSAllocatedUnfairLock(initialState: CadenceState())
    private let captureCadenceState = OSAllocatedUnfairLock(initialState: CadenceState())

    // MARK: - Initialization
    
    init() {
        self.state = OSAllocatedUnfairLock(initialState: SyncState(bufferCapacity: maxBufferSamples, frameSize: frameSize))
        
        // Initialize WebRTC bridge
        // In Swift, ObjC methods with NSError** are translated to throwing initializers
        do {
            self.aecBridge = try WebRTCAECBridge(sampleRate: Int32(sampleRate), channels: 1)
            Task { await DiagnosticLogger.shared.log(.aec,
                "WEBRTC_INIT_SUCCESS: AEC3 ready, frameSize=480") }
            let externalDelayEnabled = aecBridge?.externalDelayEstimatorEnabled ?? false
            Task { await DiagnosticLogger.shared.log(.aec,
                "WEBRTC_AEC3_CONFIG: externalDelayEstimator=\(externalDelayEnabled)") }
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
        }
        
        // Send render frames to WebRTC as they arrive.
        // With the AudioCaptureService startup order fix (2026-01-27), system audio
        // now starts BEFORE mic audio, giving WebRTC the correct frame ordering.
        
        // Track when system audio starts (for diagnostic logging)
        let wasStarted = systemHasStartedLock.withLock { started -> Bool in
            let was = started
            if !started {
                started = true
            }
            return was
        }
        if !wasStarted {
            Task { await DiagnosticLogger.shared.log(.aec,
                "WEBRTC_SYSTEM_STARTED: Mic processing will now begin") }
        }
        
        // Send render frames to WebRTC
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
            var lastRenderRms: Float?
            var batchFrames = 0
            var firstDeltaMs: Double?
            var minInterFrameMs: Double?
            var maxInterFrameMs: Double?
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
                    batchFrames += 1
                    state.withLock { state in
                        state.lastRenderFrame = frame
                    }
                    // Track RMS for diagnostics (last processed frame)
                    let rms = sqrt(frame.map { $0 * $0 }.reduce(0, +) / Float(frame.count))
                    lastRenderRms = rms

                    let now = CACurrentMediaTime()
                    let deltaMs = renderCadenceState.withLock { cadence -> Double? in
                        let delta = cadence.lastTime.map { (now - $0) * 1000 }
                        cadence.lastTime = now
                        return delta
                    }
                    if let deltaMs {
                        if batchFrames == 1 {
                            firstDeltaMs = deltaMs
                        } else {
                            minInterFrameMs = minInterFrameMs.map { min($0, deltaMs) } ?? deltaMs
                            maxInterFrameMs = maxInterFrameMs.map { max($0, deltaMs) } ?? deltaMs
                        }
                    }
                } else {
                    // Log error but continue - don't block audio callback
                    let errorCode = aecBridge?.lastError.rawValue ?? -1
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_RENDER_FAILED: error=\(errorCode)") }
                }
            }
            
            // Update render frame count for diagnostics
            if framesProcessed > 0 {
                let framesProcessedCount = framesProcessed
                let renderStats = state.withLock { state -> (shouldLog: Bool, totalRenderFrames: Int64) in
                    state.totalRenderFrames += Int64(framesProcessedCount)
                    let shouldLog = state.totalRenderFrames % 100 == 0
                    return (shouldLog, state.totalRenderFrames)
                }
                if renderStats.shouldLog, let rms = lastRenderRms {
                    let inputDb = rms > 0 ? 20 * log10(rms) : -100
                    let inputDbLog = inputDb
                    let totalRenderFramesLog = renderStats.totalRenderFrames
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_RENDER_RMS: frames=\(totalRenderFramesLog), inputDb=\(String(format: "%.1f", inputDbLog))") }
                }
            }

            // Log if render backlog grows unusually large
            if accumulator.count >= frameSize * 5 {
                let backlog = accumulator.count
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_RENDER_BACKLOG: samples=\(backlog)") }
            }

            // Log timing for verification (every 100 frames ≈ 1 second)
            if framesProcessed > 0 {
                let framesProcessedLog = framesProcessed
                let timestamp = CACurrentMediaTime()
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_RENDER_SENT: frames=\(framesProcessedLog), time=\(String(format: "%.3f", timestamp))") }
            }

            if batchFrames > 1 {
                let shouldLog = renderCadenceState.withLock { cadence -> Bool in
                    cadence.logCount += 1
                    return cadence.logCount % 10 == 0
                }
                if shouldLog {
                    let firstDelta = firstDeltaMs ?? -1
                    let minInter = minInterFrameMs ?? -1
                    let maxInter = maxInterFrameMs ?? -1
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_RENDER_CADENCE: batchFrames=\(batchFrames), firstDeltaMs=\(String(format: "%.2f", firstDelta)), minInterMs=\(String(format: "%.2f", minInter)), maxInterMs=\(String(format: "%.2f", maxInter))") }
                }
            }
        }
    }

    /// Process microphone audio to remove echo
    /// Returns cleaned audio samples with echo removed
    func processMicrophoneAudio(microphoneSamples: [Float]) -> [Float] {
        guard !microphoneSamples.isEmpty else { return microphoneSamples }
        guard aecBridge?.isReady == true else { return microphoneSamples }
        
        // With the AudioCaptureService startup order fix (2026-01-27), system audio
        // now starts BEFORE mic audio, so render frames should already be arriving.
        // Just process capture frames as they come - WebRTC handles the timing.
        
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
                let logDeltaMs = Double(logOffset) / Double(sampleRate) * 1000
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_STREAM_SYNC: sampleDelta=\(logOffset) (\(String(format: "%.1f", logDeltaMs))ms), callbackOffset=\(logTimingMs)ms (WebRTC handles delay internally)") }
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
        state.withLock { state in
            state.micRingBuffer.push(microphoneSamples)
            state.totalMicSamples += Int64(microphoneSamples.count)
        }

        var outputSamples: [Float] = []
        outputSamples.reserveCapacity(microphoneSamples.count)
// Process frames (outside lock to avoid blocking)
        // TIMING FIX (2026-01-27): Only call processCaptureFrame() here.
        // processRenderFrame() is now called in storeSystemAudio() when system audio arrives,
        // giving WebRTC the natural frame arrival timing it needs for delay estimation.
        var framesExtracted = 0
        var batchFrames = 0
        var firstDeltaMs: Double?
        var minInterFrameMs: Double?
        var maxInterFrameMs: Double?
        while true {
            // Extract mic frame with absolute start index (Swift 6 compliant - returns new array or nil)
            guard let (micFrameData, micFrameStartIndex) = extractMicFrameWithIndex() else {
                break
            }
            framesExtracted += 1
            batchFrames += 1

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

            let now = CACurrentMediaTime()
            let deltaMs = captureCadenceState.withLock { cadence -> Double? in
                let delta = cadence.lastTime.map { (now - $0) * 1000 }
                cadence.lastTime = now
                return delta
            }
            if let deltaMs {
                if batchFrames == 1 {
                    firstDeltaMs = deltaMs
                } else {
                    minInterFrameMs = minInterFrameMs.map { min($0, deltaMs) } ?? deltaMs
                    maxInterFrameMs = maxInterFrameMs.map { max($0, deltaMs) } ?? deltaMs
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
                    let inputDbLog = inputDB
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_CAPTURE_SENT: time=\(String(format: "%.3f", timestamp)), ERLE=\(String(format: "%.1f", erle))dB, delay=\(delayMs)ms, inputDb=\(String(format: "%.1f", inputDbLog))dB, reduction=\(String(format: "%.1f", reductionDB))dB") }

                    // Correlation diagnostic (render vs capture frame)
                    let (renderFrame, sampleDelta, systemStartIndex, systemAvailable) = state.withLock { state in
                        let available = state.systemRingBuffer.available
                        let startIndex = state.totalSystemSamples - Int64(available)
                        return (state.lastRenderFrame, state.totalSystemSamples - state.totalMicSamples, startIndex, available)
                    }
                    let renderRms = sqrt(renderFrame.map { $0 * $0 }.reduce(0, +) / Float(renderFrame.count))
                    let renderDb = renderRms > 0 ? 20 * log10(renderRms) : -100
                    let micDb = inputDB
                    let denom = renderRms * micRMSBefore
                    let corr: Double
                    if denom > 0 {
                        var dot: Double = 0
                        for idx in 0..<frameSize {
                            dot += Double(renderFrame[idx] * micFrameData[idx])
                        }
                        corr = dot / Double(renderRms * micRMSBefore * Float(frameSize))
                    } else {
                        corr = 0
                    }
                    let leadMs = Double(sampleDelta) / Double(sampleRate) * 1000
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "AEC_CORR: corr=\(String(format: "%.3f", corr)), renderDb=\(String(format: "%.1f", renderDb))dB, micDb=\(String(format: "%.1f", micDb))dB, leadMs=\(String(format: "%.1f", leadMs))") }

                    // Lag sweep correlation diagnostic (±200ms in 10ms steps)
                    var bestCorr: Double = 0
                    var bestLagMs: Double = 0
                    var bestRenderDb: Double = -100
                    var validCount = 0
                    var expectedCorr: Double = 0
                    var expectedRenderDb: Double = -100
                    var expectedValid = false
                    let micRms = Double(micRMSBefore)
                    if micRms > 0 {
                        // Correlation at expected lag (current lead)
                        let expectedLagMs = leadMs
                        let expectedLagSamples = Int(round(expectedLagMs / 1000.0 * Double(sampleRate)))
                        let expectedTargetIndex = micFrameStartIndex + Int64(expectedLagSamples)
                        let expectedOffset = Int(expectedTargetIndex - systemStartIndex)
                        if expectedOffset >= 0, expectedOffset + frameSize <= systemAvailable {
                            let expectedResult = state.withLock { state -> (Bool, Double, Double) in
                                let readSuccess = state.sweepScratch.withUnsafeMutableBufferPointer { ptr in
                                    state.systemRingBuffer.read(at: expectedOffset, count: frameSize, into: ptr)
                                }
                                guard readSuccess else { return (false, 0, 0) }
                                var dot: Double = 0
                                var renderPower: Double = 0
                                for idx in 0..<frameSize {
                                    let r = Double(state.sweepScratch[idx])
                                    dot += r * Double(micFrameData[idx])
                                    renderPower += r * r
                                }
                                return (true, dot, renderPower)
                            }
                            if expectedResult.0, expectedResult.2 > 0 {
                                let renderRmsExpected = sqrt(expectedResult.2 / Double(frameSize))
                                expectedCorr = expectedResult.1 / (micRms * renderRmsExpected * Double(frameSize))
                                expectedRenderDb = renderRmsExpected > 0 ? 20 * log10(renderRmsExpected) : -100
                                expectedValid = true
                            }
                        }

                        for step in -20...20 {
                            let lagSamples = step * frameSize
                            let targetIndex = micFrameStartIndex + Int64(lagSamples)
                            let offset = Int(targetIndex - systemStartIndex)
                            if offset < 0 || offset + frameSize > systemAvailable {
                                continue
                            }
                            let (readSuccess, dot, renderPower) = state.withLock { state -> (Bool, Double, Double) in
                                let readSuccess = state.sweepScratch.withUnsafeMutableBufferPointer { ptr in
                                    state.systemRingBuffer.read(at: offset, count: frameSize, into: ptr)
                                }
                                guard readSuccess else { return (false, 0, 0) }
                                var dot: Double = 0
                                var renderPower: Double = 0
                                for idx in 0..<frameSize {
                                    let r = Double(state.sweepScratch[idx])
                                    dot += r * Double(micFrameData[idx])
                                    renderPower += r * r
                                }
                                return (true, dot, renderPower)
                            }
                            guard readSuccess, renderPower > 0 else { continue }
                            let renderRmsSweep = sqrt(renderPower / Double(frameSize))
                            let corrSweep = dot / (micRms * renderRmsSweep * Double(frameSize))
                            if abs(corrSweep) > abs(bestCorr) {
                                bestCorr = corrSweep
                                bestLagMs = Double(lagSamples) / Double(sampleRate) * 1000
                                bestRenderDb = renderRmsSweep > 0 ? 20 * log10(renderRmsSweep) : -100
                            }
                            validCount += 1
                        }
                    }
                    let bestCorrLog = bestCorr
                    let bestLagLog = bestLagMs
                    let bestRenderDbLog = bestRenderDb
                    let validCountLog = validCount
                    let expectedCorrLog = expectedCorr
                    let expectedRenderDbLog = expectedRenderDb
                    let expectedValidLog = expectedValid
                    let expectedLagLog = leadMs
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "AEC_CORR_SWEEP: peakCorr=\(String(format: "%.3f", bestCorrLog)), peakLagMs=\(String(format: "%.1f", bestLagLog)), renderDb=\(String(format: "%.1f", bestRenderDbLog))dB, micDb=\(String(format: "%.1f", micDb))dB, leadMs=\(String(format: "%.1f", leadMs)), valid=\(validCountLog)") }
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "AEC_CORR_EXPECTED: corr=\(String(format: "%.3f", expectedCorrLog)), renderDb=\(String(format: "%.1f", expectedRenderDbLog))dB, expectedLagMs=\(String(format: "%.1f", expectedLagLog)), valid=\(expectedValidLog)") }
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "AEC_CORR_ENERGY: renderDbExpected=\(String(format: "%.1f", expectedRenderDbLog))dB, renderDbPeak=\(String(format: "%.1f", bestRenderDbLog))dB, expectedLagMs=\(String(format: "%.1f", expectedLagLog)), peakLagMs=\(String(format: "%.1f", bestLagLog)), expectedValid=\(expectedValidLog)") }
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
        
        if batchFrames > 1 {
            let shouldLog = captureCadenceState.withLock { cadence -> Bool in
                cadence.logCount += 1
                return cadence.logCount % 10 == 0
            }
            if shouldLog {
                let firstDelta = firstDeltaMs ?? -1
                let minInter = minInterFrameMs ?? -1
                let maxInter = maxInterFrameMs ?? -1
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_CAPTURE_CADENCE: batchFrames=\(batchFrames), firstDeltaMs=\(String(format: "%.2f", firstDelta)), minInterMs=\(String(format: "%.2f", minInter)), maxInterMs=\(String(format: "%.2f", maxInter))") }
            }
        }

        // Update capture frame count and log sync state periodically
        if framesExtracted > 0 {
            let framesExtractedCount = framesExtracted
            let stats = state.withLock { state -> (shouldLog: Bool, captureFrames: Int64, renderFrames: Int64, sampleDelta: Int64, sysAvail: Int, micAvail: Int) in
                state.totalCaptureFrames += Int64(framesExtractedCount)
                let shouldLog = state.totalCaptureFrames % 100 == 0
                let sampleDelta = state.totalSystemSamples - state.totalMicSamples
                return (shouldLog, state.totalCaptureFrames, state.totalRenderFrames, sampleDelta, state.systemRingBuffer.available, state.micRingBuffer.available)
            }
            if stats.shouldLog {
                let leadMs = Double(stats.sampleDelta) / Double(sampleRate) * 1000
                let sysAvailMs = Double(stats.sysAvail) / Double(sampleRate) * 1000
                let micAvailMs = Double(stats.micAvail) / Double(sampleRate) * 1000
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_SYNC_STATUS: renderFrames=\(stats.renderFrames), captureFrames=\(stats.captureFrames), sampleDelta=\(stats.sampleDelta) (\(String(format: "%.1f", leadMs))ms), sysAvail=\(stats.sysAvail) (\(String(format: "%.1f", sysAvailMs))ms), micAvail=\(stats.micAvail) (\(String(format: "%.1f", micAvailMs))ms)") }
            }
        }

        // CRITICAL FIX: Always return processed samples from buffer.
        // If outputSamples is empty, it means extractMicFrame returned nil immediately,
        // which shouldn't happen if we just pushed samples (unless microphoneSamples.count < frameSize).
        // In that case, return the original samples - they're in the buffer and will be
        // processed when combined with samples from the next callback.
        // NOTE: This could cause slight timing issues but ensures no samples are lost.
        let result = outputSamples.isEmpty ? microphoneSamples : outputSamples

        return result
    }
    
    /// Reset the AEC state (call when starting new recording)
    func reset() {
        // Log stats before reset
        let (gapSamples, erle, delayMs) = state.withLock { state in
            (state.totalGapSamples, aecBridge?.getERLE() ?? 0, aecBridge?.getDelayMs() ?? -1)
        }

        Task { await DiagnosticLogger.shared.log(.aec,
            "WEBRTC_RESET: gaps=\(gapSamples), ERLE=\(String(format: "%.1f", erle))dB, delay=\(delayMs)ms") }
        
        // Reset state
        state.withLock { state in
            state.systemRingBuffer.clear()
            state.micRingBuffer.clear()
            state.processedMicRingBuffer.clear()
            state.totalSystemSamples = 0
            state.totalMicSamples = 0
            state.deliveryOffsetSamples = 0
            state.offsetCalculated = false
            state.totalRenderFrames = 0
            state.totalCaptureFrames = 0
            state.systemBufferTimes.removeAll()
            state.micBufferTimes.removeAll()
            state.lastSystemBufferTime = 0
            state.systemBufferCount = 0
            state.totalGapSamples = 0
            state.offsetValidationCount = 0
        }
        
        // Clear render accumulator and reset system started flag
        renderAccumulatorLock.withLock { $0.removeAll() }
        systemHasStartedLock.withLock { $0 = false }
        renderCadenceState.withLock { cadence in
            cadence.lastTime = nil
            cadence.logCount = 0
        }
        captureCadenceState.withLock { cadence in
            cadence.lastTime = nil
            cadence.logCount = 0
        }

        aecBridge?.reset()
    }
    
    /// Start drift monitoring - no-op for WebRTC (we do periodic offset validation in processMicrophoneAudio)
    func startDriftMonitoring() {
        // No-op - offset validation is built into the processing loop
    }
    
    // MARK: - Private Helpers
    
    /// Extract mic frame and absolute start index (returns nil if not enough data)
    private func extractMicFrameWithIndex() -> ([Float], Int64)? {
        return state.withLock { state in
            guard state.micRingBuffer.available >= frameSize else { return nil }
            let startIndex = state.totalMicSamples - Int64(state.micRingBuffer.available)
            var buffer = [Float](repeating: 0, count: frameSize)
            let success = buffer.withUnsafeMutableBufferPointer { ptr in
                state.micRingBuffer.popInto(ptr, count: frameSize)
            }
            return success ? (buffer, startIndex) : nil
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
