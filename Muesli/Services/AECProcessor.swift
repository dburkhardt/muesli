//
//  AECProcessor.swift
//  Muesli
//
//  AEC Pipeline wrapper with gating for the Core Audio tap architecture.
//  Integrates with AudioSynchronizer for aligned frame processing.
//  Implements AEC gating per plan: only adapt when stable.
//

import Foundation
import os.lock
import os.log

// MARK: - AEC Mode

/// AEC operating mode based on device topology
enum AECMode: Equatable {
    case off              // AEC disabled (headset mode default)
    case conservative     // AEC enabled but with conservative settings
    case aggressive       // Full AEC (speakerphone mode)
}

// MARK: - AEC Statistics

/// Delay-hint source used for setStreamDelayMs.
/// This is propagated from AudioWorker's synchronizer strategy so we can
/// track whether coarse delay, seeded fallback, or no delay hint was used.
enum AECStreamDelayHintSource: Int {
    case unknown = 0
    case coarse
    case seeded
    case none
    
    var label: String {
        switch self {
        case .unknown:
            return "unknown"
        case .coarse:
            return "coarse"
        case .seeded:
            return "seeded"
        case .none:
            return "none"
        }
    }
}

private enum DelayMismatchTier {
    case none
    case warn
    case fail
}

/// Statistics from AEC processing
struct AECStats {
    var erleDb: Float = 0
    var delayMs: Int = 0
    var framesProcessed: Int64 = 0
    var framesSkipped: Int64 = 0
    var adaptationFrozen: Bool = false
    var currentMode: AECMode = .off
    /// Rolling RMS of the render (far-end) signal, in linear scale (updated per telemetry interval).
    var renderRmsLinear: Float = 0
    /// Rolling RMS of the capture (near-end/mic) signal, in linear scale (updated per telemetry interval).
    var captureRmsLinear: Float = 0
    /// Last delay value fed to AEC3 via setStreamDelayMs (ms). -1 if never set.
    var lastStreamDelayMs: Int = -1
    /// Last unbounded stream delay hint passed into AECProcessor (ms), before clamp.
    /// -1 when never set.
    var lastStreamDelayRawMs: Int = -1
    /// Last stream-delay hint source used when calling setStreamDelayMs.
    var lastStreamDelayHintSource: AECStreamDelayHintSource = .unknown
}

// MARK: - AEC Processor

/// AEC processor wrapper that integrates with the synchronizer pipeline
/// Implements gating rules from the plan:
/// - Only adapt when synchronizer is stable
/// - Freeze adaptation during instability
/// - Default AEC off for headset mode
final class AECProcessor {
    // MARK: - Configuration
    
    /// Frame size (10ms at 48kHz)
    static let frameSizeSamples = 480
    
    /// Sample rate
    static let sampleRate: Int32 = 48000
    
    // MARK: - Properties

    private let logger = Logger(subsystem: "com.muesli.app", category: "AECProcessor")

    /// Session ID for log correlation (short 8-char UUID prefix, set via configure())
    private var sessionID: String = "none"

    /// Reference to the synchronizer for telemetry queries (seeded delay, stable state).
    /// Set via configure(topology:sessionID:synchronizer:).
    private weak var synchronizerRef: AudioSynchronizer?

    /// Sustained delay-mismatch tracking for DELAY_MISMATCH warning.
    private var delayMismatchStartFrame: Int64 = -1
    /// Sustained delay-mismatch tracking for DELAY_MISMATCH_FAIL.
    private var delayMismatchFailStartFrame: Int64 = -1
    /// Current mismatch state to emit DELAY_MISMATCH_CLEARED when recovered.
    private var delayMismatchState: DelayMismatchTier = .none
    
    private struct DelayMismatchDecision {
        let emitWarn: Bool
        let emitFail: Bool
        let emitClear: Bool
        let mismatchMs: Int
        let warnSustainedFrames: Int64
        let failSustainedFrames: Int64
    }

    private struct State: @unchecked Sendable {
        var bridge: WebRTCAECBridge?
        var mode: AECMode = .off
        var topologyMode: DeviceTopologyMode = .unknown
        var isAdaptationFrozen: Bool = false
        var stats = AECStats()
        var outputBuffer = [Float](repeating: 0, count: AECProcessor.frameSizeSamples)
        /// Pre-allocated silence buffer — fed to AEC3 render path when adaptation is frozen
        /// to starve the adaptive filter without disrupting audio output.
        var silenceBuffer = [Float](repeating: 0, count: AECProcessor.frameSizeSamples)
    }

