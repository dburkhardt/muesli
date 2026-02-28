//
//  AudioWorker.swift
//  Muesli
//
//  High-priority audio worker thread for non-RT processing.
//  Handles: render feed cadence, capture AEC processing, and aligned render output.
//  IOProc and AVAudioEngine callbacks only push bytes to rings.
//

import Foundation
import os.lock
import os.log

// MARK: - Audio Worker Callbacks

/// Pops one 10ms mono frame from a ring into the destination buffer.
/// Returns the source metadata for that frame on success.
typealias PopAECFrameCallback = @Sendable (
    _ destination: UnsafeMutablePointer<Float>
) -> (hostTime: UInt64, startSampleIndex: Int64)?

/// Callback for processed microphone frames (AEC output).
typealias ProcessedMicFrameCallback = @Sendable (AudioFrame) -> Void

// MARK: - Audio Worker Statistics

/// Statistics from the audio worker.
struct AudioWorkerStats {
    var captureFramesProcessed: Int64 = 0
    var renderFramesFed: Int64 = 0
    var framesMissed: Int64 = 0
    var avgProcessingTimeMs: Double = 0
    var maxProcessingTimeMs: Double = 0
    var workerLoopTimeMs: Double = 0
    var renderLeadFrames: Int64 = 0
    var isRunning: Bool = false
}

enum AudioWorkerStartupGateState: String {
    case inactive
    case waitingRenderReady
    case waitingDelayReady
    case guardedTimeout
    case fullAdaptation
}

// MARK: - Audio Worker

/// High-priority audio worker for non-RT processing.
final class AudioWorker {
    private struct PassThroughWindow {
        var frameCount: Int = 0
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXX: Double = 0
        var sumYY: Double = 0
        var sumXY: Double = 0
        var sumInSq: Double = 0
        var sumOutSq: Double = 0
    }

    private struct DelayWindow {
        var frameCount: Int = 0
        var coarseSamples: [Int] = []
        var seededSamples: [Int] = []
        var divergenceCount: Int = 0
    }

    private struct DelayHintControlDecision {
        let delayMs: Int
        let source: AECStreamDelayHintSource
        let clamped: Bool
        let heldInUnstableWindow: Bool
    }

    private struct StartupGateConfig {
        let renderReadyFrames: Int
        let delayReadyFrames: Int
        let timeoutMs: Int
        let renderThresholdLinear: Float
    }
    // MARK: - Configuration

    /// Worker loop interval (5ms)
    static let loopIntervalMs: UInt64 = 5

    /// Processing frame size (10ms at 48kHz)
    static let frameSizeSamples = 480

    /// Processing sample rate for AEC/transcription feed
    static let sampleRate = 48000

    /// Maximum allowed render lead over capture feed.
    /// 30 frames = 300ms — AEC3 needs 150-300ms lead for convergence.
    static let maxRenderLeadFrames = 30

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.muesli.app", category: "AudioWorker")

    /// Synchronizer for aligned render output.
    private let synchronizer: AudioSynchronizer

    /// AEC processor.
    private let aecProcessor: AECProcessor

    /// Ring pop callback for render frames.
    private let popRenderAECFrame: PopAECFrameCallback

    /// Ring pop callback for capture frames.
    private let popCaptureAECFrame: PopAECFrameCallback

    /// Closure to query whether AEC is enabled (RT-safe: reads OSAllocatedUnfairLock).
    private let isAECEnabled: @Sendable () -> Bool
    /// Closure returning current coalesced route epoch ID.
    private let routeEpochProvider: @Sendable () -> Int
    /// Closure returning whether BT-output + external-mic profile is active.
    private let isBtExternalMicProfileActive: @Sendable () -> Bool

    /// Callback for processed microphone frames.
    private var processedMicCallback: ProcessedMicFrameCallback?

    /// Worker thread.
    private var workerThread: Thread?

    /// Running flag.
    private var isRunning: Bool = false

    /// Statistics.
    private var stats = AudioWorkerStats()

    /// Lock for thread safety (OSAllocatedUnfairLock for consistency with rest of pipeline).
    private let lock = OSAllocatedUnfairLock()

    /// Feed counters for render lead management.
    private var renderFedCount: Int64 = 0
    private var captureFedCount: Int64 = 0

    /// Accumulated RMS sums for the current telemetry interval (reset after each telemetry log).
    private var renderRmsAccumulator: Double = 0
    private var captureRmsAccumulator: Double = 0
    private var rmsFrameCount: Int = 0

    /// Render-silence detection for AEC freeze/reset.
    /// Counts consecutive render frames with RMS < silenceThreshold.
    private var consecutiveSilentRenderFrames: Int64 = 0
    /// Number of capture frames processed while render was silent.
    private var captureFramesDuringRenderSilence: Int64 = 0
    /// Whether AEC is currently frozen due to prolonged render silence.
    private var renderSilenceFrozen: Bool = false
    /// Render silence threshold (linear RMS).
    private static let renderSilenceThreshold: Float = 0.001
    /// Frames of silence before freezing AEC (30 seconds at 10ms/frame = 3000 frames).
    private static let renderSilenceFreezeFrames: Int64 = 3000
    /// Milestone for extended silence logging at 60 seconds.
    private static let renderSilenceExtendedFrames: Int64 = 6000
    /// Whether the 30s freeze threshold log was already emitted.
    private var loggedSilenceFreeze: Bool = false
    /// Whether the 60s extended silence log was already emitted.
    private var loggedSilenceExtended: Bool = false

    #if DEBUG
    static let testRenderSilenceFreezeFrames = renderSilenceFreezeFrames
    static let testRenderSilenceExtendedFrames = renderSilenceExtendedFrames
    #endif

    /// Circular buffer for processing time history (O(1) insert, no heap allocs after init).
    private let processingTimeHistorySize = 100
    private var processingTimesRing: [Double]
    private var processingTimesWriteIndex: Int = 0
    private var processingTimesCount: Int = 0

    /// Pre-allocated processing buffers.
    private var renderFrameBuffer = [Float](repeating: 0, count: 480)
    private var captureFrameBuffer = [Float](repeating: 0, count: 480)

