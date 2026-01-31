//
//  AudioWorker.swift
//  Muesli
//
//  High-priority audio worker thread for non-RT processing.
//  Handles: downmix, framing, resampling, alignment, AEC.
//  IOProc only copies bytes - all processing happens here.
//

import Foundation
import os.log

// MARK: - Audio Worker Callback

/// Callback for processed audio frames
/// - Parameters:
///   - renderSamples: Processed render (system) audio (16kHz mono)
///   - captureSamples: Processed capture (mic) audio (16kHz mono, echo-cancelled)
///   - frameIndex: Sequential frame index
typealias ProcessedAudioCallback = (
    _ renderSamples: [Float],
    _ captureSamples: [Float],
    _ frameIndex: Int64
) -> Void

// MARK: - Audio Worker Statistics

/// Statistics from the audio worker
struct AudioWorkerStats {
    var framesProcessed: Int64 = 0
    var framesMissed: Int64 = 0
    var avgProcessingTimeMs: Double = 0
    var maxProcessingTimeMs: Double = 0
    var workerLoopTimeMs: Double = 0
    var isRunning: Bool = false
}

// MARK: - Audio Worker

/// High-priority audio worker for non-RT processing
/// Runs on a dedicated thread to avoid blocking IOProc callbacks
final class AudioWorker {
    
    // MARK: - Configuration
    
    /// Worker loop interval (5ms)
    static let loopIntervalMs: UInt64 = 5
    
    /// Processing frame size (10ms at 48kHz)
    static let frameSizeSamples = 480
    
    /// Output sample rate (16kHz for WhisperKit)
    static let outputSampleRate = 16000
    
    /// Internal processing sample rate (48kHz)
    static let internalSampleRate = 48000
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "AudioWorker")
    
    /// Synchronizer for render/capture alignment
    private let synchronizer: AudioSynchronizer
    
    /// AEC processor
    private let aecProcessor: AECProcessor
    
    /// Callback for processed frames
    private var processedCallback: ProcessedAudioCallback?
    
    /// Worker thread
    private var workerThread: Thread?
    
    /// Running flag
    private var isRunning: Bool = false
    
    /// Statistics
    private var stats = AudioWorkerStats()
    
    /// Lock for thread safety
    private let lock = NSLock()
    
    /// Processing time history (for averaging)
    private var processingTimes: [Double] = []
    private let processingTimeHistorySize = 100
    
    /// Resampler state (48kHz -> 16kHz)
    private var resampleBuffer: [Float] = []
    private let resampleRatio = Double(outputSampleRate) / Double(internalSampleRate)
    
    // MARK: - Initialization
    
    init(synchronizer: AudioSynchronizer, aecProcessor: AECProcessor) {
        self.synchronizer = synchronizer
        self.aecProcessor = aecProcessor
        
        // Pre-allocate resample buffer
        let maxOutputFrameSize = Int(Double(Self.frameSizeSamples) * resampleRatio) + 2
        resampleBuffer = [Float](repeating: 0, count: maxOutputFrameSize)
        
        logger.info("AudioWorker initialized")
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public API
    
    /// Start the audio worker
    /// - Parameter callback: Callback for processed frames
    func start(callback: @escaping ProcessedAudioCallback) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isRunning else { return }
        
        processedCallback = callback
        isRunning = true
        stats.isRunning = true
        
        // Create and start worker thread
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
    
    /// Stop the audio worker
    func stop() {
        lock.lock()
        isRunning = false
        stats.isRunning = false
        lock.unlock()
        
        // Wait for thread to finish
        while workerThread?.isExecuting == true {
            Thread.sleep(forTimeInterval: 0.01)
        }
        workerThread = nil
        processedCallback = nil

        logger.info("AudioWorker stopped")

        let logFrames = self.stats.framesProcessed
        let logMissed = self.stats.framesMissed
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "AUDIO_WORKER_STOP: frames=\(logFrames), " +
                "missed=\(logMissed)")
        }
    }
    
    /// Get current statistics
    func getStats() -> AudioWorkerStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }
    
    /// Reset the worker state
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        synchronizer.reset()
        aecProcessor.reset()
        stats = AudioWorkerStats()
        stats.isRunning = isRunning
        processingTimes.removeAll()
        
        logger.info("AudioWorker reset")
    }
    
    // MARK: - Private Implementation
    
    /// Main worker loop
    private func workerLoop() {
        let loopIntervalNs = Self.loopIntervalMs * 1_000_000
        
        while isRunning {
            let loopStart = DispatchTime.now()
            
            // Process all available frames
            processAvailableFrames()
            
            // Calculate loop time for stats
            let loopEnd = DispatchTime.now()
            let loopTimeNs = loopEnd.uptimeNanoseconds - loopStart.uptimeNanoseconds
            stats.workerLoopTimeMs = Double(loopTimeNs) / 1_000_000
            
            // Sleep until next iteration
            let sleepTimeNs = loopIntervalNs - min(loopTimeNs, loopIntervalNs)
            if sleepTimeNs > 0 {
                Thread.sleep(forTimeInterval: Double(sleepTimeNs) / 1_000_000_000)
            }
        }
    }
    
    /// Process all available aligned frames
    private func processAvailableFrames() {
        var framesThisIteration = 0
        let maxFramesPerIteration = 10  // Limit to prevent runaway processing
        
        while framesThisIteration < maxFramesPerIteration {
            guard let frame = synchronizer.getAlignedFrame() else {
                break
            }
            
            let processStart = DispatchTime.now()
            
            // Run AEC on the aligned frame
            let processedCapture = aecProcessor.processFrame(
                frame: frame,
                isStable: frame.isStable
            )
            
            // Downmix render to mono (if needed - tap output may already be mono)
            let monoRender = downsampleToMono(frame.renderSamples)
            let monoCapture = downsampleToMono(processedCapture)
            
            // Resample from 48kHz to 16kHz for transcription
            let render16k = resampleTo16kHz(monoRender)
            let capture16k = resampleTo16kHz(monoCapture)
            
            // Deliver to callback
            lock.lock()
            let callback = processedCallback
            stats.framesProcessed += 1
            lock.unlock()
            
            callback?(render16k, capture16k, frame.sampleIndex)
            
            // Update processing time stats
            let processEnd = DispatchTime.now()
            let processingTimeNs = processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds
            let processingTimeMs = Double(processingTimeNs) / 1_000_000
            
            updateProcessingTimeStats(processingTimeMs)
            
            framesThisIteration += 1
        }
    }
    
    /// Update processing time statistics
    private func updateProcessingTimeStats(_ timeMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        processingTimes.append(timeMs)
        if processingTimes.count > processingTimeHistorySize {
            processingTimes.removeFirst()
        }
        
        stats.avgProcessingTimeMs = processingTimes.reduce(0, +) / Double(processingTimes.count)
        stats.maxProcessingTimeMs = max(stats.maxProcessingTimeMs, timeMs)
    }
    
    /// Downsample stereo to mono by averaging channels
    private func downsampleToMono(_ samples: [Float]) -> [Float] {
        // Assume samples are interleaved stereo if count is even
        // If already mono (480 samples), return as-is
        guard samples.count == Self.frameSizeSamples * 2 else {
            return samples
        }
        
        var mono = [Float](repeating: 0, count: Self.frameSizeSamples)
        for i in 0..<Self.frameSizeSamples {
            mono[i] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5
        }
        return mono
    }
    
    /// Resample from 48kHz to 16kHz for WhisperKit
    private func resampleTo16kHz(_ samples: [Float]) -> [Float] {
        // 48kHz -> 16kHz = 1/3 ratio
        // 480 samples at 48kHz = 160 samples at 16kHz
        let outputCount = samples.count / 3
        guard outputCount > 0 else { return [] }
        
        var output = [Float](repeating: 0, count: outputCount)
        
        // Simple 3:1 decimation with averaging (basic anti-alias)
        for i in 0..<outputCount {
            let srcIndex = i * 3
            if srcIndex + 2 < samples.count {
                output[i] = (samples[srcIndex] + samples[srcIndex + 1] + samples[srcIndex + 2]) / 3.0
            } else if srcIndex < samples.count {
                output[i] = samples[srcIndex]
            }
        }
        
        return output
    }
}

