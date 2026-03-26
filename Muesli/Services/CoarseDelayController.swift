//
//  CoarseDelayController.swift
//  Muesli
//
//  Coarse delay controller for audio stream alignment.
//  Uses hysteresis and slew limiting for stable delay tracking.
//  Per plan: 15ms deadband, 1ms/sec slew, 0-500ms clamp.
//

import Foundation
import os.log

// MARK: - Coarse Delay Controller

/// Controls coarse delay estimation for render-capture alignment
/// Uses conservative hysteresis and slew limiting to prevent AEC instability
final class CoarseDelayController {
    private struct TuningProfile {
        let deadbandSamples: Int
        let maxSlewRateSamplesPerSecond: Int
    }

    // MARK: - Configuration (from plan)
    
    /// Hysteresis deadband in samples (15ms at 48kHz)
    static let deadbandSamples = 15 * 48  // 720 samples
    
    /// Maximum slew rate (1ms/sec at 48kHz = 48 samples/sec)
    static let maxSlewRateSamplesPerSecond = 48

    /// BT-output + external-mic profile deadband (8ms at 48kHz)
    static let btExternalMicDeadbandSamples = 8 * 48  // 384 samples

    /// BT-output + external-mic profile slew (4ms/sec at 48kHz)
    static let btExternalMicMaxSlewRateSamplesPerSecond = 192
    
    /// Minimum delay (0ms)
    static let minDelaySamples = 0
    
    /// Maximum delay (500ms at 48kHz)
    static let maxDelaySamples = 500 * 48  // 24000 samples
    
    /// Stability threshold (10ms at 48kHz)
    static let stabilityThresholdSamples = 10 * 48  // 480 samples
    
    /// Minimum stable time for AEC adaptation (5 seconds)
    static let minStableTimeSeconds: TimeInterval = 5.0
    