    /// Debug-only diagnostics gate for heavier observability.
    private let diagnosticsEnabled: Bool
    private let diagnosticsVerboseEnabled: Bool
    private let delayHintControlEnabled: Bool
    private let btDelayHintBiasMs: Int
    private let btStartupGateEnabled: Bool
    private let startupGateConfig: StartupGateConfig
    private var startupGateState: AudioWorkerStartupGateState = .inactive
    private var startupGateReleaseReason: String = "disabled"
    private var startupGateRenderReadyStreak: Int = 0
    private var startupGateDelayReadyStreak: Int = 0
    private var startupGateStartTime: TimeInterval = 0
    private var startupGateRouteEpoch: Int = 0
    private var passThroughWindow = PassThroughWindow()
    private var passThroughSuspiciousSeconds: Int = 0
    private var passThroughLowAttenuationSeconds: Int = 0
    private var btDelayBiasDisabledForRouteRecovery: Bool = false
    private var btRecoveryAttemptCount: Int = 0
    private var delayWindow = DelayWindow()
    private var latestRenderRmsLinear: Float = 0
    private var phase15RenderRmsAccumulator: Double = 0
    private var phase15CaptureRmsAccumulator: Double = 0
    private var phase15RmsFrameCount: Int64 = 0
    private var phase15PreviousCoarseDelayMs: Int?
    private var phase15PreviousTimestampSeconds: TimeInterval?
    private var phase15ConsecutiveCollapseSeconds: Int = 0
    private var phase15DelayHintClampCount: Int64 = 0
    private var phase15DelayHintHoldCount: Int64 = 0
    private var lastAppliedDelayHintMs: Int = -1
    private var lastAppliedDelayHintSource: AECStreamDelayHintSource = .unknown

    private static let phase15ErleCollapseThresholdDb: Double = 3.0
    private static let phase15CollapseAlertSeconds = 15
    private static let delayHintSlewLimitMsPerFrame = 8
    private static let btRecoveryLowAttenuationSecondsThreshold = 20
    private static let btRecoveryMaxAttemptsPerRoute = 1
    private static let btPassThroughMinRenderRmsLinear = 0.003
    private static let btPassThroughMinCaptureRmsLinear = 0.003

    // MARK: - Initialization

    init(
        synchronizer: AudioSynchronizer,
        aecProcessor: AECProcessor,
        popRenderAECFrame: @escaping PopAECFrameCallback,
        popCaptureAECFrame: @escaping PopAECFrameCallback,
        isAECEnabled: @escaping @Sendable () -> Bool = { true },
        routeEpochProvider: @escaping @Sendable () -> Int = { 0 },
        isBtExternalMicProfileActive: @escaping @Sendable () -> Bool = { false }
    ) {
        self.synchronizer = synchronizer
        self.aecProcessor = aecProcessor
        self.popRenderAECFrame = popRenderAECFrame
        self.popCaptureAECFrame = popCaptureAECFrame
        self.isAECEnabled = isAECEnabled
        self.routeEpochProvider = routeEpochProvider
        self.isBtExternalMicProfileActive = isBtExternalMicProfileActive
        self.processingTimesRing = [Double](repeating: 0, count: processingTimeHistorySize)
        let defaults = UserDefaults.standard
        #if DEBUG
        self.diagnosticsEnabled = true
        self.diagnosticsVerboseEnabled = (defaults.object(forKey: "AECDiagnosticsVerbose") as? Bool) ?? true
        #else
        self.diagnosticsEnabled = defaults.bool(forKey: "aecDiagnosticsEnabled")
        self.diagnosticsVerboseEnabled = defaults.bool(forKey: "AECDiagnosticsVerbose")
        #endif
        self.delayHintControlEnabled = (defaults.object(forKey: "aecDelayHintControlEnabled") as? Bool) ?? true
        self.btDelayHintBiasMs = max(0, (defaults.object(forKey: "aecBtHardeningDelayHintBiasMs") as? Int) ?? 80)
        self.btStartupGateEnabled = (defaults.object(forKey: "aecBtHardeningStartupGateEnabled") as? Bool) ?? true
        let startupRenderReadyFrames = (defaults.object(forKey: "aecBtHardeningStartupRenderReadyFrames") as? Int) ?? 5
        let startupDelayReadyFrames = (defaults.object(forKey: "aecBtHardeningStartupDelayReadyFrames") as? Int) ?? 10
        let startupTimeoutMs = (defaults.object(forKey: "aecBtHardeningStartupTimeoutMs") as? Int) ?? 15_000
        let startupRenderThresholdDbfs = (defaults.object(forKey: "aecBtHardeningRenderThresholdDbfs") as? Double) ?? -45.0
        let startupRenderThresholdLinear = max(Float(pow(10.0, startupRenderThresholdDbfs / 20.0)), 0.00001)
        self.startupGateConfig = StartupGateConfig(
            renderReadyFrames: max(1, startupRenderReadyFrames),
            delayReadyFrames: max(1, startupDelayReadyFrames),
            timeoutMs: max(1000, startupTimeoutMs),
            renderThresholdLinear: startupRenderThresholdLinear
        )

        assert(renderFrameBuffer.count == Self.frameSizeSamples)
        assert(captureFrameBuffer.count == Self.frameSizeSamples)

        logger.info("AudioWorker initialized")
    }

    /// Select the stream delay hint to pass into AEC3.
    /// - Parameters:
    ///   - coarseDelayMs: Latest coarse delay estimate (ms), preferred when >0.
    ///   - seededDelayMs: Seeded fallback delay estimate (ms), used when coarse is unavailable.
    /// - Returns: Delay hint in ms and the source used.
    static func selectStreamDelayHint(
        coarseDelayMs: Int,
        seededDelayMs: Int
    ) -> (delayMs: Int, source: AECStreamDelayHintSource) {
        if coarseDelayMs > 0 {
            return (coarseDelayMs, .coarse)
        } else if seededDelayMs >= 0 {
            return (max(seededDelayMs, 0), .seeded)
        } else {
            return (0, .none)
        }
    }

    static func applyBtProfileDelayBias(
        selectedHint: (delayMs: Int, source: AECStreamDelayHintSource),
        btExternalMicProfileActive: Bool,
        biasMs: Int
    ) -> (delayMs: Int, source: AECStreamDelayHintSource) {
        guard btExternalMicProfileActive, biasMs > 0 else {
            return selectedHint
        }
        guard selectedHint.source != .none else {
            return selectedHint
        }
        let adjusted = min(max(selectedHint.delayMs + biasMs, 0), 500)
        return (adjusted, selectedHint.source)
    }

    static func shouldTriggerBtRecovery(
        btExternalMicProfileActive: Bool,
        startupGateState: AudioWorkerStartupGateState,
        lowAttenuationSeconds: Int,
        attemptCount: Int,
        minLowAttenuationSeconds: Int = btRecoveryLowAttenuationSecondsThreshold,
        maxAttemptsPerRoute: Int = btRecoveryMaxAttemptsPerRoute
    ) -> Bool {
        guard btExternalMicProfileActive else { return false }
        guard startupGateState == .fullAdaptation else { return false }
        guard attemptCount < maxAttemptsPerRoute else { return false }
        return lowAttenuationSeconds >= minLowAttenuationSeconds
    }