// MARK: - Format Conversion Utilities

/// Utilities for RT-safe format conversion
/// Note: These run on the worker thread, NOT in IOProc
struct FormatConversion {
    
    /// Convert interleaved stereo to mono
    /// - Parameters:
    ///   - input: Interleaved stereo samples
    ///   - inputCount: Number of input samples (frames * 2)
    ///   - output: Output buffer for mono samples
    ///   - outputCount: Output buffer size
    /// - Returns: Number of output samples written
    static func stereoToMono(
        input: UnsafePointer<Float>,
        inputCount: Int,
        output: UnsafeMutablePointer<Float>,
        outputCount: Int
    ) -> Int {
        let frameCount = inputCount / 2
        let actualOutputCount = min(frameCount, outputCount)
        
        for i in 0..<actualOutputCount {
            output[i] = (input[i * 2] + input[i * 2 + 1]) * 0.5
        }
        
        return actualOutputCount
    }
    
    /// Normalize Int16 samples to Float32 [-1, 1]
    /// - Parameters:
    ///   - input: Int16 samples
    ///   - inputCount: Number of input samples
    ///   - output: Output buffer for Float32 samples
    /// - Returns: Number of output samples written
    static func int16ToFloat32(
        input: UnsafePointer<Int16>,
        inputCount: Int,
        output: UnsafeMutablePointer<Float>
    ) -> Int {
        let scale: Float = 1.0 / 32768.0
        
        for i in 0..<inputCount {
            output[i] = Float(input[i]) * scale
        }
        
        return inputCount
    }
    
    /// Frame audio into 10ms chunks with remainder handling
    /// - Parameters:
    ///   - input: Input samples
    ///   - inputCount: Number of input samples
    ///   - remainder: Remainder buffer (pre-allocated)
    ///   - remainderCount: Current remainder count (in/out)
    ///   - frameSize: Target frame size (e.g., 480 for 10ms at 48kHz)
    ///   - frameHandler: Called for each complete frame
    static func frameAudio(
        input: UnsafePointer<Float>,
        inputCount: Int,
        remainder: UnsafeMutablePointer<Float>,
        remainderCount: inout Int,
        frameSize: Int,
        frameHandler: (UnsafePointer<Float>, Int) -> Void
    ) {
        var inputOffset = 0
        
        // First, complete any partial frame from remainder
        if remainderCount > 0 {
            let needed = frameSize - remainderCount
            let available = min(needed, inputCount)
            
            // Copy to remainder
            for i in 0..<available {
                remainder[remainderCount + i] = input[i]
            }
            
            remainderCount += available
            inputOffset = available
            
            // If we have a complete frame, emit it
            if remainderCount >= frameSize {
                frameHandler(remainder, frameSize)
                remainderCount = 0
            }
        }
        
        // Process complete frames from input
        while inputOffset + frameSize <= inputCount {
            frameHandler(input + inputOffset, frameSize)
            inputOffset += frameSize
        }
        
        // Store any remaining samples
        let leftover = inputCount - inputOffset
        if leftover > 0 {
            for i in 0..<leftover {
                remainder[remainderCount + i] = input[inputOffset + i]
            }
            remainderCount += leftover
        }
    }
}
