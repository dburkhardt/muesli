//
//  AudioSynchronizer.swift
//  Muesli
//
//  Unified sample-index timeline for render (tap) and capture (mic) streams.
//  Pairs audio by sample index (NOT timestamp-nearest).
//  Outputs aligned 10ms frames for AEC processing.
//

import Foundation
import os.lock
import os.log

// MARK: - Synchronizer State

/// Current state of audio synchronization
enum SynchronizerState: Equatable {
    case initializing       // Collecting initial buffers
    case priming            // Building render lead
    case stable             // Normal operation
    case unstable           // Discontinuity detected, re-syncing
}

// MARK: - Aligned Frame

/// An aligned pair of render and capture audio frames (10ms each)
struct AlignedFrame {
    /// Render (system audio) samples - Float32 mono
    let renderSamples: [Float]

    /// Capture (microphone) samples - Float32 mono
    let captureSamples: [Float]

    /// Sample index for this frame
    let sampleIndex: Int64

    /// Frame size in samples (480 for 10ms at 48kHz)
    let frameSize: Int

    /// Whether the alignment is considered stable
    let isStable: Bool

    /// Host time from the render stream (for downstream timing metadata)
    let renderHostTime: UInt64
}

// MARK: - Synchronizer Statistics

/// Statistics from the synchronizer for telemetry
struct SynchronizerStats {
    var renderBufferDepthMs: Double = 0
    var captureBufferDepthMs: Double = 0
    var coarseDelayMs: Double = 0
    var delayVarianceMs: Double = 0
    var driftPPM: Double = 0
    var underruns: Int = 0
    var overruns: Int = 0
    var discontinuities: Int = 0
    var framesProcessed: Int64 = 0
    var alignmentStableSeconds: Double = 0
}

// MARK: - Audio Synchronizer

/// Synchronizes render (tap) and capture (mic) audio streams
/// Uses sample-index timeline (NOT timestamp-nearest matching)
final class AudioSynchronizer {
    
    // MARK: - Configuration
    
    /// Frame size in samples (10ms at 48kHz)
    static let frameSizeSamples = 480
    
    /// Sample rate
    static let sampleRate = 48000
    
    /// Target render lead in ms (default: 200ms)
    static let targetRenderLeadMs = 200
    
    /// Render lead band [150ms, 300ms]
    static let minRenderLeadMs = 100  // was 150; real-world lead is ~130ms
    static let maxRenderLeadMs = 300
    
    /// Max render buffer (600ms)
    static let maxRenderBufferMs = 600
    
    /// Max capture buffer (250ms)
    static let maxCaptureBufferMs = 250
    
    /// Stability threshold (10ms at 48kHz)
    static let stabilityThresholdSamples = 480
    
    /// Minimum stable time for AEC adaptation (5 seconds)
    static let minStableTimeSeconds: TimeInterval = 5
    
    /// Minimum time without discontinuity for stable state (10 seconds)
    static let minNoDiscontinuitySeconds: TimeInterval = 10

    /// Debounce cooldown for repeated discontinuities (2 seconds)
    static let discontinuityDebounceSeconds: TimeInterval = 2.0

    // For testing only: allow overriding timing constants
    struct TimingConfig {
        var minNoDiscontinuitySeconds: TimeInterval = AudioSynchronizer.minNoDiscontinuitySeconds
        var discontinuityDebounceSeconds: TimeInterval = AudioSynchronizer.discontinuityDebounceSeconds
    }