    static func applyDelayHintControl(
        requestedDelayMs: Int,
        source: AECStreamDelayHintSource,
        lastAppliedDelayMs: Int,
        lastAppliedSource: AECStreamDelayHintSource = .unknown,
        isStable: Bool,
        enabled: Bool,
        slewLimitMsPerFrame: Int = delayHintSlewLimitMsPerFrame
    ) -> (delayMs: Int, source: AECStreamDelayHintSource, clamped: Bool, heldInUnstableWindow: Bool) {
        guard enabled else {
            return (requestedDelayMs, source, false, false)
        }

        if !isStable, lastAppliedDelayMs >= 0 {
            return (lastAppliedDelayMs, lastAppliedSource, false, true)
        }

        guard lastAppliedDelayMs >= 0 else {
            return (requestedDelayMs, source, false, false)
        }

        let delta = requestedDelayMs - lastAppliedDelayMs
        if abs(delta) > slewLimitMsPerFrame {
            let adjusted = lastAppliedDelayMs + (delta > 0 ? slewLimitMsPerFrame : -slewLimitMsPerFrame)
            return (adjusted, source, true, false)
        }
        return (requestedDelayMs, source, false, false)
    }

    static func transitionStartupGateState(
        currentState: AudioWorkerStartupGateState,
        renderReadyStreak: Int,
        delayReadyStreak: Int,
        elapsedMs: Int,
        renderReadyFrames: Int,
        delayReadyFrames: Int,
        timeoutMs: Int
    ) -> (nextState: AudioWorkerStartupGateState, releaseReason: String?) {
        switch currentState {
        case .inactive, .fullAdaptation:
            return (currentState, nil)
        case .waitingRenderReady:
            if renderReadyStreak >= renderReadyFrames {
                return (.waitingDelayReady, nil)
            }
            if elapsedMs >= timeoutMs {
                return (.guardedTimeout, "timeout_guarded")
            }
            return (.waitingRenderReady, nil)
        case .waitingDelayReady:
            if renderReadyStreak >= renderReadyFrames && delayReadyStreak >= delayReadyFrames {
                return (.fullAdaptation, "render_and_delay_ready")
            }
            if elapsedMs >= timeoutMs {
                return (.guardedTimeout, "timeout_guarded")
            }
            return (.waitingDelayReady, nil)
        case .guardedTimeout:
            if renderReadyStreak >= renderReadyFrames && delayReadyStreak >= delayReadyFrames {
                return (.fullAdaptation, "delayed_readiness_after_timeout")
            }
            return (.guardedTimeout, nil)
        }
    }

    static func phase15RenderRmsForFrame(
        latestRenderRmsLinear: Float,
        renderUpdatedThisIteration: Bool
    ) -> Float {
        renderUpdatedThisIteration ? latestRenderRmsLinear : 0
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Start the audio worker.
    func start(
        micCallback: @escaping ProcessedMicFrameCallback
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        processedMicCallback = micCallback
        isRunning = true
        stats.isRunning = true

        workerThread = Thread { [weak self] in
            self?.workerLoop()
        }
        workerThread?.name = "MuesliAudioWorker"
        workerThread?.qualityOfService = .userInteractive
        workerThread?.start()

        logger.info("AudioWorker started")

        let logDelayHintControlEnabled = delayHintControlEnabled
        let logDiagnosticsVerboseEnabled = diagnosticsVerboseEnabled
        resetStartupGateForCurrentRoute(reason: "worker_start")
        let logStartupState = startupGateState.rawValue
        let logStartupReason = startupGateReleaseReason
        let logStartupEnabled = btStartupGateEnabled
        let logBtProfileActive = isBtExternalMicProfileActive()
        let logBtDelayHintBiasMs = btDelayHintBiasMs
        let logBtDelayBiasDisabledForRouteRecovery = btDelayBiasDisabledForRouteRecovery
        let logBtRecoveryAttemptCount = btRecoveryAttemptCount
        let logRouteEpochID = startupGateRouteEpoch
        let delayHintConfigMessage =
            "AEC_DELAY_HINT_CONTROL_CONFIG: enabled=\(logDelayHintControlEnabled), slewLimitMsPerFrame=\(Self.delayHintSlewLimitMsPerFrame), btDelayHintBiasMs=\(logBtDelayHintBiasMs), diagnosticsVerbose=\(logDiagnosticsVerboseEnabled)"
        let flagsSnapshotMessage =
            "AEC_FLAGS_SNAPSHOT: aecTelemetryVersion=2, routeEpochId=\(logRouteEpochID), btExternalMicProfile=\(logBtProfileActive), delayHintControlEnabled=\(logDelayHintControlEnabled), btDelayHintBiasMs=\(logBtDelayHintBiasMs), btDelayBiasDisabledForRouteRecovery=\(logBtDelayBiasDisabledForRouteRecovery), btRecoveryAttemptCount=\(logBtRecoveryAttemptCount), btStartupGateEnabled=\(logStartupEnabled), startupRenderReadyFrames=\(startupGateConfig.renderReadyFrames), startupDelayReadyFrames=\(startupGateConfig.delayReadyFrames), startupTimeoutMs=\(startupGateConfig.timeoutMs), startupRenderThresholdLinear=\(String(format: "%.5f", startupGateConfig.renderThresholdLinear)), startupGateState=\(logStartupState), startupGateReleaseReason=\(logStartupReason)"
        Task.detached(priority: nil) {
            await DiagnosticLogger.shared.log(.aec, "AUDIO_WORKER_START")
            await DiagnosticLogger.shared.log(.aec, flagsSnapshotMessage)
            await DiagnosticLogger.shared.log(.aec, delayHintConfigMessage)
        }
    }

    /// Stop the audio worker.
    func stop() {
        lock.lock()
        isRunning = false
        stats.isRunning = false
        lock.unlock()

        while workerThread?.isExecuting == true {
            Thread.sleep(forTimeInterval: 0.01)
        }

        workerThread = nil

        let logAECEnabled = isAECEnabled()

        lock.lock()
        processedMicCallback = nil
        let logCaptureFrames = stats.captureFramesProcessed
        let logRenderFrames = stats.renderFramesFed
        let logMissed = stats.framesMissed
        lock.unlock()

        logger.info("AudioWorker stopped")

        let stopMessage =
            "AUDIO_WORKER_STOP: captureFrames=\(logCaptureFrames), renderFrames=\(logRenderFrames), missed=\(logMissed), aecEnabled=\(logAECEnabled)"
        Task.detached(priority: nil) {
            await DiagnosticLogger.shared.log(.aec, stopMessage)
        }
    }

    /// Get current statistics.
    func getStats() -> AudioWorkerStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Reset worker state.
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        synchronizer.reset()
        aecProcessor.reset()
        stats = AudioWorkerStats()
        stats.isRunning = isRunning
        renderFedCount = 0
        captureFedCount = 0
        renderRmsAccumulator = 0
        captureRmsAccumulator = 0
        rmsFrameCount = 0
        consecutiveSilentRenderFrames = 0
        captureFramesDuringRenderSilence = 0
        renderSilenceFrozen = false
        loggedSilenceFreeze = false
        loggedSilenceExtended = false
        processingTimesWriteIndex = 0
        processingTimesCount = 0
        passThroughWindow = PassThroughWindow()
        passThroughSuspiciousSeconds = 0
        passThroughLowAttenuationSeconds = 0
        btDelayBiasDisabledForRouteRecovery = false
        btRecoveryAttemptCount = 0
        delayWindow = DelayWindow()
        latestRenderRmsLinear = 0
        startupGateState = .inactive
        startupGateReleaseReason = "reset"
        startupGateRenderReadyStreak = 0
        startupGateDelayReadyStreak = 0
        startupGateStartTime = 0
        startupGateRouteEpoch = routeEpochProvider()
        phase15RenderRmsAccumulator = 0
        phase15CaptureRmsAccumulator = 0
        phase15RmsFrameCount = 0
        phase15PreviousCoarseDelayMs = nil
        phase15PreviousTimestampSeconds = nil
        phase15ConsecutiveCollapseSeconds = 0
        phase15DelayHintClampCount = 0
        phase15DelayHintHoldCount = 0
        lastAppliedDelayHintMs = -1
        lastAppliedDelayHintSource = .unknown

        logger.info("AudioWorker reset")
    }

