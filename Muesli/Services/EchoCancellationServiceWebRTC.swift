import Foundation
import os.lock
import QuartzCore

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
    
    // MARK: - Initialization
    
    init() {
        self.state = OSAllocatedUnfairLock(initialState: SyncState(bufferCapacity: 24000))
        
        // Initialize WebRTC bridge
        var error: NSError?
        self.aecBridge = WebRTCAECBridge(sampleRate: Int32(sampleRate),
                                          channels: 1,
                                          error: &error)
        if let error = error {
            self.initializationError = error
            Task { await DiagnosticLogger.shared.log(.aec,
                "WEBRTC_INIT_FAILED: \(error.localizedDescription)") }
        } else {
            Task { await DiagnosticLogger.shared.log(.aec,
                "WEBRTC_INIT_SUCCESS: AEC3 ready, frameSize=480") }
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
        
        state.withLock { state in
            // Track timing for warmup
            if state.micBufferTimes.count < SyncState.kBuffersToAverage {
                state.micBufferTimes.append(now)
            }
            
            // Store mic samples
            state.micRingBuffer.push(microphoneSamples)
            state.totalMicSamples += Int64(microphoneSamples.count)
            
            // Calculate offset once we have enough timing data
            // Using 12 buffers (~1 second) instead of 50 buffers for faster sync.
            // Offset is validated periodically (every 100 frames) to catch warmup artifacts.
            if !state.offsetCalculated &&
               state.systemBufferTimes.count >= SyncState.kBuffersToAverage &&
               state.micBufferTimes.count >= SyncState.kBuffersToAverage {
                
                let avgSysTime = state.systemBufferTimes.reduce(0, +) / Double(SyncState.kBuffersToAverage)
                let avgMicTime = state.micBufferTimes.reduce(0, +) / Double(SyncState.kBuffersToAverage)
                let offsetSeconds = avgSysTime - avgMicTime
                state.deliveryOffsetSamples = Int64(offsetSeconds * Double(sampleRate))
                state.offsetCalculated = true
                
                // Immediate validation after warmup
                let actualDelta = state.totalSystemSamples - state.totalMicSamples
                let mismatch = abs(actualDelta - state.deliveryOffsetSamples)
                if mismatch > 2400 {  // >50ms drift
                    let oldOffset = state.deliveryOffsetSamples
                    state.deliveryOffsetSamples = max(-24000, min(24000, actualDelta))
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_OFFSET_CORRECTION: \(oldOffset)→\(state.deliveryOffsetSamples)") }
                }
                
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_OFFSET: \(state.deliveryOffsetSamples) samples (\(String(format: "%.1f", offsetSeconds * 1000))ms)") }
            }
            
            // LESSON 7: Periodic offset validation
            state.offsetValidationCount += 1
            if state.offsetCalculated && state.offsetValidationCount >= SyncState.kOffsetValidationInterval {
                state.offsetValidationCount = 0
                let actualDelta = state.totalSystemSamples - state.totalMicSamples
                let mismatch = abs(actualDelta - state.deliveryOffsetSamples)
                if mismatch > 2400 {  // >50ms drift
                    let oldOffset = state.deliveryOffsetSamples
                    state.deliveryOffsetSamples = max(-24000, min(24000, actualDelta))
                    Task { await DiagnosticLogger.shared.log(.aec,
                        "WEBRTC_OFFSET_CORRECTION: \(oldOffset)→\(state.deliveryOffsetSamples)") }
                }
            }
            
            currentOffset = state.deliveryOffsetSamples
            offsetReady = state.offsetCalculated
        }
        
        // Step 2: Process in 10ms frames with ACTUAL ALIGNMENT
        var outputSamples: [Float] = []
        outputSamples.reserveCapacity(microphoneSamples.count)
        
        // Process frames (outside lock to avoid blocking)
        while true {
            // Try to get one frame of mic audio
            let gotMicFrame = state.withLock { state in
                state.micRingBuffer.available >= frameSize
            }
            guard gotMicFrame else { break }
            
            // Extract mic frame under lock
            var micFrameData = captureFrame  // Use pre-allocated buffer
            let extracted = state.withLock { state in
                micFrameData.withUnsafeMutableBufferPointer { ptr in
                    state.micRingBuffer.popInto(ptr, count: frameSize)
                }
            }
            guard extracted else { break }
            
            // Find MATCHING system audio using offset (THIS IS THE KEY FIX)
            var renderFrameData = renderFrame
            var gotRenderFrame = false
            
            if offsetReady {
                gotRenderFrame = state.withLock { state in
                    // Calculate where to read from in system buffer (offset from head)
                    // Positive offset: system arrives later → read older system samples
                    // Negative offset: system arrives earlier → read newer system samples
                    let available = state.systemRingBuffer.available
                    let targetOffset: Int
                    if currentOffset >= 0 {
                        targetOffset = max(0, Int(currentOffset) - frameSize)
                    } else {
                        // Use tail-aligned read when system leads (negative offset)
                        targetOffset = max(0, available - frameSize + Int(currentOffset))
                    }
                    if available >= targetOffset + frameSize {
                        return renderFrameData.withUnsafeMutableBufferPointer { ptr in
                            state.systemRingBuffer.read(at: targetOffset, count: frameSize, into: ptr)
                        }
                    }
                    return false
                }
            }
            
            // LESSON 7: Bounds check fallback - pass through if no matching system audio
            if !gotRenderFrame {
                // No matching system audio - pass through original mic audio
                outputSamples.append(contentsOf: micFrameData.prefix(frameSize))
                continue
            }
            
            // Feed ALIGNED frames to WebRTC (render BEFORE capture)
            var processedFrame = outputFrame
            
            // Process render (system) frame first
            let renderSuccess = renderFrameData.withUnsafeBufferPointer { ptr in
                aecBridge?.processRenderFrame(ptr.baseAddress!) ?? false
            }
            
            if !renderSuccess {
                // Render processing failed - log error and pass through
                Task { await DiagnosticLogger.shared.log(.aec,
                    "WEBRTC_RENDER_FAILED: \(aecBridge?.lastError.rawValue ?? -1)") }
                outputSamples.append(contentsOf: micFrameData.prefix(frameSize))
                continue
            }
            
            // Then process capture (mic) frame
            let captureSuccess = micFrameData.withUnsafeBufferPointer { inputPtr in
                processedFrame.withUnsafeMutableBufferPointer { outputPtr in
                    aecBridge?.processCaptureFrame(inputPtr.baseAddress!, outputSamples: outputPtr.baseAddress!) ?? false
                }
            }
            
            if captureSuccess {
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
        
        // Return processed samples, or original if nothing was processed
        return outputSamples.isEmpty ? microphoneSamples : outputSamples
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
    
    // MARK: - Diagnostics
    
    /// Current ERLE (Echo Return Loss Enhancement) in dB
    var currentERLE: Float { aecBridge?.getERLE() ?? 0 }
    
    /// Current delay estimate in milliseconds
    var currentDelayMs: Int { Int(aecBridge?.getDelayMs() ?? -1) }
    
    /// Whether the AEC bridge is initialized and ready
    var isReady: Bool { aecBridge?.isReady ?? false }
}
