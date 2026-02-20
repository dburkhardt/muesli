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
    /// - Parameter topology: Current device topology mode
    func configure(topology: DeviceTopologyMode) {
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

        Task {
            await DiagnosticLogger.shared.log(.aec,
                "AEC_CONFIG: mode=\(logMode), topology=\(topology)")
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

        let result = stateLock.withLock { state -> (feedSucceeded: Bool, shouldLogGatingChange: Bool, logFrozen: Bool, shouldWarn: Bool) in
            guard state.mode != .off else {
                state.stats.framesSkipped += 1
                return (false, false, false, false)
            }

            let (changed, frozen) = Self.updateGatingLocked(state: &state, isStable: isStable)

            guard let bridge = state.bridge, bridge.isReady else {
                state.stats.framesSkipped += 1
                return (false, changed, frozen, false)
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
                return (false, changed, frozen, true)
            }

            state.stats.erleDb = bridge.getERLE()
            state.stats.delayMs = Int(bridge.getDelayMs())
            return (true, changed, frozen, false)
        }

        if result.shouldLogGatingChange {
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "AEC_GATING: frozen=\(result.logFrozen), stable=\(isStable)")
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

        let result = stateLock.withLock { state -> (output: [Float], captureSucceeded: Bool, shouldLogGatingChange: Bool, logFrozen: Bool, shouldWarn: Bool) in
            guard state.mode != .off else {
                state.stats.framesSkipped += 1
                return (captureSamples, false, false, false, false)
            }

            let (changed, frozen) = Self.updateGatingLocked(state: &state, isStable: isStable)

            guard let bridge = state.bridge, bridge.isReady else {
                state.stats.framesSkipped += 1
                return (captureSamples, false, changed, frozen, false)
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
                return (captureSamples, false, changed, frozen, true)
            }

            state.stats.framesProcessed += 1
            state.stats.erleDb = bridge.getERLE()
            state.stats.delayMs = Int(bridge.getDelayMs())
            return (state.outputBuffer, true, changed, frozen, false)
        }

        if result.shouldLogGatingChange {
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "AEC_GATING: frozen=\(result.logFrozen), stable=\(isStable)")
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
        
        Task {
            await DiagnosticLogger.shared.log(.aec, "AEC_FREEZE")
        }
    }
    
    /// Unfreeze AEC adaptation
    func unfreezeAdaptation() {
        stateLock.withLock { state in
            state.isAdaptationFrozen = false
            state.stats.adaptationFrozen = false
        }
        
        logger.info("AEC adaptation unfrozen")
        
        Task {
            await DiagnosticLogger.shared.log(.aec, "AEC_UNFREEZE")
        }
    }
    
    /// Set the render-to-capture stream delay for AEC3's internal model.
    /// Must be called once per 10ms block, before processCaptureFrame.
    /// AEC3 compiled with use_external_delay_estimator=true requires this — without it,
    /// it assumes delay=0 and cannot converge regardless of signal quality.
    /// - Parameter delayMs: Coarse delay from AudioSynchronizer (render-lead based)
    @discardableResult
    func setStreamDelayMs(_ delayMs: Int) -> Bool {
        guard delayMs >= 0 else { return false }
        return stateLock.withLock { state -> Bool in
            guard let bridge = state.bridge, bridge.isReady else { return false }
            return bridge.setStreamDelayMs(Int32(delayMs))
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
        
        logger.info("AEC reset")

        let statsErle = statsSnapshot.erleDb
        let statsDelay = statsSnapshot.delayMs
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "AEC_RESET: erle=\(statsErle)dB, delay=\(statsDelay)ms")
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

    /// Interval counter for telemetry logging (tracks capture frames processed).
    /// Internal (not private) so AudioWorker can read it to detect when a log was emitted.
    var lastTelemetryFrameCount: Int64 = 0

    /// Log AEC telemetry at a regular interval (call from worker loop).
    /// Logs ERLE, delay estimate, mode, feed counts, and signal RMS every `intervalFrames` capture frames.
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

        if stats.framesProcessed - lastTelemetryFrameCount >= intervalFrames {
            lastTelemetryFrameCount = stats.framesProcessed
            shouldLog = true
        } else {
            shouldLog = false
        }

        guard shouldLog else { return }

        // Convert linear RMS to dBFS for logging
        let renderRmsDb = renderRmsLinear > 0 ? 20.0 * log10(renderRmsLinear) : -96.0
        let captureRmsDb = captureRmsLinear > 0 ? 20.0 * log10(captureRmsLinear) : -96.0

        var msg = "AEC_TELEMETRY: ERLE=\(String(format: "%.1f", stats.erleDb))dB"
        msg += ", delay=\(stats.delayMs)ms"
        msg += ", mode=\(stats.currentMode)"
        msg += ", processed=\(stats.framesProcessed)"
        msg += ", skipped=\(stats.framesSkipped)"
        msg += ", frozen=\(stats.adaptationFrozen)"
        msg += ", renderRms=\(String(format: "%.1f", renderRmsDb))dBFS"
        msg += ", captureRms=\(String(format: "%.1f", captureRmsDb))dBFS"

        if let ws = workerStats {
            msg += ", renderLead=\(ws.renderLeadFrames)frames"
            msg += ", avgLoopMs=\(String(format: "%.2f", ws.workerLoopTimeMs))"
        }

        Task {
            await DiagnosticLogger.shared.log(.aec, msg)
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
            && renderRmsLinear > 0.001  // render has actual signal (not silence)
        {
            let nonConvergingMsg = "AEC_NONCONVERGING: ERLE=\(String(format: "%.1f", stats.erleDb))dB"
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

        Task {
            if initSucceeded {
                await DiagnosticLogger.shared.log(.aec, "AEC_INIT: WebRTC AEC3")
            } else if let msg = initErrorMsg {
                await DiagnosticLogger.shared.log(.aec, "AEC_INIT_FAILED: \(msg)")
            }
        }
    }
    
    /// Update gating based on stability
    private static func updateGatingLocked(state: inout State, isStable: Bool) -> (changed: Bool, frozen: Bool) {
        let wasAdaptationFrozen = state.isAdaptationFrozen

        if !isStable {
            if !state.isAdaptationFrozen {
                state.isAdaptationFrozen = true
                state.stats.adaptationFrozen = true
            }
        } else if state.isAdaptationFrozen {
            // Unfreeze when stable returns (any mode).
            // Reset the bridge to clear stale internal delay estimates accumulated
            // while the adaptive filter was starved with silence.
            state.bridge?.reset()
            state.isAdaptationFrozen = false
            state.stats.adaptationFrozen = false
        }

        return (wasAdaptationFrozen != state.isAdaptationFrozen, state.isAdaptationFrozen)
    }
}