    // MARK: - Private Implementation

    /// Main worker loop.
    private func workerLoop() {
        let loopIntervalNs = Self.loopIntervalMs * 1_000_000

        while isWorkerRunning() {
            let loopStart = DispatchTime.now()

            processAvailableFrames()

            let loopEnd = DispatchTime.now()
            let loopTimeNs = loopEnd.uptimeNanoseconds - loopStart.uptimeNanoseconds

            lock.lock()
            stats.workerLoopTimeMs = Double(loopTimeNs) / 1_000_000
            lock.unlock()

            let sleepTimeNs = loopIntervalNs - min(loopTimeNs, loopIntervalNs)
            if sleepTimeNs > 0 {
                Thread.sleep(forTimeInterval: Double(sleepTimeNs) / 1_000_000_000)
            }
        }
    }

    private func isWorkerRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    /// Process available frames in three stages:
    /// 1) render feed to AEC (bounded lead),
    /// 2) capture processing through AEC (or pass-through if disabled),
    /// 3) aligned render frame output from synchronizer.
    private func processAvailableFrames() {
        let maxFramesPerIteration = 10
        let aecEnabled = isAECEnabled()
        refreshStartupGateForRouteEpochChange()

        // 1) Feed render stream first, but keep lead bounded.
        //    Skip entirely if AEC is disabled — no point feeding render to a disabled processor.
        var renderFedThisIteration = 0
        let renderUpdatedThisIteration: Bool
        if aecEnabled {
            while renderFedThisIteration < maxFramesPerIteration {
                let currentLead = renderFedCount - captureFedCount
                if currentLead > Int64(Self.maxRenderLeadFrames) {
                    break
                }

                let metadata = renderFrameBuffer.withUnsafeMutableBufferPointer { ptr in
                    popRenderAECFrame(ptr.baseAddress!)
                }

                guard metadata != nil else {
                    break
                }

                let syncIsStableForRender = synchronizer.isStable
                let adaptationStableForRender = startupGateAllowsAdaptation(
                    syncIsStable: syncIsStableForRender,
                    delaySourceTag: nil
                )
                _ = aecProcessor.feedRenderFrame(renderFrameBuffer, isStable: adaptationStableForRender)
                renderFedCount += 1
                renderFedThisIteration += 1

                // Accumulate render RMS for telemetry
                let renderRms = computeRMS(renderFrameBuffer)
                updateStartupRenderReadyStreak(renderRms: renderRms)
                renderRmsAccumulator += Double(renderRms)
                rmsFrameCount += 1
                latestRenderRmsLinear = renderRms

                // Track render silence for AEC freeze/reset
                if renderRms < Self.renderSilenceThreshold {
                    consecutiveSilentRenderFrames += 1

                    // Freeze AEC at 30s of silence to prevent filter corruption.
                    if consecutiveSilentRenderFrames >= Self.renderSilenceFreezeFrames && !renderSilenceFrozen {
                        renderSilenceFrozen = true
                        aecProcessor.freezeAdaptation()
                        logger.warning("Render silent for 30s — freezing AEC adaptation")
                    }

                    // Log TAP_RENDER_SILENT at milestones
                    if consecutiveSilentRenderFrames >= Self.renderSilenceFreezeFrames && !loggedSilenceFreeze {
                        loggedSilenceFreeze = true
                        let silentMs = consecutiveSilentRenderFrames * 10
                        let captDuring = captureFramesDuringRenderSilence
                        Task {
                            await DiagnosticLogger.shared.log(.aec,
                                "TAP_RENDER_SILENT: silentMs=\(silentMs), captureActive=true, captureFramesDuringSilence=\(captDuring)")
                        }
                    }
                    if consecutiveSilentRenderFrames >= Self.renderSilenceExtendedFrames && !loggedSilenceExtended {
                        loggedSilenceExtended = true
                        let silentMs = consecutiveSilentRenderFrames * 10
                        let captDuring = captureFramesDuringRenderSilence
                        Task {
                            await DiagnosticLogger.shared.log(.aec,
                                "TAP_RENDER_SILENT: silentMs=\(silentMs), captureActive=true, captureFramesDuringSilence=\(captDuring)")
                        }
                    }
                } else if consecutiveSilentRenderFrames >= Self.renderSilenceFreezeFrames {
                    // Render resumed after prolonged silence — resume AEC adaptation.
                    let silentFrames = consecutiveSilentRenderFrames
                    let silentMs = silentFrames * 10
                    let captDuring = captureFramesDuringRenderSilence
                    aecProcessor.unfreezeAdaptation()
                    renderSilenceFrozen = false
                    consecutiveSilentRenderFrames = 0
                    captureFramesDuringRenderSilence = 0
                    loggedSilenceFreeze = false
                    loggedSilenceExtended = false
                    logger.info("Render resumed after \(silentMs)ms silence — AEC resumed (filter preserved)")
                    Task {
                        await DiagnosticLogger.shared.log(.aec,
                            "AEC_RENDER_RESUME: silentFrames=\(silentFrames), silentMs=\(silentMs), captureFramesDuringSilence=\(captDuring), preserved=true")
                        await DiagnosticLogger.shared.log(.aec,
                            "AEC_RENDER_RESUME_PRESERVED: silentFrames=\(silentFrames), silentMs=\(silentMs), captureFramesDuringSilence=\(captDuring)")
                    }
                } else {
                    // Short silence ended, just reset counter
                    consecutiveSilentRenderFrames = 0
                    captureFramesDuringRenderSilence = 0
                }
            }
            renderUpdatedThisIteration = renderFedThisIteration > 0
        } else {
            renderUpdatedThisIteration = false
        }

        // 2) Process capture frames and emit processed microphone audio.
        //    When AEC is disabled, pass capture frames through unmodified.
        var captureProcessedThisIteration = 0
        while captureProcessedThisIteration < maxFramesPerIteration {
            let metadata = captureFrameBuffer.withUnsafeMutableBufferPointer { ptr in
                popCaptureAECFrame(ptr.baseAddress!)
            }

            guard let metadata else {
                break
            }

            // Accumulate capture RMS for telemetry
            let captureRms = computeRMS(captureFrameBuffer)
            captureRmsAccumulator += Double(captureRms)

            // Track capture frames during render silence
            if consecutiveSilentRenderFrames > 0 {
                captureFramesDuringRenderSilence += 1
            }

            let processStart = DispatchTime.now()
            let processedCapture: [Float]
            if aecEnabled {
                // Pass the synchronizer's coarse delay as the stream delay hint.
                // The synchronizer's coarse delay measures the pipeline buffering lead
                // (typically ~100-200ms). WebRTC AEC3 needs this hint because its
                // internal filter is only 150ms long. If the physical acoustic delay
                // plus the pipeline lead exceeds 150ms, it cannot cancel the echo
                // unless we shift the render buffer by passing this hint.
                // We pass it on every frame to keep the WebRTC internal state machine updated.
                let syncCoarseDelayMs = synchronizer.coarseDelayMs
                let syncSeededDelayMs = synchronizer.seededDelayMs
                let syncIsStable = synchronizer.isStable
                let delayDecomposition = synchronizer.delayDecompositionSnapshot()
                let adaptationStable = startupGateAllowsAdaptation(
                    syncIsStable: syncIsStable,
                    delaySourceTag: delayDecomposition.sourceTag
                )
                let delayHint = Self.selectStreamDelayHint(
                    coarseDelayMs: syncCoarseDelayMs,
                    seededDelayMs: syncSeededDelayMs
                )
                let activeBtDelayHintBiasMs = btDelayBiasDisabledForRouteRecovery ? 0 : btDelayHintBiasMs
                let btDelayHint = Self.applyBtProfileDelayBias(
                    selectedHint: delayHint,
                    btExternalMicProfileActive: isBtExternalMicProfileActive(),
                    biasMs: activeBtDelayHintBiasMs
                )
                let controlledDelayHint = applyDelayHintControl(
                    selectedHint: btDelayHint,
                    isStable: adaptationStable
                )
                if controlledDelayHint.clamped {
                    phase15DelayHintClampCount += 1
                }
                if controlledDelayHint.heldInUnstableWindow {
                    phase15DelayHintHoldCount += 1
                }
                if diagnosticsEnabled {
                    updateDelayWindow(
                        coarseDelayMs: syncCoarseDelayMs,
                        seededDelayMs: syncSeededDelayMs
                    )
                }
                let delaySet = aecProcessor.setStreamDelayMs(
                    controlledDelayHint.delayMs,
                    source: controlledDelayHint.source
                )
                if !delaySet {
                    lock.lock()
                    stats.framesMissed += 1
                    lock.unlock()
                }

                processedCapture = aecProcessor.processCaptureFrame(
                    captureFrameBuffer,
                    isStable: adaptationStable
                )

                // Worker-owned Phase 1.5 correlation accumulation (1Hz snapshots).
                // Zero-fill render RMS when no render frame was consumed this worker iteration.
                // This avoids stale carry-forward from prior iterations.
                let renderRmsForPhase = Self.phase15RenderRmsForFrame(
                    latestRenderRmsLinear: latestRenderRmsLinear,
                    renderUpdatedThisIteration: renderUpdatedThisIteration
                )
                phase15RenderRmsAccumulator += Double(renderRmsForPhase)
                phase15CaptureRmsAccumulator += Double(captureRms)
                phase15RmsFrameCount += 1
                if let phaseSummary = aecProcessor.recordPhase15Sample(syncDelayMs: syncCoarseDelayMs) {
                    emitPhase15Summary(
                        summary: phaseSummary,
                        delayDecomposition: delayDecomposition
                    )
                }
            } else {
                // AEC disabled — pass capture through unmodified
                processedCapture = captureFrameBuffer
            }
            let processEnd = DispatchTime.now()
            let processingTimeMs = Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000
            if diagnosticsEnabled && aecEnabled {
                updatePassThroughWindow(input: captureFrameBuffer, output: processedCapture)
            }

            captureFedCount += 1
            captureProcessedThisIteration += 1

            lock.lock()
            let micCallback = processedMicCallback
            stats.captureFramesProcessed += 1
            stats.renderFramesFed = renderFedCount
            stats.renderLeadFrames = renderFedCount - captureFedCount
            lock.unlock()

            micCallback?(AudioFrame(
                samples: processedCapture,
                sampleRate: Self.sampleRate,
                hostTime: metadata.hostTime,
                startSampleIndex: metadata.startSampleIndex
            ))

            updateProcessingTimeStats(processingTimeMs)
        }

        // 3) Drain aligned frames to keep the synchronizer state machine healthy.
        // Aligned frames are consumed but discarded — render transcription is now
        // delivered independently via TapAudioCaptureService.drainRenderTranscriptionRing().
        // This loop must run so getAlignedFrame() advances internal pointers,
        // maintaining correct isStable transitions for AEC gating.
        var alignedFramesDrained = 0
        while alignedFramesDrained < maxFramesPerIteration {
            guard synchronizer.getAlignedFrame() != nil else {
                break
            }
            alignedFramesDrained += 1
        }

        lock.lock()
        stats.renderFramesFed = renderFedCount
        stats.renderLeadFrames = renderFedCount - captureFedCount
        let currentStats = stats
        lock.unlock()

        // Compute rolling RMS averages for this telemetry window
        let avgRenderRms = rmsFrameCount > 0 ? Float(renderRmsAccumulator / Double(rmsFrameCount)) : 0
        let avgCaptureRms = rmsFrameCount > 0 ? Float(captureRmsAccumulator / Double(rmsFrameCount)) : 0

        // Periodic AEC telemetry (~every 10 seconds); reset RMS accumulators after logging
        let prevFrameCount = aecProcessor.lastTelemetryFrameCount
        aecProcessor.logPeriodicTelemetry(
            workerStats: currentStats,
            renderRmsLinear: avgRenderRms,
            captureRmsLinear: avgCaptureRms
        )
        // Reset accumulators when a telemetry log was emitted
        if aecProcessor.lastTelemetryFrameCount != prevFrameCount {
            renderRmsAccumulator = 0
            captureRmsAccumulator = 0
            rmsFrameCount = 0
        }

        if diagnosticsEnabled {
            emitDiagnosticSummariesIfNeeded()
        }
    }