    /// RT-safe state lock for all mutable processor state.
    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    
    // MARK: - Initialization
    
    init() {
        initializeAEC()
    }
    
    deinit {
        stateLock.withLock { state in
            state.bridge = nil
        }
    }
    
    // MARK: - Public API

    /// Current operating mode
    var mode: AECMode {
        stateLock.withLock { state in
            state.mode
        }
    }

    /// Whether adaptation is currently frozen
    var isAdaptationFrozen: Bool {
        stateLock.withLock { state in
            state.isAdaptationFrozen
        }
    }
    
    /// Configure AEC for device topology
    /// - Parameters:
    ///   - topology: Current device topology mode
    ///   - sessionID: Short session UUID for log correlation (default "none")
    ///   - synchronizer: AudioSynchronizer reference for telemetry queries (optional)
    func configure(topology: DeviceTopologyMode, sessionID: String = "none", synchronizer: AudioSynchronizer? = nil) {
        self.sessionID = sessionID
        self.synchronizerRef = synchronizer
        self.delayMismatchStartFrame = -1

        let logMode = stateLock.withLock { state -> AECMode in
            state.topologyMode = topology

            switch topology {
            case .headset:
                // Headset mode: AEC off by default to avoid artifacts
                state.mode = .off
            case .speakerphone:
                // Speakerphone mode: Full AEC enabled
                state.mode = .aggressive
            case .unknown:
                // Unknown: Use conservative AEC
                state.mode = .conservative
            }

            state.stats.currentMode = state.mode
            return state.mode
        }

        switch logMode {
        case .off:
            logger.info("AEC mode: OFF (headset)")
        case .aggressive:
            logger.info("AEC mode: AGGRESSIVE (speakerphone)")
        case .conservative:
            logger.info("AEC mode: CONSERVATIVE (unknown topology)")
        }

        let logSessionID = self.sessionID
        let estimatorEnabled = isExternalDelayEstimatorEnabled
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "session=\(logSessionID) AEC_CONFIG: mode=\(logMode), topology=\(topology), externalDelayEstimator=\(estimatorEnabled)")
        }
    }
    
    /// Feed render (far-end/system) frame to WebRTC.
    /// This must be called whenever render arrives, independent of capture handling.
    /// - Parameters:
    ///   - samples: Mono 10ms frame (480 samples @ 48kHz)
    ///   - isStable: Whether adaptation should currently be allowed
    /// - Returns: True if frame was successfully fed to WebRTC
    @discardableResult
    func feedRenderFrame(_ samples: [Float], isStable: Bool = true) -> Bool {
        guard samples.count == Self.frameSizeSamples else {
            logger.warning("Invalid render frame size: \(samples.count), expected \(Self.frameSizeSamples)")
            assertionFailure("AEC render frame size invariant violated: \(samples.count) != \(Self.frameSizeSamples)")
            stateLock.withLock { state in
                state.stats.framesSkipped += 1
            }
            return false
        }

        let result = stateLock.withLock { state -> (feedSucceeded: Bool, shouldLogGatingChange: Bool, logFrozen: Bool, preservedFilterState: Bool, shouldWarn: Bool) in
            guard state.mode != .off else {
                state.stats.framesSkipped += 1
                return (false, false, false, false, false)
            }

            let (changed, frozen, preservedFilterState) = Self.updateGatingLocked(state: &state, isStable: isStable)

            guard let bridge = state.bridge, bridge.isReady else {
                state.stats.framesSkipped += 1
                return (false, changed, frozen, preservedFilterState, false)
            }

            // When adaptation is frozen, feed silence to AEC3's render path.
            // This starves the adaptive filter (no far-end reference) without
            // disrupting capture-side audio output.
            let feedSucceeded: Bool
            if state.isAdaptationFrozen {
                feedSucceeded = state.silenceBuffer.withUnsafeBufferPointer { ptr in
                    bridge.processRenderFrame(ptr.baseAddress!)
                }
            } else {
                feedSucceeded = samples.withUnsafeBufferPointer { ptr in
                    bridge.processRenderFrame(ptr.baseAddress!)
                }
            }

            if !feedSucceeded {
                state.stats.framesSkipped += 1
                return (false, changed, frozen, preservedFilterState, true)
            }

            state.stats.erleDb = bridge.getERLE()
            state.stats.delayMs = Int(bridge.getDelayMs())
            return (true, changed, frozen, preservedFilterState, false)
        }

        if result.shouldLogGatingChange {
            let logSessionID = self.sessionID
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "session=\(logSessionID) AEC_GATING: frozen=\(result.logFrozen), stable=\(isStable)")
            }
            if result.preservedFilterState {
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "session=\(logSessionID) AEC_GATING_PRESERVED: stable=\(isStable)")
                }
            }
        }

        if result.shouldWarn {
            logger.warning("Render frame processing failed")
        }

        return result.feedSucceeded
    }

    /// Process capture (near-end/microphone) frame.
    /// - Parameters:
    ///   - captureSamples: Mono 10ms frame (480 samples @ 48kHz)
    ///   - isStable: Whether adaptation should currently be allowed
    /// - Returns: Echo-cancelled capture samples (or pass-through on failure/disabled)
    func processCaptureFrame(
        _ captureSamples: [Float],
        isStable: Bool = true
    ) -> [Float] {
        guard captureSamples.count == Self.frameSizeSamples else {
            logger.warning("Invalid capture frame size: \(captureSamples.count), expected \(Self.frameSizeSamples)")
            assertionFailure("AEC capture frame size invariant violated: \(captureSamples.count) != \(Self.frameSizeSamples)")
            stateLock.withLock { state in
                state.stats.framesSkipped += 1
            }
            return captureSamples
        }

        let result = stateLock.withLock { state -> (output: [Float], captureSucceeded: Bool, shouldLogGatingChange: Bool, logFrozen: Bool, preservedFilterState: Bool, shouldWarn: Bool) in
            guard state.mode != .off else {
                state.stats.framesSkipped += 1
                return (captureSamples, false, false, false, false, false)
            }

            let (changed, frozen, preservedFilterState) = Self.updateGatingLocked(state: &state, isStable: isStable)

            guard let bridge = state.bridge, bridge.isReady else {
                state.stats.framesSkipped += 1
                return (captureSamples, false, changed, frozen, preservedFilterState, false)
            }

            let captureSucceeded = captureSamples.withUnsafeBufferPointer { inputPtr in
                state.outputBuffer.withUnsafeMutableBufferPointer { outputPtr in
                    bridge.processCaptureFrame(
                        inputPtr.baseAddress!,
                        outputSamples: outputPtr.baseAddress!
                    )
                }
            }

            if !captureSucceeded {
                state.stats.framesSkipped += 1
                return (captureSamples, false, changed, frozen, preservedFilterState, true)
            }

            state.stats.framesProcessed += 1
            state.stats.erleDb = bridge.getERLE()
            state.stats.delayMs = Int(bridge.getDelayMs())
            return (state.outputBuffer, true, changed, frozen, preservedFilterState, false)
        }

        if result.shouldLogGatingChange {
            let logSessionID = self.sessionID
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "session=\(logSessionID) AEC_GATING: frozen=\(result.logFrozen), stable=\(isStable)")
            }
            if result.preservedFilterState {
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "session=\(logSessionID) AEC_GATING_PRESERVED: stable=\(isStable)")
                }
            }
        }

        if result.shouldWarn {
            logger.warning("Capture frame processing failed")
        }

        return result.output
    }
    
    /// Freeze AEC adaptation (during discontinuity/instability)
    func freezeAdaptation() {
        stateLock.withLock { state in
            state.isAdaptationFrozen = true
            state.stats.adaptationFrozen = true
        }
        
        logger.info("AEC adaptation frozen")

        let logSessionID = self.sessionID
        Task {
            await DiagnosticLogger.shared.log(.aec, "session=\(logSessionID) AEC_FREEZE")
        }
    }
    
    /// Unfreeze AEC adaptation
    func unfreezeAdaptation() {
        stateLock.withLock { state in
            state.isAdaptationFrozen = false
            state.stats.adaptationFrozen = false
        }
        
        logger.info("AEC adaptation unfrozen")

        let logSessionID = self.sessionID
        Task {
            await DiagnosticLogger.shared.log(.aec, "session=\(logSessionID) AEC_UNFREEZE")
        }
    }
    
    /// Set the render-to-capture stream delay hint for AEC3's internal model.
    /// Must be called once per 10ms block, before processCaptureFrame.
    /// With current v2.x bundles this hint is treated as no-op unless external
    /// delay estimator support is available, so it is still captured for
    /// diagnostics even when it cannot be applied.
    /// - Parameter delayMs: Coarse delay from AudioSynchronizer (render-lead based)
    @discardableResult
    func setStreamDelayMs(
        _ delayMs: Int,
        source: AECStreamDelayHintSource = .unknown
    ) -> Bool {
        guard delayMs >= 0 else { return false }
        let boundedDelayMs = min(max(delayMs, 0), 500)
        return stateLock.withLock { state -> Bool in
            state.stats.lastStreamDelayRawMs = delayMs
            state.stats.lastStreamDelayHintSource = source
            guard let bridge = state.bridge, bridge.isReady else { return false }
            guard bridge.externalDelayEstimatorEnabled else {
                state.stats.lastStreamDelayMs = -1
                return true
            }
            let ok = bridge.setStreamDelayMs(Int32(boundedDelayMs))
            state.stats.lastStreamDelayMs = ok ? boundedDelayMs : -1
            return ok
        }
    }

    /// Reset AEC state
    func reset() {
        let statsSnapshot = stateLock.withLock { state -> AECStats in
            state.bridge?.reset()
            state.isAdaptationFrozen = false
            state.stats = AECStats()
            state.stats.currentMode = state.mode
            return state.stats
        }

        // Reset session-scoped telemetry counters so each new recording session
        // emits early AEC_TELEMETRY at ~1s/~2s regardless of prior sessions.
        lastTelemetryFrameCount = 0
        delayMismatchStartFrame = -1
        delayMismatchFailStartFrame = -1
        delayMismatchState = .none

        logger.info("AEC reset")

        let statsErle = statsSnapshot.erleDb
        let statsDelay = statsSnapshot.delayMs
        let logSessionID = self.sessionID
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "session=\(logSessionID) AEC_RESET: erle=\(statsErle)dB, delay=\(statsDelay)ms")
        }
    }
    
    /// Get current statistics
    func getStats() -> AECStats {
        stateLock.withLock { state in
            if let bridge = state.bridge, bridge.isReady {
                state.stats.erleDb = bridge.getERLE()
                state.stats.delayMs = Int(bridge.getDelayMs())
            }
            return state.stats
        }
    }

    // MARK: - Periodic Telemetry

    /// Whether the loaded WebRTC bridge advertises external delay support.
    var isExternalDelayEstimatorEnabled: Bool {
        stateLock.withLock { state in
            state.bridge?.externalDelayEstimatorEnabled ?? false
        }
    }

    /// Interval counter for telemetry logging (tracks capture frames processed).
    /// Internal (not private) so AudioWorker can read it to detect when a log was emitted.
    var lastTelemetryFrameCount: Int64 = 0

    /// Log AEC telemetry at a regular interval (call from worker loop).
    /// Logs ERLE, delay estimate, mode, feed counts, and signal RMS every `intervalFrames` capture frames.
    /// Also fires early at frame 100 (~1s) and 200 (~2s) for fast diagnostics.
    /// - Parameters:
    ///   - workerStats: Optional AudioWorkerStats for render lead distribution.
    ///   - renderRmsLinear: Rolling RMS of the render (far-end) signal (linear scale).
    ///   - captureRmsLinear: Rolling RMS of the capture (near-end/mic) signal (linear scale).
    func logPeriodicTelemetry(
        workerStats: AudioWorkerStats? = nil,
        renderRmsLinear: Float = 0,
        captureRmsLinear: Float = 0
    ) {
        let stats = getStats()
        let shouldLog: Bool
        let intervalFrames: Int64 = 1000  // ~10 seconds at 100 frames/sec

        // Early-fire at frame 100 (~1s) and 200 (~2s) for fast diagnostics
        let earlyFire = (lastTelemetryFrameCount < 100 && stats.framesProcessed >= 100)
            || (lastTelemetryFrameCount < 200 && stats.framesProcessed >= 200)

        if earlyFire || stats.framesProcessed - lastTelemetryFrameCount >= intervalFrames {
            lastTelemetryFrameCount = stats.framesProcessed
            shouldLog = true
        } else {
            shouldLog = false
        }

        guard shouldLog else { return }

        // Convert linear RMS to dBFS for logging
        let renderRmsDb = renderRmsLinear > 0 ? 20.0 * log10(renderRmsLinear) : -96.0
        let captureRmsDb = captureRmsLinear > 0 ? 20.0 * log10(captureRmsLinear) : -96.0

        // Query synchronizer for seeded delay and stable state
        let syncSeededDelayMs: Int
        let syncIsStable: Bool
        let syncDelayMs: Int
        if let sync = synchronizerRef {
            syncSeededDelayMs = sync.seededDelayMs
            syncIsStable = sync.isStable
            syncDelayMs = sync.coarseDelayMs
        } else {
            syncSeededDelayMs = -1
            syncIsStable = false
            syncDelayMs = -1
        }

        var msg = "session=\(sessionID) AEC_TELEMETRY: ERLE=\(String(format: "%.1f", stats.erleDb))dB"
        msg += ", delay=\(stats.delayMs)ms"
        msg += ", streamDelay=\(stats.lastStreamDelayMs)ms"
        msg += ", streamDelayRaw=\(stats.lastStreamDelayRawMs)ms"
        msg += ", streamDelaySource=\(stats.lastStreamDelayHintSource.label)"
        msg += ", externalDelayEstimator=\(isExternalDelayEstimatorEnabled)"
        msg += ", mode=\(stats.currentMode)"
        msg += ", processed=\(stats.framesProcessed)"
        msg += ", skipped=\(stats.framesSkipped)"
        msg += ", frozen=\(stats.adaptationFrozen)"
        msg += ", renderRms=\(String(format: "%.1f", renderRmsDb))dBFS"
        msg += ", captureRms=\(String(format: "%.1f", captureRmsDb))dBFS"
        msg += ", seededDelay=\(syncSeededDelayMs)ms"
        msg += ", stable=\(syncIsStable)"

        if let ws = workerStats {
            msg += ", renderLead=\(ws.renderLeadFrames)frames"
            msg += ", avgLoopMs=\(String(format: "%.2f", ws.workerLoopTimeMs))"
        }

        Task {
            await DiagnosticLogger.shared.log(.aec, msg)
        }

        // DELAY_AUDIT: compare bridge delay vs synchronizer delay
        let bridgeDelayMs = stats.delayMs
        let streamDelayMs = stats.lastStreamDelayMs
        let streamDelaySource = stats.lastStreamDelayHintSource.label
        let delta = bridgeDelayMs - syncDelayMs
        let auditMsg = "session=\(sessionID) DELAY_AUDIT: streamDelayMs=\(streamDelayMs)"
            + ", streamDelaySource=\(streamDelaySource)"
            + ", bridgeDelayMs=\(bridgeDelayMs)"
            + ", synchronizerDelayMs=\(syncDelayMs)"
            + ", delta=\(delta)ms"
        Task {
            await DiagnosticLogger.shared.log(.aec, auditMsg)
        }

        let mismatchDecision = evaluateDelayMismatch(
            bridgeDelayMs: bridgeDelayMs,
            syncDelayMs: syncDelayMs,
            renderRmsLinear: renderRmsLinear,
            captureRmsLinear: captureRmsLinear,
            framesProcessed: stats.framesProcessed
        )

        if mismatchDecision.emitWarn {
            let warnMsg = "session=\(sessionID) DELAY_MISMATCH_WARN: |sync-bridge|=\(mismatchDecision.mismatchMs)ms"
                + " sustained \(String(format: "%.1f", Double(mismatchDecision.warnSustainedFrames) / 100.0))s"
                + ", bridgeDelayMs=\(bridgeDelayMs)"
                + ", synchronizerDelayMs=\(syncDelayMs)"
                + ", renderRms=\(String(format: "%.1f", renderRmsDb))dBFS"
                + ", captureRms=\(String(format: "%.1f", captureRmsDb))dBFS"
            Task {
                await DiagnosticLogger.shared.log(.aec, warnMsg)
            }
        }

        if mismatchDecision.emitFail {
            let failMsg = "session=\(sessionID) DELAY_MISMATCH_FAIL: |sync-bridge|=\(mismatchDecision.mismatchMs)ms"
                + " sustained \(String(format: "%.1f", Double(mismatchDecision.failSustainedFrames) / 100.0))s"
                + ", bridgeDelayMs=\(bridgeDelayMs)"
                + ", synchronizerDelayMs=\(syncDelayMs)"
                + ", renderRms=\(String(format: "%.1f", renderRmsDb))dBFS"
                + ", captureRms=\(String(format: "%.1f", captureRmsDb))dBFS"
            Task {
                await DiagnosticLogger.shared.log(.aec, failMsg)
            }
        }

        if mismatchDecision.emitClear {
            let clearMsg = "session=\(sessionID) DELAY_MISMATCH_CLEARED: currentDelta=\(mismatchDecision.mismatchMs)ms"
            Task {
                await DiagnosticLogger.shared.log(.aec, clearMsg)
            }
        }

        // Detect stable-but-non-converging condition:
        // If we have been stable for >30 seconds (>3000 frames processed) but ERLE is still
        // very low (<2 dB), AEC3 has likely not converged. This can happen when:
        //   - The render/mic signal energy is too low (near silence)
        //   - The release build uses a stale/incompatible WebRTC artifact
        //   - The initialization sequence was incorrect (e.g., configure before reset)
        let erleThresholdDb: Float = 2.0
        let convergenceMinFrames: Int64 = 3000  // ~30 seconds at 100 frames/sec
        if stats.currentMode != .off
            && stats.framesProcessed >= convergenceMinFrames
            && !stats.adaptationFrozen
            && stats.erleDb < erleThresholdDb
            && renderRmsLinear > 0.001 { // render has actual signal (not silence)
            let nonConvergingMsg = "session=\(sessionID) AEC_NONCONVERGING: ERLE=\(String(format: "%.1f", stats.erleDb))dB"
                + " after \(stats.framesProcessed) frames"
                + ", renderRms=\(String(format: "%.1f", renderRmsDb))dBFS"
                + ", captureRms=\(String(format: "%.1f", captureRmsDb))dBFS"
                + ", mode=\(stats.currentMode)"
            Task {
                await DiagnosticLogger.shared.log(.aec, nonConvergingMsg)
            }
        }
    }

    /// Set AEC mode manually
    func setMode(_ newMode: AECMode) {
        stateLock.withLock { state in
            state.mode = newMode
            state.stats.currentMode = newMode
        }
        
        logger.info("AEC mode set: \(String(describing: newMode))")
    }
    
    // MARK: - Private Implementation
    
    /// Evaluate the delay mismatch policy without side effects beyond state updates.
    /// - Returns: Whether WARN/FAIL/CLEARED telemetry should be emitted for this frame.
    private func evaluateDelayMismatch(
        bridgeDelayMs: Int,
        syncDelayMs: Int,
        renderRmsLinear: Float,
        captureRmsLinear: Float,
        framesProcessed: Int64
    ) -> DelayMismatchDecision {
        let mismatchWarnThresholdMs = 20
        let mismatchFailThresholdMs = 80
        let mismatchWarnFrames: Int64 = 300  // ~3 seconds at 100 frames/sec
        let mismatchFailFrames: Int64 = 500  // ~5 seconds at 100 frames/sec
        let hasHealthyRms = renderRmsLinear > 0.001 && captureRmsLinear > 0.001
        let mismatchMs = abs(syncDelayMs - bridgeDelayMs)
        let isWarnCondition = mismatchMs > mismatchWarnThresholdMs &&
            mismatchMs < mismatchFailThresholdMs &&
            hasHealthyRms
        let isFailCondition = mismatchMs > mismatchFailThresholdMs && hasHealthyRms
        let previousMismatchState = delayMismatchState
        var warnSustainedFrames: Int64 = 0
        var failSustainedFrames: Int64 = 0
        var nextMismatchState: DelayMismatchTier = .none

        if isWarnCondition {
            if delayMismatchStartFrame < 0 {
                delayMismatchStartFrame = framesProcessed
            }
            warnSustainedFrames = (framesProcessed - delayMismatchStartFrame) + 1
            nextMismatchState = .warn
        } else {
            delayMismatchStartFrame = -1
        }

        if isFailCondition {
            if delayMismatchFailStartFrame < 0 {
                delayMismatchFailStartFrame = framesProcessed
            }
            failSustainedFrames = (framesProcessed - delayMismatchFailStartFrame) + 1
            nextMismatchState = .fail
        } else {
            delayMismatchFailStartFrame = -1
        }

        let emitWarn = isWarnCondition && warnSustainedFrames >= mismatchWarnFrames
        let emitFail = isFailCondition && failSustainedFrames >= mismatchFailFrames
        let emitClear = previousMismatchState != .none && nextMismatchState == .none
        delayMismatchState = nextMismatchState

        return DelayMismatchDecision(
            emitWarn: emitWarn,
            emitFail: emitFail,
            emitClear: emitClear,
            mismatchMs: mismatchMs,
            warnSustainedFrames: warnSustainedFrames,
            failSustainedFrames: failSustainedFrames
        )
    }

    #if DEBUG
    /// Debug-only evaluator for deterministic mismatch policy tests.
    func debugEvaluateDelayMismatch(
        bridgeDelayMs: Int,
        syncDelayMs: Int,
        renderRmsLinear: Float,
        captureRmsLinear: Float,
        framesProcessed: Int64
    ) -> (emitWarn: Bool, emitFail: Bool, emitClear: Bool, state: Int, mismatchMs: Int) {
        let result = evaluateDelayMismatch(
            bridgeDelayMs: bridgeDelayMs,
            syncDelayMs: syncDelayMs,
            renderRmsLinear: renderRmsLinear,
            captureRmsLinear: captureRmsLinear,
            framesProcessed: framesProcessed
        )
        let state: Int
        switch delayMismatchState {
        case .none: state = 0
        case .warn: state = 1
        case .fail: state = 2
        }
        return (
            emitWarn: result.emitWarn,
            emitFail: result.emitFail,
            emitClear: result.emitClear,
            state: state,
            mismatchMs: result.mismatchMs
        )
    }

    /// Reset delay mismatch tracking for deterministic tests.
    func debugResetDelayMismatchState() {
        delayMismatchStartFrame = -1
        delayMismatchFailStartFrame = -1
        delayMismatchState = .none
    }
    #endif
    
    /// Initialize the WebRTC AEC bridge
    private func initializeAEC() {
        var initSucceeded = false
        var initErrorMsg: String?
        do {
            let bridge = try WebRTCAECBridge(
                sampleRate: Self.sampleRate,
                channels: 1
            )
            // Use nonisolated(unsafe) to suppress the non-Sendable capture warning.
            // This is safe because the bridge is immediately moved into the lock-protected
            // state and never accessed concurrently.
            nonisolated(unsafe) let unsafeBridge = bridge
            stateLock.withLock { state in
                state.bridge = unsafeBridge
            }
            initSucceeded = true
            logger.info("WebRTC AEC initialized")
        } catch {
            initErrorMsg = error.localizedDescription
            logger.error("Failed to initialize AEC: \(error.localizedDescription)")
        }

        let logSessionID = self.sessionID
        Task {
            if initSucceeded {
                await DiagnosticLogger.shared.log(.aec, "session=\(logSessionID) AEC_INIT: WebRTC AEC3")
            } else if let msg = initErrorMsg {
                await DiagnosticLogger.shared.log(.aec, "session=\(logSessionID) AEC_INIT_FAILED: \(msg)")
            }
        }
    }
    
    /// Update gating based on stability
    private static func updateGatingLocked(state: inout State, isStable: Bool) -> (changed: Bool, frozen: Bool, preservedFilterState: Bool) {
        let wasAdaptationFrozen = state.isAdaptationFrozen
        var preservedFilterState = false

        if !isStable {
            if !state.isAdaptationFrozen {
                state.isAdaptationFrozen = true
                state.stats.adaptationFrozen = true
            }
        } else if state.isAdaptationFrozen {
            // Unfreeze when stable returns (any mode).
            // Preserve learned filter state through normal AEC pauses.
            // WebRTC AEC3 adapts with leaked memory and internal re-seeding,
            // so full bridge reset here slows convergence and can re-trigger
            // non-convergence on normal conversation gaps.
            preservedFilterState = true
            state.isAdaptationFrozen = false
            state.stats.adaptationFrozen = false
        }

        return (wasAdaptationFrozen != state.isAdaptationFrozen, state.isAdaptationFrozen, preservedFilterState)
    }
}
