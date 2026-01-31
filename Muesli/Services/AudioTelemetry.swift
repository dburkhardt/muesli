//
//  AudioTelemetry.swift
//  Muesli
//
//  Telemetry and observability for the audio pipeline.
//  Collects metrics per session for debugging and quality monitoring.
//

import Foundation
import os.log

// MARK: - Session Telemetry

/// Telemetry data collected per recording session
struct SessionTelemetry: Sendable {
    // MARK: - Delay Metrics
    
    /// Coarse delay estimate in milliseconds
    var coarseDelayMs: Double = 0
    
    /// Delay variance in milliseconds
    var delayVarianceMs: Double = 0
    
    // MARK: - Drift Metrics
    
    /// Drift estimate in parts per million
    var driftPPM: Double = 0
    
    /// Resampler ratio applied
    var resamplerRatio: Double = 1.0
    
    // MARK: - Buffer Metrics
    
    /// Render buffer depth in milliseconds
    var renderBufferDepthMs: Double = 0
    
    /// Capture buffer depth in milliseconds
    var captureBufferDepthMs: Double = 0
    
    // MARK: - Error Counts
    
    /// Number of render underruns
    var renderUnderruns: Int = 0
    
    /// Number of capture overruns
    var captureOverruns: Int = 0
    
    /// Number of discontinuities detected
    var discontinuities: Int = 0
    
    /// Number of AEC bad-alignment events
    var aecBadAlignmentCount: Int = 0
    
    // MARK: - AEC Metrics
    
    /// ERLE trend (dB) - echo return loss enhancement
    var erleTrend: [Float] = []
    
    /// Current ERLE value
    var currentERLE: Float = 0
    
    // MARK: - Silence Diagnosis (per plan)
    
    /// Rolling tap RMS level
    var tapRMS: Float = 0
    
    /// Whether tap is active (producing audio)
    var tapActive: Bool = false
    
    /// Self-test A passed (system sound present)
    var selfTestAPassed: Bool = false
    
    /// Self-test B passed (Muesli excluded)
    var selfTestBPassed: Bool = false
    
    /// Whether permission denied is suspected
    var suspectedPermissionDenied: Bool = false
    
    /// Which UI guidance was shown
    var guidanceShown: String?
    
    // MARK: - Timing
    
    /// Session start time
    var sessionStartTime: Date = Date()
    
    /// Total frames processed
    var framesProcessed: Int64 = 0
    
    /// Total duration in seconds
    var durationSeconds: TimeInterval {
        return Date().timeIntervalSince(sessionStartTime)
    }
}

// MARK: - Audio Telemetry Service