    private func refreshStartupGateForRouteEpochChange() {
        let epoch = routeEpochProvider()
        if epoch != startupGateRouteEpoch {
            resetStartupGateForCurrentRoute(reason: "route_epoch_changed")
        }
    }

    private func resetStartupGateForCurrentRoute(reason: String) {
        if reason == "route_epoch_changed" || reason == "worker_start" {
            btDelayBiasDisabledForRouteRecovery = false
            btRecoveryAttemptCount = 0
        }
        startupGateRouteEpoch = routeEpochProvider()
        startupGateRenderReadyStreak = 0
        startupGateDelayReadyStreak = 0
        startupGateStartTime = Date().timeIntervalSince1970

        let gateActive = btStartupGateEnabled && isBtExternalMicProfileActive()
        if gateActive {
            startupGateState = .waitingRenderReady
            startupGateReleaseReason = "pending"
        } else {
            startupGateState = .inactive
            startupGateReleaseReason = "disabled_or_non_bt_profile"
        }

        let routeEpoch = startupGateRouteEpoch
        let state = startupGateState.rawValue
        let releaseReason = startupGateReleaseReason
        Task.detached(priority: nil) {
            await DiagnosticLogger.shared.log(.aec,
                "AEC_STARTUP_GATE_RESET: routeEpochId=\(routeEpoch), reason=\(reason), state=\(state), releaseReason=\(releaseReason)")
        }
    }