    private let timingConfig: TimingConfig

    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "AudioSynchronizer")
    
    /// Render (tap/system audio) ring buffer
    private let renderRing: TapCaptureRing
    
    /// Capture (mic) ring buffer
    private let captureRing: MicCaptureRing
    
    /// Coarse delay controller
    private let delayController: CoarseDelayController
    
    /// Drift tracker
    private let driftTracker: DriftTracker
    
    /// Current state
    private(set) var state: SynchronizerState = .initializing
    
    /// Current device topology mode
    private var topologyMode: DeviceTopologyMode = .unknown
    
    /// Statistics
    private var stats = SynchronizerStats()
    
    /// Last stable time
    private var lastStableTime: Date?
    
    /// Last discontinuity time
    private var lastDiscontinuityTime: Date?
    
    /// Pre-allocated output buffers
    private var renderOutputBuffer: [Float]
    private var captureOutputBuffer: [Float]
    
    /// Current sample index for output frames
    private var outputSampleIndex: Int64 = 0

    /// Last-seen render hostTime (propagated to AlignedFrame for downstream metadata)
    private var lastRenderHostTime: UInt64 = 0
    
    /// Lock for state access (RT-safe: os_unfair_lock has priority donation, no priority inversion)
    private let stateLock = OSAllocatedUnfairLock()
    
    // MARK: - Initialization
    
    init(timingConfig: TimingConfig = TimingConfig()) {
        self.timingConfig = timingConfig
        // Create ring buffers with plan-specified capacities
        renderRing = TapCaptureRing(capacityMs: Self.maxRenderBufferMs)
        captureRing = MicCaptureRing(capacityMs: Self.maxCaptureBufferMs)
        delayController = CoarseDelayController()
        driftTracker = DriftTracker()

        // Pre-allocate output buffers (10ms at 48kHz)
        renderOutputBuffer = [Float](repeating: 0, count: Self.frameSizeSamples)
        captureOutputBuffer = [Float](repeating: 0, count: Self.frameSizeSamples)

        logger.info("AudioSynchronizer initialized")
    }
    
    // MARK: - Public API
    
    /// Configure for device topology
    func configure(topologyMode: DeviceTopologyMode) {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        self.topologyMode = topologyMode
        
        // In headset mode, use more conservative settings
        if topologyMode == .headset {
            delayController.setHeadsetMode(true)
        } else {
            delayController.setHeadsetMode(false)
        }
        
        logger.info("Configured for topology: \(String(describing: topologyMode))")
        
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "SYNC_CONFIG: topology=\(topologyMode)")
        }
    }
    
    /// Push render (system audio) samples
    /// - Parameters:
    ///   - samples: Audio samples (Float32)
    ///   - count: Number of samples
    ///   - sampleTime: Sample time from timestamp
    ///   - hostTime: Host time from timestamp
    func pushRender(
        samples: UnsafePointer<Float>,
        count: Int,
        sampleTime: Float64,
        hostTime: UInt64
    ) {
        renderRing.push(samples: samples, count: count, sampleTime: sampleTime, hostTime: hostTime)

        // Update drift tracker with render timing
        driftTracker.updateRender(sampleTime: sampleTime, hostTime: hostTime, sampleCount: count)

        // Protect shared state: lastRenderHostTime and handleDiscontinuity writes
        stateLock.lock()
        // Track render hostTime for propagation to AlignedFrame
        lastRenderHostTime = hostTime

        // Check for discontinuity
        if renderRing.hasDiscontinuity {
            handleDiscontinuity(source: "render")
        }
        stateLock.unlock()
    }
    
    /// Push capture (mic) samples
    /// - Parameters:
    ///   - samples: Audio samples (Float32)
    ///   - count: Number of samples
    ///   - sampleTime: Sample time from timestamp
    ///   - hostTime: Host time from timestamp
    func pushCapture(
        samples: UnsafePointer<Float>,
        count: Int,
        sampleTime: Float64,
        hostTime: UInt64
    ) {
        captureRing.push(samples: samples, count: count, sampleTime: sampleTime, hostTime: hostTime)

        // Update drift tracker with capture timing
        driftTracker.updateCapture(sampleTime: sampleTime, hostTime: hostTime, sampleCount: count)

        // Protect shared state: handleDiscontinuity writes
        stateLock.lock()
        // Check for discontinuity
        if captureRing.hasDiscontinuity {
            handleDiscontinuity(source: "capture")
        }
        stateLock.unlock()
    }
    
    /// Get next aligned frame for AEC processing
    /// Returns nil if not enough data is available
    func getAlignedFrame() -> AlignedFrame? {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        // Check state
        switch state {
        case .initializing:
            if canTransitionToPriming() {
                state = .priming
            } else {
                return nil
            }
            fallthrough
            
        case .priming:
            if canTransitionToStable() {
                state = .stable
                lastStableTime = Date()
                delayController.unfreezeAdaptation()
                let renderLeadSamples = renderRing.available - captureRing.available
                logger.info("Synchronizer transitioned to stable from priming")
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "SYNC_STATE: stable, renderLead=\(renderLeadSamples)samples")
                }
            } else {
                // Continue priming - wait for render lead
                return nil
            }
            fallthrough
            
        case .unstable:
            // During unstable state, still output frames but mark as unstable
            // Re-check stability conditions
            if canTransitionToStable() {
                state = .stable
                lastStableTime = Date()
                delayController.unfreezeAdaptation()
                let renderLeadSamples = renderRing.available - captureRing.available
                logger.info("Synchronizer transitioned to stable from unstable")
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "SYNC_STATE: stable, renderLead=\(renderLeadSamples)samples")
                }
            }
            fallthrough
            
        case .stable:
            break
        }
        
        // Check buffer levels
        let renderAvailable = renderRing.available
        let captureAvailable = captureRing.available
        
        // Need at least one frame of each
        guard captureAvailable >= Self.frameSizeSamples else {
            return nil
        }
        
        // Get coarse delay for alignment
        let coarseDelaySamples = delayController.currentDelaySamples
        
        // Calculate render position for this capture frame
        let captureStartIndex = captureRing.currentStartIndex
        let renderTargetIndex = captureStartIndex - Int64(coarseDelaySamples)
        
        // Check if render data is available at target position
        let renderStartIndex = renderRing.currentStartIndex
        let renderEndIndex = renderRing.currentEndIndex
        
        var alignedRenderAvailable = true
        
        if renderTargetIndex < renderStartIndex {
            // Render underflow - target is before available data
            // Use oldest available render data instead
            alignedRenderAvailable = false
            stats.underruns += 1
        } else if renderTargetIndex + Int64(Self.frameSizeSamples) > renderEndIndex {
            // Render not yet available - target is ahead of available data
            // This means capture is ahead of render (opposite of expected)
            alignedRenderAvailable = false
        }
        
        // Extract capture frame
        guard let captureFrame = captureRing.popArray(count: Self.frameSizeSamples) else {
            return nil
        }
        
        // Extract render frame (aligned or fallback)
        var renderFrame: [Float]
        
        if alignedRenderAvailable {
            // Read aligned render data
            renderFrame = [Float](repeating: 0, count: Self.frameSizeSamples)
            let success = renderRing.read(
                at: renderTargetIndex,
                count: Self.frameSizeSamples,
                into: &renderFrame
            )
            
            if !success {
                // Fallback to zeros if read fails
                renderFrame = [Float](repeating: 0, count: Self.frameSizeSamples)
            }
            
            // Discard render samples up to target (maintain lead)
            let discardCount = Int(renderTargetIndex + Int64(Self.frameSizeSamples) - renderStartIndex)
            if discardCount > 0 {
                renderRing.discard(min(discardCount, renderAvailable))
            }
        } else {
            // Use silence or oldest available as fallback
            renderFrame = [Float](repeating: 0, count: Self.frameSizeSamples)
        }
        
        // Update statistics
        stats.framesProcessed += 1
        stats.renderBufferDepthMs = Double(renderRing.available) / Double(Self.sampleRate) * 1000
        stats.captureBufferDepthMs = Double(captureRing.available) / Double(Self.sampleRate) * 1000
        
        // Check stability
        let isStable = state == .stable && alignedRenderAvailable
        
        // Update delay controller (only when stable and aligned)
        if isStable {
            updateDelayController()
        }
        
        let frame = AlignedFrame(
            renderSamples: renderFrame,
            captureSamples: captureFrame,
            sampleIndex: outputSampleIndex,
            frameSize: Self.frameSizeSamples,
            isStable: isStable,
            renderHostTime: lastRenderHostTime
        )
        
        outputSampleIndex += Int64(Self.frameSizeSamples)
        
        return frame
    }
    
    /// Check if alignment is currently stable
    var isStable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state == .stable
    }
    
    /// Get current statistics
    func getStats() -> SynchronizerStats {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        var currentStats = stats
        currentStats.coarseDelayMs = Double(delayController.currentDelaySamples) / Double(Self.sampleRate) * 1000
        currentStats.driftPPM = driftTracker.currentDriftPPM
        
        if let stableTime = lastStableTime, state == .stable {
            currentStats.alignmentStableSeconds = Date().timeIntervalSince(stableTime)
        }
        
        return currentStats
    }
    
    /// Reset the synchronizer (call on route change, etc.)
    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }

        renderRing.reset()
        captureRing.reset()
        delayController.reset()
        driftTracker.reset()

        state = .initializing
        lastStableTime = nil
        lastDiscontinuityTime = Date()
        outputSampleIndex = 0
        lastRenderHostTime = 0

        stats.discontinuities += 1

        logger.info("Synchronizer reset")

        let logDiscontinuities = self.stats.discontinuities
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "SYNC_RESET: discontinuities=\(logDiscontinuities)")
        }
    }

    /// Reset the synchronizer for a brand-new recording session (no cooldown carry-over)
    func resetForNewSession() {
        stateLock.lock()
        defer { stateLock.unlock() }
        renderRing.reset()
        captureRing.reset()
        delayController.reset()
        driftTracker.reset()
        state = .initializing
        lastStableTime = nil
        lastDiscontinuityTime = nil   // No cooldown for fresh session
        outputSampleIndex = 0
        lastRenderHostTime = 0
        stats = SynchronizerStats()   // Fresh stats

        logger.info("Synchronizer reset for new session")
        Task {
            await DiagnosticLogger.shared.log(.aec, "SYNC_RESET_NEW_SESSION")
        }
    }
    
    // MARK: - Private Implementation
    
    /// Check if we can transition from initializing to priming
    private func canTransitionToPriming() -> Bool {
        // Need some data in both buffers
        return renderRing.available > 0 && captureRing.available > 0
    }
    
    /// Check if we can transition to stable state
    private func canTransitionToStable() -> Bool {
        // Calculate current render lead
        let renderLeadSamples = renderRing.available - captureRing.available
        let targetLeadSamples = Self.targetRenderLeadMs * Self.sampleRate / 1000
        let minLeadSamples = Self.minRenderLeadMs * Self.sampleRate / 1000
        let maxLeadSamples = Self.maxRenderLeadMs * Self.sampleRate / 1000
        
        // Check if render lead is within acceptable band
        let leadInBand = renderLeadSamples >= minLeadSamples && renderLeadSamples <= maxLeadSamples
        
        // Check if enough time has passed without discontinuity
        var noRecentDiscontinuity = true
        if let lastDisc = lastDiscontinuityTime {
            noRecentDiscontinuity = Date().timeIntervalSince(lastDisc) >= timingConfig.minNoDiscontinuitySeconds / 2
        }
        
        return leadInBand && noRecentDiscontinuity
    }
    
    /// Handle discontinuity from either stream
    private func handleDiscontinuity(source: String) {
        stats.discontinuities += 1

        let now = Date()
        let shouldRefreshCooldown: Bool
        if let lastDisc = lastDiscontinuityTime {
            shouldRefreshCooldown = now.timeIntervalSince(lastDisc) >= timingConfig.discontinuityDebounceSeconds
        } else {
            shouldRefreshCooldown = true
        }

        if shouldRefreshCooldown {
            lastDiscontinuityTime = now
        }

        let isNewTransition = state != .unstable
        if isNewTransition {
            state = .unstable
        }

        let logDiscontinuities = self.stats.discontinuities
        if isNewTransition {
            logger.warning("Discontinuity detected from \(source)")
        } else {
            logger.info("Repeated discontinuity from \(source) (cooldown refreshed=\(shouldRefreshCooldown))")
        }

        Task {
            await DiagnosticLogger.shared.log(.aec,
                "SYNC_DISCONTINUITY: source=\(source), total=\(logDiscontinuities), repeated=\(!isNewTransition), cooldownRefreshed=\(shouldRefreshCooldown)")
        }

        renderRing.clearDiscontinuity()
        captureRing.clearDiscontinuity()
        delayController.freezeAdaptation()
    }
    
    /// Update delay controller with current buffer state
    private func updateDelayController() {
        // Only update during stable, far-end dominant periods
        let renderDepth = renderRing.available
        let captureDepth = captureRing.available
        
        // Calculate observed delay from buffer depths
        let observedDelaySamples = renderDepth - captureDepth
        
        delayController.update(observedDelaySamples: observedDelaySamples)
    }
}