    /// Time without discontinuity for stable state (10 seconds)
    static let minNoDiscontinuitySeconds: TimeInterval = 10.0
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "CoarseDelayController")
    
    /// Current delay estimate in samples
    private(set) var currentDelaySamples: Int = 0
    
    /// Target delay (what we're slewing toward)
    private var targetDelaySamples: Int = 0
    
    /// Whether adaptation is frozen (during instability)
    private var isAdaptationFrozen: Bool = false
    
    /// Whether we're in headset mode (more conservative)
    private var isHeadsetMode: Bool = false

    /// Active delay adaptation tuning profile.
    private var tuningProfile = TuningProfile(
        deadbandSamples: CoarseDelayController.deadbandSamples,
        maxSlewRateSamplesPerSecond: CoarseDelayController.maxSlewRateSamplesPerSecond
    )
    
    /// Last update timestamp for slew calculation
    private var lastUpdateTime: Date = Date()
    
    /// Last time delay was stable
    private var lastStableTime: Date?
    
    /// Accumulated stable time
    private var stableTimeAccumulated: TimeInterval = 0
    
    /// History of delay observations for variance calculation
    private var delayHistory: [Int] = []
    private let delayHistorySize = 50
    
    /// Lock for thread safety
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    init() {
        logger.debug("CoarseDelayController initialized")
    }
    
    // MARK: - Public API
    
    /// Update delay estimate with new observation
    /// Only updates when conditions allow (per plan gating rules)
    /// - Parameter observedDelaySamples: Observed delay in samples
    func update(observedDelaySamples: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        // Don't update if frozen
        guard !isAdaptationFrozen else { return }
        
        // Clamp observed delay to valid range
        let clampedObserved = max(Self.minDelaySamples, min(Self.maxDelaySamples, observedDelaySamples))
        
        // Add to history
        delayHistory.append(clampedObserved)
        if delayHistory.count > delayHistorySize {
            delayHistory.removeFirst()
        }
        
        // Calculate error from current delay
        let error = clampedObserved - currentDelaySamples
        
        // Apply hysteresis deadband - ignore small changes
        guard abs(error) > tuningProfile.deadbandSamples else {
            // Within deadband - consider stable
            updateStability(isStable: true)
            return
        }
        
        // Update target delay
        targetDelaySamples = clampedObserved
        
        // Apply slew limiting
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUpdateTime)
        lastUpdateTime = now
        
        let maxSlewThisUpdate = Int(Double(tuningProfile.maxSlewRateSamplesPerSecond) * elapsed)
        let slewAmount = min(abs(error), max(1, maxSlewThisUpdate))
        
        if error > 0 {
            currentDelaySamples += slewAmount
        } else {
            currentDelaySamples -= slewAmount
        }
        
        // Clamp result
        currentDelaySamples = max(Self.minDelaySamples, min(Self.maxDelaySamples, currentDelaySamples))
        
        // Not stable during slewing
        updateStability(isStable: false)
    }
    
    /// Freeze adaptation (during discontinuity/instability)
    func freezeAdaptation() {
        lock.lock()
        defer { lock.unlock() }
        
        isAdaptationFrozen = true
        stableTimeAccumulated = 0
        lastStableTime = nil
        
        logger.info("Adaptation frozen")
    }
    
    /// Unfreeze adaptation
    func unfreezeAdaptation() {
        lock.lock()
        defer { lock.unlock() }
        
        isAdaptationFrozen = false
        lastUpdateTime = Date()
        
        logger.info("Adaptation unfrozen")
    }
    
    /// Set headset mode (more conservative adaptation)
    func setHeadsetMode(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        
        isHeadsetMode = enabled
        
        // In headset mode, freeze adaptation by default
        if enabled {
            isAdaptationFrozen = true
        }
    }

    /// Set BT-output + external-mic tuning profile.
    /// This profile allows quicker convergence on routes with larger transport jitter.
    func setBluetoothExternalMicProfile(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }

        tuningProfile = enabled
            ? TuningProfile(
                deadbandSamples: Self.btExternalMicDeadbandSamples,
                maxSlewRateSamplesPerSecond: Self.btExternalMicMaxSlewRateSamplesPerSecond
            )
            : TuningProfile(
                deadbandSamples: Self.deadbandSamples,
                maxSlewRateSamplesPerSecond: Self.maxSlewRateSamplesPerSecond
            )

        logger.info(
            "CoarseDelayController BT profile \(enabled ? "enabled" : "disabled"), deadband=\(self.tuningProfile.deadbandSamples) samples, maxSlew=\(self.tuningProfile.maxSlewRateSamplesPerSecond) samples/sec"
        )
    }
    
    /// Seed the delay estimate directly from a known render-lead measurement.
    /// Use at stable-transition time when the render lead is directly observable
    /// from buffer depths — bypasses slew limiting so AEC3 gets the correct delay
    /// immediately rather than ramping from 0 over ~90 seconds.
    /// - Parameter delaySamples: Known render-to-capture offset in samples
    func seed(delaySamples: Int) {
        lock.lock()
        defer { lock.unlock() }

        let clamped = max(Self.minDelaySamples, min(Self.maxDelaySamples, delaySamples))
        currentDelaySamples = clamped
        targetDelaySamples = clamped
        // Reset history so variance/stability tracking reflects the seeded value
        delayHistory.removeAll()
        delayHistory.append(clamped)

        logger.info("CoarseDelayController seeded: \(clamped) samples (\(String(format: "%.1f", Double(clamped)/48.0))ms)")
    }

    /// Reset the controller
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        currentDelaySamples = 0
        targetDelaySamples = 0
        isAdaptationFrozen = false
        lastUpdateTime = Date()
        lastStableTime = nil
        stableTimeAccumulated = 0
        delayHistory.removeAll()
        
        logger.info("CoarseDelayController reset")
    }
    
    /// Check if delay is currently stable
    /// Stable = abs(delay_error) < 10ms for >= 5 seconds
    var isStable: Bool {
        lock.lock()
        defer { lock.unlock() }
        
        return stableTimeAccumulated >= Self.minStableTimeSeconds
    }
    
    /// Get current delay in milliseconds
    var currentDelayMs: Double {
        lock.lock()
        defer { lock.unlock() }
        
        return Double(currentDelaySamples) / 48.0
    }
    
    /// Get delay variance in milliseconds
    var delayVarianceMs: Double {
        lock.lock()
        defer { lock.unlock() }
        
        guard delayHistory.count >= 2 else { return 0 }
        
        let mean = Double(delayHistory.reduce(0, +)) / Double(delayHistory.count)
        let variance = delayHistory.reduce(0.0) { sum, value in
            let diff = Double(value) - mean
            return sum + diff * diff
        } / Double(delayHistory.count)
        
        return sqrt(variance) / 48.0  // Convert to ms
    }
    
    // MARK: - Private Implementation
    
    /// Update stability tracking
    private func updateStability(isStable: Bool) {
        let now = Date()
        
        if isStable {
            if let lastStable = lastStableTime {
                stableTimeAccumulated += now.timeIntervalSince(lastStable)
            }
            lastStableTime = now
        } else {
            // Reset stability accumulation
            stableTimeAccumulated = 0
            lastStableTime = nil
        }
    }
}