    private func updateStartupRenderReadyStreak(renderRms: Float) {
        guard startupGateState != .inactive && startupGateState != .fullAdaptation else { return }
        if renderRms >= startupGateConfig.renderThresholdLinear {
            startupGateRenderReadyStreak += 1
        } else {
            startupGateRenderReadyStreak = 0
        }
    }

    private func startupGateAllowsAdaptation(
        syncIsStable: Bool,
        delaySourceTag: DelayDecompositionSourceTag?
    ) -> Bool {
        if startupGateState == .inactive {
            return syncIsStable
        }

        if let delaySourceTag {
            if delaySourceTag != .unavailable {
                startupGateDelayReadyStreak += 1
            } else {
                startupGateDelayReadyStreak = 0
            }
        }

        let elapsedMs = max(0, Int((Date().timeIntervalSince1970 - startupGateStartTime) * 1000.0))
        let transition = Self.transitionStartupGateState(
            currentState: startupGateState,
            renderReadyStreak: startupGateRenderReadyStreak,
            delayReadyStreak: startupGateDelayReadyStreak,
            elapsedMs: elapsedMs,
            renderReadyFrames: startupGateConfig.renderReadyFrames,
            delayReadyFrames: startupGateConfig.delayReadyFrames,
            timeoutMs: startupGateConfig.timeoutMs
        )

        if transition.nextState != startupGateState {
            let previousState = startupGateState
            startupGateState = transition.nextState
            if let releaseReason = transition.releaseReason {
                startupGateReleaseReason = releaseReason
            }
            let routeEpoch = startupGateRouteEpoch
            let prev = previousState.rawValue
            let next = startupGateState.rawValue
            let releaseReason = startupGateReleaseReason
            let renderStreak = startupGateRenderReadyStreak
            let delayStreak = startupGateDelayReadyStreak
            Task.detached(priority: nil) {
                await DiagnosticLogger.shared.log(.aec,
                    "AEC_STARTUP_GATE_TRANSITION: routeEpochId=\(routeEpoch), from=\(prev), to=\(next), releaseReason=\(releaseReason), elapsedMs=\(elapsedMs), renderReadyStreak=\(renderStreak), delayReadyStreak=\(delayStreak)")
            }
        }

        if startupGateState == .fullAdaptation {
            return syncIsStable
        }
        return false
    }

    private func applyDelayHintControl(
        selectedHint: (delayMs: Int, source: AECStreamDelayHintSource),
        isStable: Bool
    ) -> DelayHintControlDecision {
        let decision = Self.applyDelayHintControl(
            requestedDelayMs: selectedHint.delayMs,
            source: selectedHint.source,
            lastAppliedDelayMs: lastAppliedDelayHintMs,
            lastAppliedSource: lastAppliedDelayHintSource,
            isStable: isStable,
            enabled: delayHintControlEnabled,
            slewLimitMsPerFrame: Self.delayHintSlewLimitMsPerFrame
        )
        lastAppliedDelayHintMs = decision.delayMs
        lastAppliedDelayHintSource = decision.source
        return DelayHintControlDecision(
            delayMs: decision.delayMs,
            source: decision.source,
            clamped: decision.clamped,
            heldInUnstableWindow: decision.heldInUnstableWindow
        )
    }

