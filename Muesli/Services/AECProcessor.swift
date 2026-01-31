//
//  AECProcessor.swift
//  Muesli
//
//  AEC Pipeline wrapper with gating for the Core Audio tap architecture.
//  Integrates with AudioSynchronizer for aligned frame processing.
//  Implements AEC gating per plan: only adapt when stable.
//

import Foundation
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
    
    /// WebRTC AEC bridge (underlying implementation)
    private var aecBridge: WebRTCAECBridge?
    
    /// Current operating mode
    private(set) var mode: AECMode = .off
    
    /// Device topology mode
    private var topologyMode: DeviceTopologyMode = .unknown
    
    /// Whether adaptation is currently frozen
    private(set) var isAdaptationFrozen: Bool = false
    
    /// Statistics
    private var stats = AECStats()
    
    /// Lock for thread safety
    private let lock = NSLock()
    
    /// Pre-allocated output buffer
    private var outputBuffer: [Float]
    
    // MARK: - Initialization
    
    init() {
        outputBuffer = [Float](repeating: 0, count: Self.frameSizeSamples)
        initializeAEC()
    }
    
    deinit {
        aecBridge = nil
    }
    
    // MARK: - Public API
    
    /// Configure AEC for device topology
    /// - Parameter topology: Current device topology mode
    func configure(topology: DeviceTopologyMode) {
        lock.lock()
        defer { lock.unlock() }
        
        topologyMode = topology
        
        switch topology {
        case .headset:
            // Headset mode: AEC off by default to avoid artifacts
            mode = .off
            logger.info("AEC mode: OFF (headset)")
            
        case .speakerphone:
            // Speakerphone mode: Full AEC enabled
            mode = .aggressive
            logger.info("AEC mode: AGGRESSIVE (speakerphone)")
            
        case .unknown:
            // Unknown: Use conservative AEC
            mode = .conservative
            logger.info("AEC mode: CONSERVATIVE (unknown topology)")
        }
        
        stats.currentMode = mode

        let logMode = self.mode
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "AEC_CONFIG: mode=\(logMode), topology=\(topology)")
        }
    }
    
    /// Process an aligned audio frame
    /// - Parameters:
    ///   - frame: Aligned render/capture frame from synchronizer
    ///   - isStable: Whether the synchronizer is currently stable
    /// - Returns: Processed capture samples (echo-cancelled if AEC active)
    func processFrame(
        frame: AlignedFrame,
        isStable: Bool
    ) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        
        // Check if AEC is enabled
        guard mode != .off else {
            stats.framesSkipped += 1
            return frame.captureSamples
        }
        
        // Update gating based on stability
        updateGating(isStable: isStable)
        
        // If adaptation is frozen, pass through
        if isAdaptationFrozen && mode == .conservative {
            stats.framesSkipped += 1
            return frame.captureSamples
        }
        
        // Ensure AEC is initialized
        guard let bridge = aecBridge, bridge.isReady else {
            stats.framesSkipped += 1
            return frame.captureSamples
        }
        
        // Verify frame sizes
        guard frame.renderSamples.count == Self.frameSizeSamples,
              frame.captureSamples.count == Self.frameSizeSamples else {
            logger.warning("Invalid frame size: render=\(frame.renderSamples.count), capture=\(frame.captureSamples.count)")
            stats.framesSkipped += 1
            return frame.captureSamples
        }
        
        // Process render (far-end) first
        let renderSuccess = frame.renderSamples.withUnsafeBufferPointer { ptr in
            bridge.processRenderFrame(ptr.baseAddress!)
        }
        
        if !renderSuccess {
            logger.warning("Render frame processing failed")
            stats.framesSkipped += 1
            return frame.captureSamples
        }
        
        // Process capture (near-end) with echo cancellation
        var processedSamples = [Float](repeating: 0, count: Self.frameSizeSamples)
        
        let captureSuccess = frame.captureSamples.withUnsafeBufferPointer { inputPtr in
            processedSamples.withUnsafeMutableBufferPointer { outputPtr in
                bridge.processCaptureFrame(inputPtr.baseAddress!, outputSamples: outputPtr.baseAddress!)
            }
        }
        
        if !captureSuccess {
            logger.warning("Capture frame processing failed")
            stats.framesSkipped += 1
            return frame.captureSamples
        }
        
        // Update statistics
        stats.framesProcessed += 1
        stats.erleDb = bridge.getERLE()
        stats.delayMs = Int(bridge.getDelayMs())
        
        return processedSamples
    }
    
    /// Freeze AEC adaptation (during discontinuity/instability)
    func freezeAdaptation() {
        lock.lock()
        defer { lock.unlock() }
        
        isAdaptationFrozen = true
        stats.adaptationFrozen = true
        
        logger.info("AEC adaptation frozen")
        
        Task {
            await DiagnosticLogger.shared.log(.aec, "AEC_FREEZE")
        }
    }
    
    /// Unfreeze AEC adaptation
    func unfreezeAdaptation() {
        lock.lock()
        defer { lock.unlock() }
        
        isAdaptationFrozen = false
        stats.adaptationFrozen = false
        
        logger.info("AEC adaptation unfrozen")
        
        Task {
            await DiagnosticLogger.shared.log(.aec, "AEC_UNFREEZE")
        }
    }
    
    /// Reset AEC state
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        aecBridge?.reset()
        isAdaptationFrozen = false
        stats = AECStats()
        stats.currentMode = mode
        
        logger.info("AEC reset")

        let statsErle = stats.erleDb
        let statsDelay = stats.delayMs
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "AEC_RESET: erle=\(statsErle)dB, delay=\(statsDelay)ms")
        }
    }
    
    /// Get current statistics
    func getStats() -> AECStats {
        lock.lock()
        defer { lock.unlock() }
        
        // Update ERLE and delay from bridge
        if let bridge = aecBridge, bridge.isReady {
            stats.erleDb = bridge.getERLE()
            stats.delayMs = Int(bridge.getDelayMs())
        }
        
        return stats
    }
    
    /// Set AEC mode manually
    func setMode(_ newMode: AECMode) {
        lock.lock()
        defer { lock.unlock() }
        
        mode = newMode
        stats.currentMode = newMode
        
        logger.info("AEC mode set: \(String(describing: newMode))")
    }
    
    // MARK: - Private Implementation
    
    /// Initialize the WebRTC AEC bridge
    private func initializeAEC() {
        do {
            aecBridge = try WebRTCAECBridge(
                sampleRate: Self.sampleRate,
                channels: 1
            )
            logger.info("WebRTC AEC initialized")
            
            Task {
                await DiagnosticLogger.shared.log(.aec, "AEC_INIT: WebRTC AEC3")
            }
        } catch {
            logger.error("Failed to initialize AEC: \(error.localizedDescription)")
            
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "AEC_INIT_FAILED: \(error.localizedDescription)")
            }
        }
    }
    
    /// Update gating based on stability
    private func updateGating(isStable: Bool) {
        let wasAdaptationFrozen = isAdaptationFrozen
        
        // Gate adaptation based on stability
        if !isStable {
            if !isAdaptationFrozen {
                isAdaptationFrozen = true
                stats.adaptationFrozen = true
            }
        } else {
            // Only unfreeze in aggressive mode
            if isAdaptationFrozen && mode == .aggressive {
                isAdaptationFrozen = false
                stats.adaptationFrozen = false
            }
        }
        
        // Log state changes
        if wasAdaptationFrozen != isAdaptationFrozen {
            let logFrozen = self.isAdaptationFrozen
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "AEC_GATING: frozen=\(logFrozen), stable=\(isStable)")
            }
        }
    }
}
