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

/// Callback for processed render/system frames (transcription stream).
typealias ProcessedRenderFrameCallback = @Sendable (AudioFrame) -> Void

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

    /// Callback for processed render frames.
    private var processedRenderCallback: ProcessedRenderFrameCallback?

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
        micCallback: @escaping ProcessedMicFrameCallback,
        renderCallback: @escaping ProcessedRenderFrameCallback
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        processedMicCallback = micCallback
        processedRenderCallback = renderCallback
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
        processedRenderCallback = nil
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

            let processStart = DispatchTime.now()
            let processedCapture: [Float]
            if aecEnabled {
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

        // 3) Drain aligned frames for render transcription stream.
        var alignedFramesDelivered = 0
        while alignedFramesDelivered < maxFramesPerIteration {
            guard let alignedFrame = synchronizer.getAlignedFrame() else {
                break
            }

            lock.lock()
            let renderCallback = processedRenderCallback
            lock.unlock()

            renderCallback?(AudioFrame(
                samples: alignedFrame.renderSamples,
                sampleRate: Self.sampleRate,
                hostTime: alignedFrame.renderHostTime,
                startSampleIndex: alignedFrame.sampleIndex
            ))

            alignedFramesDelivered += 1
        }

        lock.lock()
        stats.renderFramesFed = renderFedCount
        stats.renderLeadFrames = renderFedCount - captureFedCount
        let currentStats = stats
        lock.unlock()

        // Periodic AEC telemetry (~every 10 seconds)
        aecProcessor.logPeriodicTelemetry(workerStats: currentStats)
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