    private func emitPhase15Summary(
        summary: AECPhase15Summary,
        delayDecomposition: DelayDecompositionSnapshot
    ) {
        let rmsFrames = max(phase15RmsFrameCount, 1)
        let renderRmsLinear = Float(phase15RenderRmsAccumulator / Double(rmsFrames))
        let captureRmsLinear = Float(phase15CaptureRmsAccumulator / Double(rmsFrames))
        phase15RenderRmsAccumulator = 0
        phase15CaptureRmsAccumulator = 0
        phase15RmsFrameCount = 0

        let renderDb = renderRmsLinear > 0 ? 20.0 * log10(Double(renderRmsLinear)) : -96.0
        let captureDb = captureRmsLinear > 0 ? 20.0 * log10(Double(captureRmsLinear)) : -96.0
        let regime = classifyRmsRegime(renderDb: renderDb, captureDb: captureDb)
        let collapseThisSecond = summary.erleBelow3Pct >= 80.0 && regime == "far_end_dominant"
        phase15ConsecutiveCollapseSeconds = collapseThisSecond ? (phase15ConsecutiveCollapseSeconds + 1) : 0
        let collapseAlert = phase15ConsecutiveCollapseSeconds >= Self.phase15CollapseAlertSeconds

        let now = Date().timeIntervalSince1970
        var coarseSlopeMsPerSec = 0.0
        if let previousCoarse = phase15PreviousCoarseDelayMs,
           let previousTime = phase15PreviousTimestampSeconds {
            let deltaSeconds = now - previousTime
            if deltaSeconds > 0 {
                coarseSlopeMsPerSec = Double(delayDecomposition.coarseDelayMs - previousCoarse) / deltaSeconds
            }
        }
        phase15PreviousCoarseDelayMs = delayDecomposition.coarseDelayMs
        phase15PreviousTimestampSeconds = now

        let summaryLine =
            "AEC_PHASE15: windowFrames=\(summary.windowFrames), totalFrames=\(summary.totalFrames), invalidDelaySamples=\(summary.invalidDelaySamples), erleBelow3Pct=\(String(format: "%.1f", summary.erleBelow3Pct)), deltaOver100Pct=\(String(format: "%.1f", summary.deltaOver100Pct)), coincidencePct=\(String(format: "%.1f", summary.coincidencePct)), regime=\(regime), collapseSeconds=\(phase15ConsecutiveCollapseSeconds), collapseAlert=\(collapseAlert), coarseDelayMs=\(delayDecomposition.coarseDelayMs), seededDelayMs=\(delayDecomposition.seededDelayMs), sourceTag=\(delayDecomposition.sourceTag.rawValue), driftPpm=\(String(format: "%.1f", delayDecomposition.driftPPM)), driftAdjustMsPerSec=\(String(format: "%.3f", delayDecomposition.driftAdjustmentMsPerSec)), effectiveDelayMs=\(String(format: "%.3f", delayDecomposition.effectiveCoarseDelayMs)), coarseSlopeMsPerSec=\(String(format: "%.3f", coarseSlopeMsPerSec)), delayHintClampCount=\(phase15DelayHintClampCount), delayHintHoldCount=\(phase15DelayHintHoldCount), routeEpochId=\(startupGateRouteEpoch), startupGateState=\(startupGateState.rawValue), startupGateReleaseReason=\(startupGateReleaseReason)"

        Task.detached(priority: nil) {
            await DiagnosticLogger.shared.log(.aec, summaryLine)
        }

        if diagnosticsVerboseEnabled {
            let csvLine =
                "AEC_PHASE15_CSV: windowFrames=\(summary.windowFrames),totalFrames=\(summary.totalFrames),invalidDelaySamples=\(summary.invalidDelaySamples),erleBelow3Frames=\(summary.erleBelow3Frames),deltaOver100Frames=\(summary.deltaOver100Frames),coincidentFrames=\(summary.coincidentFrames),erleBelow3Pct=\(String(format: "%.3f", summary.erleBelow3Pct)),deltaOver100Pct=\(String(format: "%.3f", summary.deltaOver100Pct)),coincidencePct=\(String(format: "%.3f", summary.coincidencePct)),deltaBinLt20=\(summary.deltaBinLt20),deltaBin20To49=\(summary.deltaBin20To49),deltaBin50To99=\(summary.deltaBin50To99),deltaBin100To199=\(summary.deltaBin100To199),deltaBinGe200=\(summary.deltaBinGe200),regime=\(regime),collapseSeconds=\(phase15ConsecutiveCollapseSeconds),collapseAlert=\(collapseAlert),coarseDelayMs=\(delayDecomposition.coarseDelayMs),seededDelayMs=\(delayDecomposition.seededDelayMs),sourceTag=\(delayDecomposition.sourceTag.rawValue),driftPpm=\(String(format: "%.3f", delayDecomposition.driftPPM)),driftAdjustMsPerSec=\(String(format: "%.6f", delayDecomposition.driftAdjustmentMsPerSec)),effectiveDelayMs=\(String(format: "%.6f", delayDecomposition.effectiveCoarseDelayMs)),coarseSlopeMsPerSec=\(String(format: "%.6f", coarseSlopeMsPerSec)),delayHintClampCount=\(phase15DelayHintClampCount),delayHintHoldCount=\(phase15DelayHintHoldCount),routeEpochId=\(startupGateRouteEpoch),startupGateState=\(startupGateState.rawValue),startupGateReleaseReason=\(startupGateReleaseReason)"
            Task.detached(priority: nil) {
                await DiagnosticLogger.shared.log(.aec, csvLine)
            }
        }

        if collapseAlert {
            let collapseMessage =
                "AEC_ERLE_COLLAPSE: regime=\(regime), consecutiveSeconds=\(phase15ConsecutiveCollapseSeconds), erleBelow3Pct=\(String(format: "%.1f", summary.erleBelow3Pct)), deltaOver100Pct=\(String(format: "%.1f", summary.deltaOver100Pct))"
            Task.detached(priority: nil) {
                await DiagnosticLogger.shared.log(.aec, collapseMessage)
            }
        }
    }

    private func classifyRmsRegime(renderDb: Double, captureDb: Double) -> String {
        if renderDb < -60 && captureDb < -60 {
            return "silence"
        }
        let delta = renderDb - captureDb
        if delta >= 6.0 {
            return "far_end_dominant"
        }
        if delta <= -6.0 {
            return "near_end_dominant"
        }
        return "double_talk_or_balanced"
    }

