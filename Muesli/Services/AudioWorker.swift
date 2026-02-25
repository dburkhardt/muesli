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

// MARK: - Audio Worker

/// High-priority audio worker for non-RT processing.
final class AudioWorker {
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

    // MARK: - Initialization

    init(
        synchronizer: AudioSynchronizer,
        aecProcessor: AECProcessor,
        popRenderAECFrame: @escaping PopAECFrameCallback,
        popCaptureAECFrame: @escaping PopAECFrameCallback,
        isAECEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.synchronizer = synchronizer
        self.aecProcessor = aecProcessor
        self.popRenderAECFrame = popRenderAECFrame
        self.popCaptureAECFrame = popCaptureAECFrame
        self.isAECEnabled = isAECEnabled
        self.processingTimesRing = [Double](repeating: 0, count: processingTimeHistorySize)

        assert(renderFrameBuffer.count == Self.frameSizeSamples)
        assert(captureFrameBuffer.count == Self.frameSizeSamples)

        logger.info("AudioWorker initialized")
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

        Task {
            await DiagnosticLogger.shared.log(.aec, "AUDIO_WORKER_START")
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

        Task {
            await DiagnosticLogger.shared.log(
                .aec,
                "AUDIO_WORKER_STOP: captureFrames=\(logCaptureFrames), renderFrames=\(logRenderFrames), missed=\(logMissed), aecEnabled=\(logAECEnabled)"
            )
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

        // 1) Feed render stream first, but keep lead bounded.
        //    Skip entirely if AEC is disabled — no point feeding render to a disabled processor.
        var renderFedThisIteration = 0
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

                _ = aecProcessor.feedRenderFrame(renderFrameBuffer, isStable: synchronizer.isStable)
                renderFedCount += 1
                renderFedThisIteration += 1

                // Accumulate render RMS for telemetry
                let renderRms = computeRMS(renderFrameBuffer)
                renderRmsAccumulator += Double(renderRms)
                rmsFrameCount += 1

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
                // Feed AEC3 the synchronizer-derived render lead as stream delay hint.
                // Prefer coarseDelayMs once available; fall back to seededDelayMs during
                // early stabilization so delay hint is non-zero as soon as possible.
                let coarseDelayMs = synchronizer.coarseDelayMs
                let seededDelayMs = synchronizer.seededDelayMs
                let streamDelayHintMs = coarseDelayMs > 0 ? coarseDelayMs : max(seededDelayMs, 0)
                let boundedStreamDelayMs = min(max(streamDelayHintMs, 0), 500)
                let delaySet = aecProcessor.setStreamDelayMs(boundedStreamDelayMs)
                if !delaySet {
                    lock.lock()
                    stats.framesMissed += 1
                    lock.unlock()
                }

                processedCapture = aecProcessor.processCaptureFrame(
                    captureFrameBuffer,
                    isStable: synchronizer.isStable
                )
            } else {
                // AEC disabled — pass capture through unmodified
                processedCapture = captureFrameBuffer
            }
            let processEnd = DispatchTime.now()
            let processingTimeMs = Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000

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
}
