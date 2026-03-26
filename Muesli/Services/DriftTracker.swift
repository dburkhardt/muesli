//
//  DriftTracker.swift
//  Muesli
//
//  Tracks clock drift between render and capture streams.
//  Estimates drift in ppm (parts per million) and provides resampling ratio.
//

import Foundation
import os.log

// MARK: - Drift Tracker

/// Tracks clock drift between render (tap) and capture (mic) streams
/// USB microphone and Bluetooth speakers may have different clock domains
final class DriftTracker {
    // MARK: - Configuration
    
    /// Measurement window in seconds
    static let measurementWindowSeconds: TimeInterval = 60
    
    /// Maximum reasonable drift (500 ppm)
    static let maxDriftPPM: Double = 500
    
    /// Minimum measurements for provisional estimate (~5 seconds at 1Hz updates)
    static let provisionalMinMeasurements = 5

    /// Minimum measurements for valid estimate (~30 seconds at 1Hz updates)
    static let minMeasurements = 30
    
    /// Update interval for drift calculation
    static let updateIntervalSeconds: TimeInterval = 1.0
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "DriftTracker")
    
    /// Current drift estimate in ppm (positive = render faster than capture)
    private(set) var currentDriftPPM: Double = 0
    
    /// Resampling ratio to apply to capture stream (1.0 = no resampling)
    var resampleRatio: Double {
        // If render is faster, we need to speed up capture slightly
        return 1.0 + (currentDriftPPM / 1_000_000)
    }
    
    /// Whether we have a valid drift estimate
    private(set) var hasValidEstimate: Bool = false
    
    /// Whether we have a provisional (not yet fully validated) drift estimate.
    private(set) var hasProvisionalEstimate: Bool = false
    
    // MARK: - Render Tracking
    
    /// Total render samples received
    private var totalRenderSamples: Int64 = 0
    
    /// First render host time
    private var firstRenderHostTime: UInt64 = 0
    
    /// Last render host time
    private var lastRenderHostTime: UInt64 = 0
    
    // MARK: - Capture Tracking
    
    /// Total capture samples received
    private var totalCaptureSamples: Int64 = 0
    
    /// First capture host time
    private var firstCaptureHostTime: UInt64 = 0
    
    /// Last capture host time
    private var lastCaptureHostTime: UInt64 = 0
    
    // MARK: - Drift History
    
    /// History of drift measurements
    private var driftHistory: [Double] = []
    private let driftHistorySize = 60  // One minute of 1-second samples
    
    /// Last drift calculation time
    private var lastDriftCalculationTime: Date = Date()
    
    /// Lock for thread safety
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    init() {
        logger.debug("DriftTracker initialized")
    }
    
    // MARK: - Public API
    
    /// Update with render stream timing
    func updateRender(sampleTime: Float64, hostTime: UInt64, sampleCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        if firstRenderHostTime == 0 {
            firstRenderHostTime = hostTime
        }
        
        totalRenderSamples += Int64(sampleCount)
        lastRenderHostTime = hostTime
        
        calculateDriftIfNeeded()
    }
    
    /// Update with capture stream timing
    func updateCapture(sampleTime: Float64, hostTime: UInt64, sampleCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        if firstCaptureHostTime == 0 {
            firstCaptureHostTime = hostTime
        }
        
        totalCaptureSamples += Int64(sampleCount)
        lastCaptureHostTime = hostTime
        
        calculateDriftIfNeeded()
    }
    
    /// Reset the drift tracker
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        totalRenderSamples = 0
        totalCaptureSamples = 0
        firstRenderHostTime = 0
        lastRenderHostTime = 0
        firstCaptureHostTime = 0
        lastCaptureHostTime = 0
        currentDriftPPM = 0
        hasValidEstimate = false
        hasProvisionalEstimate = false
        driftHistory.removeAll()
        lastDriftCalculationTime = Date()
        
        logger.info("DriftTracker reset")
    }
    
    /// Get drift statistics
    func getStats() -> (driftPPM: Double, variance: Double, isValid: Bool) {
        lock.lock()
        defer { lock.unlock() }
        
        let variance = calculateVariance()
        return (currentDriftPPM, variance, hasValidEstimate)
    }
    
    // MARK: - Private Implementation
    
    /// Calculate drift if enough time has passed
    private func calculateDriftIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastDriftCalculationTime) >= Self.updateIntervalSeconds else {
            return
        }
        lastDriftCalculationTime = now
        
        // Need both streams to have valid timing
        guard firstRenderHostTime > 0, firstCaptureHostTime > 0,
              lastRenderHostTime > firstRenderHostTime,
              lastCaptureHostTime > firstCaptureHostTime else {
            return
        }
        
        // Calculate elapsed time in each stream (using host time)
        let renderElapsedNs = lastRenderHostTime - firstRenderHostTime
        let captureElapsedNs = lastCaptureHostTime - firstCaptureHostTime
        
        // Convert host time to seconds (Mach time is in ticks, need to convert)
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        let nsPerTick = Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
        
        let renderElapsedSeconds = Double(renderElapsedNs) * nsPerTick / 1_000_000_000
        let captureElapsedSeconds = Double(captureElapsedNs) * nsPerTick / 1_000_000_000
        
        // Need at least 10 seconds of data
        guard renderElapsedSeconds >= 10, captureElapsedSeconds >= 10 else {
            return
        }
        
        // Calculate sample rate for each stream
        let renderSampleRate = Double(totalRenderSamples) / renderElapsedSeconds
        let captureSampleRate = Double(totalCaptureSamples) / captureElapsedSeconds
        
        // Calculate drift in ppm (relative to 48kHz)
        // Positive = render is faster, negative = capture is faster
        let expectedRate = 48000.0
        let renderDriftPPM = (renderSampleRate - expectedRate) / expectedRate * 1_000_000
        let captureDriftPPM = (captureSampleRate - expectedRate) / expectedRate * 1_000_000
        
        // Relative drift between streams
        let relativeDriftPPM = renderDriftPPM - captureDriftPPM
        
        // Clamp to reasonable range
        let clampedDrift = max(-Self.maxDriftPPM, min(Self.maxDriftPPM, relativeDriftPPM))
        
        // Add to history
        driftHistory.append(clampedDrift)
        if driftHistory.count > driftHistorySize {
            driftHistory.removeFirst()
        }
        
        // Update estimate using exponential moving average
        if hasValidEstimate {
            let alpha = 0.1  // Smoothing factor
            currentDriftPPM = currentDriftPPM * (1 - alpha) + clampedDrift * alpha
        } else if driftHistory.count >= Self.minMeasurements {
            // Initial estimate from history mean
            currentDriftPPM = driftHistory.reduce(0, +) / Double(driftHistory.count)
            hasValidEstimate = true
            hasProvisionalEstimate = true

            logger.info("Drift estimate established: \(String(format: "%.1f", self.currentDriftPPM)) ppm")

            let logDrift = self.currentDriftPPM
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "DRIFT_ESTIMATE: ppm=\(String(format: "%.1f", logDrift))")
            }
        } else if driftHistory.count >= Self.provisionalMinMeasurements {
            // Provisional estimate with tighter clamp to avoid overreacting early.
            let provisional = driftHistory.reduce(0, +) / Double(driftHistory.count)
            currentDriftPPM = max(-150, min(150, provisional))
            hasProvisionalEstimate = true
        }
    }
    
    /// Calculate variance of drift measurements
    private func calculateVariance() -> Double {
        guard driftHistory.count >= 2 else { return 0 }
        
        let mean = driftHistory.reduce(0, +) / Double(driftHistory.count)
        let variance = driftHistory.reduce(0.0) { sum, value in
            let diff = value - mean
            return sum + diff * diff
        } / Double(driftHistory.count)
        
        return sqrt(variance)
    }
}