    /// Compute RMS amplitude of a mono Float32 frame.
    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        return (sumSq / Float(samples.count)).squareRoot()
    }

    /// Update processing time statistics using circular buffer (O(1), no allocations).
    private func updateProcessingTimeStats(_ timeMs: Double) {
        lock.lock()
        defer { lock.unlock() }

        processingTimesRing[processingTimesWriteIndex] = timeMs
        processingTimesWriteIndex = (processingTimesWriteIndex + 1) % processingTimeHistorySize
        processingTimesCount = min(processingTimesCount + 1, processingTimeHistorySize)

        // Compute average from filled portion of ring
        var sum = 0.0
        for i in 0..<processingTimesCount {
            sum += processingTimesRing[i]
        }
        stats.avgProcessingTimeMs = sum / Double(processingTimesCount)
        stats.maxProcessingTimeMs = max(stats.maxProcessingTimeMs, timeMs)
    }

    private func updatePassThroughWindow(input: [Float], output: [Float]) {
        guard input.count == output.count else { return }
        for i in 0..<input.count {
            let x = Double(input[i])
            let y = Double(output[i])
            passThroughWindow.sumX += x
            passThroughWindow.sumY += y
            passThroughWindow.sumXX += x * x
            passThroughWindow.sumYY += y * y
            passThroughWindow.sumXY += x * y
            passThroughWindow.sumInSq += x * x
            passThroughWindow.sumOutSq += y * y
        }
        passThroughWindow.frameCount += 1
    }

    private func updateDelayWindow(coarseDelayMs: Int, seededDelayMs: Int) {
        delayWindow.frameCount += 1
        delayWindow.coarseSamples.append(coarseDelayMs)
        delayWindow.seededSamples.append(seededDelayMs)
        if seededDelayMs >= 0 && abs(coarseDelayMs - seededDelayMs) > 80 {
            delayWindow.divergenceCount += 1
        }
    }

    private func emitDiagnosticSummariesIfNeeded() {
        let expectedFramesPerSecond = 100

        if passThroughWindow.frameCount >= expectedFramesPerSecond {
            let n = Double(passThroughWindow.frameCount * Self.frameSizeSamples)
            let cov = (n * passThroughWindow.sumXY) - (passThroughWindow.sumX * passThroughWindow.sumY)
            let varX = (n * passThroughWindow.sumXX) - (passThroughWindow.sumX * passThroughWindow.sumX)
            let varY = (n * passThroughWindow.sumYY) - (passThroughWindow.sumY * passThroughWindow.sumY)
            let corrDen = sqrt(max(varX, 0) * max(varY, 0))
            let corr = corrDen > 0 ? cov / corrDen : 0
            let rmsIn = sqrt(passThroughWindow.sumInSq / n)
            let rmsOut = sqrt(passThroughWindow.sumOutSq / n)
            let attenuationDb = (rmsIn > 0 && rmsOut > 0) ? (20 * log10(rmsIn / rmsOut)) : 0
            let hasHealthyEnergy = rmsIn >= Self.btPassThroughMinCaptureRmsLinear
                && rmsOut >= Self.btPassThroughMinRenderRmsLinear
            let lowAttenuation = hasHealthyEnergy && attenuationDb < 3.0
            let suspicious = hasHealthyEnergy && corr > 0.95 && attenuationDb < 1.0
            passThroughLowAttenuationSeconds = lowAttenuation ? (passThroughLowAttenuationSeconds + 1) : 0
            passThroughSuspiciousSeconds = suspicious ? (passThroughSuspiciousSeconds + 1) : 0
            let suspiciousSeconds = passThroughSuspiciousSeconds
            let lowAttenuationSeconds = passThroughLowAttenuationSeconds
            let passThroughMessage =
                "AEC_PASS_THROUGH_AUDIT: corr=\(String(format: "%.3f", corr)), attenuationDb=\(String(format: "%.2f", attenuationDb)), renderRmsLinear=\(String(format: "%.6f", rmsOut)), captureRmsLinear=\(String(format: "%.6f", rmsIn)), hasHealthyEnergy=\(hasHealthyEnergy), lowAttenuationSeconds=\(lowAttenuationSeconds), lowAttenuationWarning=\(lowAttenuationSeconds >= 5), suspiciousSeconds=\(suspiciousSeconds), alert=\(suspiciousSeconds >= 10)"

            Task {
                await DiagnosticLogger.shared.log(
                    .aec,
                    passThroughMessage
                )
            }

            let shouldTriggerBtRecovery = Self.shouldTriggerBtRecovery(
                btExternalMicProfileActive: isBtExternalMicProfileActive(),
                startupGateState: startupGateState,
                lowAttenuationSeconds: lowAttenuationSeconds,
                attemptCount: btRecoveryAttemptCount
            )
            if shouldTriggerBtRecovery {
                btRecoveryAttemptCount += 1
                btDelayBiasDisabledForRouteRecovery = true
                lastAppliedDelayHintMs = -1
                lastAppliedDelayHintSource = .unknown
                let attempt = btRecoveryAttemptCount
                let routeEpoch = startupGateRouteEpoch
                let previousBiasMs = btDelayHintBiasMs
                let startupState = startupGateState.rawValue
                resetStartupGateForCurrentRoute(reason: "bt_nonconverging_recovery")
                aecProcessor.reset()
                Task.detached(priority: nil) {
                    await DiagnosticLogger.shared.log(
                        .aec,
                        "AEC_BT_RECOVERY: attempt=\(attempt), reason=low_attenuation_nonconverging, routeEpochId=\(routeEpoch), startupGateState=\(startupState), lowAttenuationSeconds=\(lowAttenuationSeconds), previousBtDelayHintBiasMs=\(previousBiasMs), btDelayBiasDisabledForRouteRecovery=true"
                    )
                }
            }
            passThroughWindow = PassThroughWindow()
        }

        if delayWindow.frameCount >= expectedFramesPerSecond {
            let coarseP50 = percentile(delayWindow.coarseSamples, percentile: 50)
            let coarseP95 = percentile(delayWindow.coarseSamples, percentile: 95)
            let seededP50 = percentile(delayWindow.seededSamples, percentile: 50)
            let seededP95 = percentile(delayWindow.seededSamples, percentile: 95)
            let divergenceFrames = delayWindow.divergenceCount
            let observedFrames = delayWindow.frameCount
            let delayMessage =
                "AEC_DELAY_MODEL: coarseP50=\(coarseP50), coarseP95=\(coarseP95), seededP50=\(seededP50), seededP95=\(seededP95), divergenceFrames=\(divergenceFrames), frames=\(observedFrames)"
            Task {
                await DiagnosticLogger.shared.log(
                    .aec,
                    delayMessage
                )
            }
            delayWindow = DelayWindow()
        }
    }

    private func percentile(_ values: [Int], percentile: Int) -> Int {
        let filtered = values.filter { $0 >= 0 }.sorted()
        guard !filtered.isEmpty else { return -1 }
        let p = min(max(percentile, 0), 100)
        let idx = Int(round((Double(filtered.count - 1) * Double(p)) / 100.0))
        return filtered[idx]
    }
}