/// Service for collecting and reporting audio pipeline telemetry
actor AudioTelemetryService {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "AudioTelemetry")
    
    /// Current session telemetry
    private var currentSession = SessionTelemetry()
    
    /// History of past sessions (last 10)
    private var sessionHistory: [SessionTelemetry] = []
    private let maxHistorySize = 10
    
    /// ERLE history for trend calculation
    private var erleHistory: [Float] = []
    private let erleHistorySize = 60  // 1 minute at 1 sample/sec
    
    /// Update interval (1 second)
    private let updateInterval: TimeInterval = 1.0
    
    /// Last update time
    private var lastUpdateTime: Date = Date()
    
    // MARK: - Initialization
    
    init() {
        logger.info("AudioTelemetryService initialized")
    }
    
    // MARK: - Session Management
    
    /// Start a new telemetry session
    func startSession() {
        currentSession = SessionTelemetry()
        currentSession.sessionStartTime = Date()
        erleHistory.removeAll()
        
        logger.info("Telemetry session started")
        
        Task {
            await DiagnosticLogger.shared.log(.aec, "TELEMETRY_SESSION_START")
        }
    }
    
    /// End the current session and archive it
    func endSession() {
        // Archive current session
        sessionHistory.append(currentSession)
        if sessionHistory.count > maxHistorySize {
            sessionHistory.removeFirst()
        }
        
        // Log session summary
        logSessionSummary()
        
        logger.info("Telemetry session ended: duration=\(String(format: "%.1f", self.currentSession.durationSeconds))s, frames=\(self.currentSession.framesProcessed)")
    }
    
    // MARK: - Update Methods
    
    /// Update delay metrics
    func updateDelay(coarseMs: Double, varianceMs: Double) {
        currentSession.coarseDelayMs = coarseMs
        currentSession.delayVarianceMs = varianceMs
    }
    
    /// Update drift metrics
    func updateDrift(ppm: Double, resamplerRatio: Double) {
        currentSession.driftPPM = ppm
        currentSession.resamplerRatio = resamplerRatio
    }
    
    /// Update buffer depths
    func updateBufferDepths(renderMs: Double, captureMs: Double) {
        currentSession.renderBufferDepthMs = renderMs
        currentSession.captureBufferDepthMs = captureMs
    }
    
    /// Record a render underrun
    func recordRenderUnderrun() {
        currentSession.renderUnderruns += 1
    }
    
    /// Record a capture overrun
    func recordCaptureOverrun() {
        currentSession.captureOverruns += 1
    }
    
    /// Record a discontinuity
    func recordDiscontinuity() {
        currentSession.discontinuities += 1
    }
    
    /// Record an AEC bad-alignment event
    func recordAECBadAlignment() {
        currentSession.aecBadAlignmentCount += 1
    }
    
    /// Update ERLE value
    func updateERLE(_ erleDb: Float) {
        currentSession.currentERLE = erleDb
        
        erleHistory.append(erleDb)
        if erleHistory.count > erleHistorySize {
            erleHistory.removeFirst()
        }
        
        currentSession.erleTrend = erleHistory
    }
    
    /// Update silence diagnosis metrics
    func updateSilenceDiagnosis(
        tapRMS: Float,
        tapActive: Bool,
        selfTestA: Bool,
        selfTestB: Bool,
        suspectedDenied: Bool,
        guidanceShown: String?
    ) {
        currentSession.tapRMS = tapRMS
        currentSession.tapActive = tapActive
        currentSession.selfTestAPassed = selfTestA
        currentSession.selfTestBPassed = selfTestB
        currentSession.suspectedPermissionDenied = suspectedDenied
        currentSession.guidanceShown = guidanceShown
    }
    
    /// Update frame count
    func updateFrameCount(_ count: Int64) {
        currentSession.framesProcessed = count
    }
    
    /// Update from synchronizer stats
    func updateFromSynchronizer(_ stats: SynchronizerStats) {
        currentSession.coarseDelayMs = stats.coarseDelayMs
        currentSession.delayVarianceMs = stats.delayVarianceMs
        currentSession.driftPPM = stats.driftPPM
        currentSession.renderBufferDepthMs = stats.renderBufferDepthMs
        currentSession.captureBufferDepthMs = stats.captureBufferDepthMs
        currentSession.renderUnderruns = stats.underruns
        currentSession.captureOverruns = stats.overruns
        currentSession.discontinuities = stats.discontinuities
        currentSession.framesProcessed = stats.framesProcessed
    }
    
    /// Update from AEC stats
    func updateFromAEC(_ stats: AECStats) {
        updateERLE(stats.erleDb)
    }
    
    // MARK: - Query Methods
    
    /// Get current session telemetry
    func getCurrentSession() -> SessionTelemetry {
        return currentSession
    }
    
    /// Get session history
    func getSessionHistory() -> [SessionTelemetry] {
        return sessionHistory
    }
    
    /// Get a summary string for the current session
    func getCurrentSummary() -> String {
        let session = currentSession
        return """
        Duration: \(String(format: "%.1f", session.durationSeconds))s
        Frames: \(session.framesProcessed)
        Delay: \(String(format: "%.1f", session.coarseDelayMs))ms (±\(String(format: "%.1f", session.delayVarianceMs))ms)
        Drift: \(String(format: "%.1f", session.driftPPM)) ppm
        Buffers: render=\(String(format: "%.0f", session.renderBufferDepthMs))ms, capture=\(String(format: "%.0f", session.captureBufferDepthMs))ms
        Errors: underruns=\(session.renderUnderruns), overruns=\(session.captureOverruns), discontinuities=\(session.discontinuities)
        ERLE: \(String(format: "%.1f", session.currentERLE))dB
        Tap: rms=\(String(format: "%.4f", session.tapRMS)), active=\(session.tapActive)
        """
    }
    
    // MARK: - Private Methods
    
    /// Log session summary to diagnostic logger
    private func logSessionSummary() {
        let session = currentSession
        
        Task {
            await DiagnosticLogger.shared.log(.aec, """
                TELEMETRY_SESSION_END: \
                duration=\(String(format: "%.1f", session.durationSeconds))s, \
                frames=\(session.framesProcessed), \
                delay=\(String(format: "%.1f", session.coarseDelayMs))ms, \
                drift=\(String(format: "%.1f", session.driftPPM))ppm, \
                underruns=\(session.renderUnderruns), \
                overruns=\(session.captureOverruns), \
                discontinuities=\(session.discontinuities), \
                erle=\(String(format: "%.1f", session.currentERLE))dB, \
                selfTestA=\(session.selfTestAPassed), \
                selfTestB=\(session.selfTestBPassed)
                """)
        }
    }
}

// MARK: - Shared Instance

extension AudioTelemetryService {
    /// Shared singleton instance
    static let shared = AudioTelemetryService()
}