// MARK: - Adaptive Resampler

/// Simple adaptive resampler for drift compensation
/// Uses linear interpolation for low overhead
struct AdaptiveResampler {
    /// Resample audio buffer with given ratio
    /// - Parameters:
    ///   - input: Input samples
    ///   - ratio: Resampling ratio (1.0 = no change, >1 = speed up, <1 = slow down)
    /// - Returns: Resampled output
    static func resample(input: [Float], ratio: Double) -> [Float] {
        guard ratio != 1.0, !input.isEmpty else {
            return input
        }
        
        let outputCount = Int(Double(input.count) * ratio)
        guard outputCount > 0 else { return [] }
        
        var output = [Float](repeating: 0, count: outputCount)
        
        for i in 0..<outputCount {
            let inputPosition = Double(i) / ratio
            let inputIndex = Int(inputPosition)
            let fraction = Float(inputPosition - Double(inputIndex))
            
            if inputIndex + 1 < input.count {
                // Linear interpolation
                output[i] = input[inputIndex] * (1 - fraction) + input[inputIndex + 1] * fraction
            } else if inputIndex < input.count {
                output[i] = input[inputIndex]
            }
        }
        
        return output
    }
    
    /// Resample in place (modifies destination buffer)
    /// - Parameters:
    ///   - input: Input samples
    ///   - inputCount: Number of input samples
    ///   - output: Output buffer
    ///   - outputCount: Maximum output samples
    ///   - ratio: Resampling ratio
    /// - Returns: Actual number of output samples written
    static func resample(
        input: UnsafePointer<Float>,
        inputCount: Int,
        output: UnsafeMutablePointer<Float>,
        outputCount: Int,
        ratio: Double
    ) -> Int {
        guard ratio != 1.0, inputCount > 0, outputCount > 0 else {
            // Copy directly if no resampling needed
            let copyCount = min(inputCount, outputCount)
            for i in 0..<copyCount {
                output[i] = input[i]
            }
            return copyCount
        }
        
        let targetOutputCount = min(Int(Double(inputCount) * ratio), outputCount)
        
        for i in 0..<targetOutputCount {
            let inputPosition = Double(i) / ratio
            let inputIndex = Int(inputPosition)
            let fraction = Float(inputPosition - Double(inputIndex))
            
            if inputIndex + 1 < inputCount {
                output[i] = input[inputIndex] * (1 - fraction) + input[inputIndex + 1] * fraction
            } else if inputIndex < inputCount {
                output[i] = input[inputIndex]
            } else {
                output[i] = 0
            }
        }
        
        return targetOutputCount
    }
}
