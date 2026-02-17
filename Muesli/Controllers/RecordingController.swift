import CoreMedia
import Foundation
import os.lock
import os.log
import QuartzCore
import SwiftUI

/// Controller responsible for recording lifecycle management
/// Extracted from MuesliViewModel to improve separation of concerns
@Observable
@MainActor
final class RecordingController {
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "RecordingController")
    
    // MARK: - Dependencies
    
    private let audioCaptureService: any AudioCaptureServiceProtocol
    private let fileOutputService: FileOutputService
    private let transcriptionService: TranscriptionService
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let echoCancellationService: EchoCancellationServiceProtocol
    private let preferencesManager: PreferencesManager
    private let microphoneManager: MicrophoneManager
    private let exportService: ExportService
    
    /// Warning manager for propagating non-fatal errors to UI
    let warningManager: WarningManager
    
    // MARK: - State
    
    /// The currently recording session (only one can record at a time)
    private(set) var activeSession: RecordingSession?
    
    /// Whether to show the model error alert
    var showModelErrorAlert: Bool = false
    
    /// Session waiting for user response to model error
    var sessionPendingModelDecision: RecordingSession?
    
    /// Whether to show the meeting title prompt sheet
    var showTitlePromptSheet: Bool = false
    
    /// Session pending stop (waiting for title input)
    var pendingStopSession: RecordingSession?
    
    // MARK: - Audio Level Throttling
    
    /// Last time microphone level was updated (for throttling UI updates)
    private var lastMicLevelUpdate = Date.distantPast
    
    /// Last time system audio level was updated (for throttling UI updates)
    private var lastSystemLevelUpdate = Date.distantPast
    
    /// Minimum interval between audio level UI updates (~30fps)
    private let levelUpdateInterval: TimeInterval = AudioConfiguration.levelUpdateInterval
    
    /// Consecutive audio processing error counter
    private var audioErrorCounter: Int = 0
    
    /// Maximum consecutive audio errors before stopping recording
    private let maxConsecutiveAudioErrors: Int = AudioConfiguration.maxConsecutiveAudioErrors
    
    // MARK: - Thread-safe Mute State
    
    /// Microphone mute state (for synchronous access from audio callback)
    /// Uses OSAllocatedUnfairLock for proper thread-safe access
    private let isMicrophoneMutedLock = OSAllocatedUnfairLock(initialState: false)
    
    /// Thread-safe getter for audio callbacks (nonisolated)
    nonisolated var isMicrophoneMutedSafe: Bool {
        isMicrophoneMutedLock.withLock { $0 }
    }
    
    // MARK: - AEC Fallback State (Thread-safe)
    
    /// Whether AEC was disabled due to resampling fallback (sample rate mismatch)
    /// Thread-safe for access from audio callback
    private let aecDisabledDueToFallbackLock = OSAllocatedUnfairLock(initialState: false)
    
    /// Whether the resampling warning has been shown this recording session
    /// Thread-safe for access from audio callback
    private let hasShownResamplingWarningLock = OSAllocatedUnfairLock(initialState: false)
    
    // MARK: - Callbacks
    
    /// Called when a new recording session starts (for ViewModel state sync)
    var onSessionStarted: ((RecordingSession) -> Void)?
    
    /// Called when active session changes (for history manager updates)
    var onSessionCompleted: ((RecordingSession, URL?) -> Void)?
    
    /// Called when meeting history should be refreshed
    var onRefreshHistory: (() -> Void)?
    
    /// Called when the selected meeting should change
    var onSelectedMeetingChanged: ((MeetingHistoryItem?) -> Void)?
    
    /// Called when split view visibility should change
    var onSplitViewVisibilityChanged: ((Bool) -> Void)?
    
    // MARK: - Initialization
    
    init(
        audioCaptureService: any AudioCaptureServiceProtocol,
        fileOutputService: FileOutputService,
        transcriptionService: TranscriptionService,
        transcriptionCoordinator: TranscriptionCoordinator,
        echoCancellationService: EchoCancellationServiceProtocol,
        preferencesManager: PreferencesManager,
        microphoneManager: MicrophoneManager,
        exportService: ExportService,
        warningManager: WarningManager = WarningManager()
    ) {
        self.audioCaptureService = audioCaptureService
        self.fileOutputService = fileOutputService
        self.transcriptionService = transcriptionService
        self.transcriptionCoordinator = transcriptionCoordinator
        self.echoCancellationService = echoCancellationService
        self.preferencesManager = preferencesManager
        self.microphoneManager = microphoneManager
        self.exportService = exportService
        self.warningManager = warningManager
        
        // Wire up service warning callbacks
        wireWarningCallbacks()
        
        // Note: Audio buffer handler is set up in ensureAudioHandlersConfigured() before each recording
    }
    
    /// Wire up warning callbacks from all services to the warning manager
    private func wireWarningCallbacks() {
        // FileOutputService warnings
        fileOutputService.onWarning = { [weak self] message, details in
            Task { @MainActor in
                self?.warningManager.addWarning(.fileOutput, message: message, details: details, canRetry: false)
            }
        }
        
        // TranscriptionCoordinator warnings
        transcriptionCoordinator.onWarning = { [weak self] category, message, details, canRetry in
            Task { @MainActor in
                self?.warningManager.addWarning(category, message: message, details: details, canRetry: canRetry)
            }
        }
        
        // TranscriptionCoordinator warning dismissal (auto-dismiss when model ready)
        transcriptionCoordinator.onWarningDismissed = { [weak self] category in
            Task { @MainActor in
                self?.warningManager.dismissWarnings(for: category)
            }
        }
        
        // ExportService warnings
        exportService.onWarning = { [weak self] message, details in
            Task { @MainActor in
                self?.warningManager.addWarning(.export, message: message, details: details, canRetry: false)
            }
        }
        
        // TranscriptionService warnings (wired at start of recording)
        transcriptionService.setWarningHandler { [weak self] message, details in
            Task { @MainActor in
                self?.warningManager.addWarning(.transcription, message: message, details: details, canRetry: false)
            }
        }
    }
    
    deinit {
        logger.debug("Deallocating")
    }
    
    // MARK: - Audio Buffer Handler Setup
    
    /// Ensures audio handlers are configured before starting capture
    /// Must be called (and awaited) before audioCaptureService.startCapture()
    private func ensureAudioHandlersConfigured() async {
        let fileService = self.fileOutputService
        let transcriptService = self.transcriptionService
        let transcriptionCoordinator = self.transcriptionCoordinator
        let aecService = self.echoCancellationService
        let prefs = self.preferencesManager
        let audioCaptureServiceRef = self.audioCaptureService
        let warningMgr = self.warningManager
        
        // Capture locks directly to avoid @MainActor isolation in callback
        let muteLock = self.isMicrophoneMutedLock
        let aecLock = prefs.echoCancellationLock
        let aecDisabledLock = self.aecDisabledDueToFallbackLock
        let warningShownLock = self.hasShownResamplingWarningLock
        
        await audioCaptureServiceRef.setBufferHandler { [weak self] buffer, type in
                // Wrap entire handler in error handling for graceful degradation
                do {
                    // NO direct self capture in processing - only use captured locks and services (thread-safe)
                    let isMicMuted = muteLock.withLock { $0 }
                    let isAECEnabled = aecLock.withLock { $0 }
                    
                    switch type {
                    case .system:
                        try RecordingController.handleSystemAudioBuffer(
                            buffer,
                            isAECEnabled: isAECEnabled,
                            fileService: fileService,
                            transcriptionCoordinator: transcriptionCoordinator,
                            aecService: aecService
                        )
                        
                    case .microphone:
                        try RecordingController.handleMicrophoneAudioBuffer(
                            buffer,
                            isMicMuted: isMicMuted,
                            isAECEnabled: isAECEnabled,
                            fileService: fileService,
                            transcriptionCoordinator: transcriptionCoordinator,
                            aecService: aecService,
                            aecDisabledLock: aecDisabledLock,
                            warningShownLock: warningShownLock,
                            warningManager: warningMgr
                        )
                    }
                    
                    // Reset error counter on success
                    Task { @MainActor in
                        self?.audioErrorCounter = 0
                    }
                } catch {
                    // Log error but continue processing
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.logger.error("Audio buffer processing error: \(error)")
                        self.audioErrorCounter += 1
                        
                        // If too many consecutive errors, stop recording gracefully
                        if self.audioErrorCounter > self.maxConsecutiveAudioErrors {
                            self.logger.error(
                                "Too many consecutive audio errors (\(self.audioErrorCounter)), stopping recording"
                            )
                            
                            if let session = self.activeSession {
                                session.interruptionReason = "Audio processing error"
                                self.handleCaptureInterrupted(error: error)
                            }
                        }
                    }
                }
            }
            
            // Set up stream interruption handler
            await audioCaptureServiceRef.setInterruptedHandler { [weak self] error in
                Task { @MainActor in
                    self?.handleCaptureInterrupted(error: error)
                }
            }
            
        // Set up audio level handler
        await audioCaptureServiceRef.setLevelHandler { [weak self] level, type in
            Task { @MainActor in
                self?.updateAudioLevel(level, type: type)
            }
        }
        
        // Set up audio warning handler (for mic failures, system audio issues, etc.)
        await audioCaptureServiceRef.setWarningHandler { [weak self] category, message, details, canRetry in
            Task { @MainActor in
                self?.warningManager.addWarning(category, message: message, details: details, canRetry: canRetry)
            }
        }
    }
    
    // MARK: - Audio Buffer Processing Helpers
    
    // MARK: - AEC Diagnostic Counters
    
    // MARK: - Callback Performance Instrumentation
    
    /// Component timing breakdown for callback performance analysis
    private struct CallbackTiming: Sendable {
        var extract: TimeInterval = 0
        var aec: TimeInterval = 0
        var fileOutput: TimeInterval = 0
        var resample: TimeInterval = 0
        var transcription: TimeInterval = 0
        var total: TimeInterval = 0
    }
    
    /// Thread-safe timing state shared across audio callbacks
    private struct TimingState {
        var sysBufferDiagCount: Int = 0
        var systemTimings: [CallbackTiming] = []
        var micTimings: [CallbackTiming] = []
        var sysTimingFlushCount: Int = 0
        var micTimingFlushCount: Int = 0
        
        init() {
            systemTimings.reserveCapacity(200)
            micTimings.reserveCapacity(200)
        }
    }
    
    /// Lock to protect timing buffers and counters across audio threads
    private nonisolated(unsafe) static let timingStateLock = OSAllocatedUnfairLock(
        initialState: TimingState()
    )
    
    /// Compute timing statistics from buffer (min, p50, p95, max)
    private static nonisolated func computeTimingStats(_ timings: [CallbackTiming]) -> (
        total: (min: Double, p50: Double, p95: Double, max: Double),
        extract: Double, aec: Double, fileOutput: Double, resample: Double, transcription: Double
    ) {
        guard !timings.isEmpty else {
            return ((0, 0, 0, 0), 0, 0, 0, 0, 0)
        }
        
        let sorted = timings.map { $0.total }.sorted()
        let count = sorted.count
        
        let minVal = sorted.first! * 1000  // Convert to ms
        let maxVal = sorted.last! * 1000
        let p50 = sorted[count / 2] * 1000
        let p95Idx = Swift.min(count - 1, Int(Double(count) * 0.95))
        let p95 = sorted[p95Idx] * 1000
        
        // Average component times (in ms)
        let avgExtract = timings.map { $0.extract }.reduce(0, +) / Double(count) * 1000
        let avgAec = timings.map { $0.aec }.reduce(0, +) / Double(count) * 1000
        let avgFileOutput = timings.map { $0.fileOutput }.reduce(0, +) / Double(count) * 1000
        let avgResample = timings.map { $0.resample }.reduce(0, +) / Double(count) * 1000
        let avgTranscription = timings.map { $0.transcription }.reduce(0, +) / Double(count) * 1000
        
        return ((minVal, p50, p95, maxVal), avgExtract, avgAec, avgFileOutput, avgResample, avgTranscription)
    }
    
    /// Process system audio buffer (extracted for error handling)
    /// Note: Timestamp is extracted inside when needed for diagnostics. AEC uses sample-count sync.
    private static nonisolated func handleSystemAudioBuffer(
        _ buffer: CMSampleBuffer,
        isAECEnabled: Bool,
        fileService: FileOutputService,
        transcriptionCoordinator: TranscriptionCoordinator,
        aecService: EchoCancellationServiceProtocol
    ) throws {
        let callbackStart = CACurrentMediaTime()
        var timing = CallbackTiming()
        
        // AEC Diagnostic: Log system audio timestamps to verify SCK clock domain
        // Throttled to every 100th buffer to avoid performance impact
        let shouldLogSysDiag = timingStateLock.withLock { state -> Bool in
            state.sysBufferDiagCount += 1
            return state.sysBufferDiagCount % 100 == 0
        }
        if shouldLogSysDiag {
            let sckTimestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
            let wallClock = CACurrentMediaTime()
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "SYS: sck=\(String(format: "%.3f", sckTimestamp.seconds))s, " +
                    "wall=\(String(format: "%.3f", wallClock))s, " +
                    "delta=\(String(format: "%.3f", wallClock - sckTimestamp.seconds))s")
            }
        }
        
        // TIMING: Extract samples for AEC
        let extractStart = CACurrentMediaTime()
        var systemSamples: [Float]?
        if isAECEnabled {
            systemSamples = EchoCancellationServiceNLMS.extractSamples(from: buffer)
        }
        timing.extract = CACurrentMediaTime() - extractStart

        if shouldLogSysDiag {
            if let samples = systemSamples {
                let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
                let inputDb = rms > 0 ? 20 * log10(rms) : -100
                let sampleCount = samples.count
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "SYS_EXTRACT_RMS: samples=\(sampleCount), inputDb=\(String(format: "%.1f", inputDb))")
                }
            } else {
                Task {
                    await DiagnosticLogger.shared.log(.aec, "SYS_EXTRACT_FAILED")
                }
            }
        }
        
        // TIMING: Store system audio for AEC reference (if AEC enabled)
        let aecStart = CACurrentMediaTime()
        if isAECEnabled, let samples = systemSamples {
            aecService.storeSystemAudio(samples: samples)
        }
        timing.aec = CACurrentMediaTime() - aecStart
        
        // TIMING: Save to file (always)
        let fileStart = CACurrentMediaTime()
        fileService.appendAudioBuffer(buffer, type: .system)
        timing.fileOutput = CACurrentMediaTime() - fileStart
        
        // TIMING: Feed to transcription coordinator (handles buffering during model load)
        let resampleStart = CACurrentMediaTime()
        let samples = TranscriptionService.resampleToWhisperFormat(
            buffer,
            sourceSampleRate: 48000,
            sourceChannels: 2
        )
        timing.resample = CACurrentMediaTime() - resampleStart
        
        // TIMING: Transcription buffering
        let transcriptionStart = CACurrentMediaTime()
        if let samples = samples {
            Task { @MainActor in
                transcriptionCoordinator.bufferSystemAudio(samples)
            }
        }
        timing.transcription = CACurrentMediaTime() - transcriptionStart
        
        timing.total = CACurrentMediaTime() - callbackStart
        let timingSnapshot = timing
        
        // Collect timing (no allocation if within capacity)
        // Collect timing and flush every 100 buffers (~2 seconds) - NOT per-buffer
        let sysFlush = timingStateLock.withLock { state -> (shouldFlush: Bool, snapshot: [CallbackTiming]) in
            if state.systemTimings.count < 200 {
                state.systemTimings.append(timingSnapshot)
            }
            state.sysTimingFlushCount += 1
            if state.sysTimingFlushCount % 100 == 0 {
                let snapshot = state.systemTimings
                state.systemTimings.removeAll(keepingCapacity: true)
                return (true, snapshot)
            }
            return (false, [])
        }
        if sysFlush.shouldFlush {
            let stats = computeTimingStats(sysFlush.snapshot)
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "SYS_CALLBACK_TIMING: total(min=\(String(format: "%.2f", stats.total.min))ms, " +
                    "p50=\(String(format: "%.2f", stats.total.p50))ms, " +
                    "p95=\(String(format: "%.2f", stats.total.p95))ms, " +
                    "max=\(String(format: "%.2f", stats.total.max))ms) " +
                    "components(extract=\(String(format: "%.2f", stats.extract))ms, " +
                    "aec=\(String(format: "%.2f", stats.aec))ms, " +
                    "file=\(String(format: "%.2f", stats.fileOutput))ms, " +
                    "resample=\(String(format: "%.2f", stats.resample))ms, " +
                    "transcription=\(String(format: "%.2f", stats.transcription))ms)")
            }
        }
    }
    
    /// Process microphone audio buffer (extracted for error handling)
    private static nonisolated func handleMicrophoneAudioBuffer(
        _ buffer: CMSampleBuffer,
        isMicMuted: Bool,
        isAECEnabled: Bool,
        fileService: FileOutputService,
        transcriptionCoordinator: TranscriptionCoordinator,
        aecService: EchoCancellationServiceProtocol,
        aecDisabledLock: OSAllocatedUnfairLock<Bool>,
        warningShownLock: OSAllocatedUnfairLock<Bool>,
        warningManager: WarningManager
    ) throws {
        let callbackStart = CACurrentMediaTime()
        var timing = CallbackTiming()
        
        // Get the actual sample rate from the incoming buffer (may be 44100Hz, 48000Hz, etc.)
        var sourceSampleRate: Int = 48000  // default
        if let formatDesc = CMSampleBufferGetFormatDescription(buffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            sourceSampleRate = Int(asbd.pointee.mSampleRate)
        }
        
        // TIMING: Extract microphone samples at native rate (NOT necessarily 48kHz!)
        let extractStart = CACurrentMediaTime()
        let micSamplesNative = EchoCancellationServiceNLMS.extractSamples(from: buffer)
        timing.extract = CACurrentMediaTime() - extractStart
        
        guard let micSamplesNative = micSamplesNative else {
            // Fallback: save original buffer
            fileService.appendAudioBuffer(buffer, type: .microphone)
            return
        }
        
        // Track actual mic sample rate (may differ from 48kHz after fallback)
        var actualMicRate = 48000
        
        // Check if AEC was disabled due to earlier fallback
        let aecWasDisabled = aecDisabledLock.withLock { $0 }
        
        // CRITICAL: Resample mic to 48kHz BEFORE AEC for consistent alignment with system audio
        // System audio is always at 48kHz, so AEC must operate at 48kHz
        let micSamples48k: [Float]
        if sourceSampleRate != 48000 {
            if micSamplesNative.isEmpty {
                // Empty input buffer: don't treat as resample failure
                // Keep actualMicRate at 48kHz so AEC isn't disabled for the session
                micSamples48k = micSamplesNative
            } else {
                let resampled = EchoCancellationServiceNLMS.resampleFloat32Public(
                    samples: micSamplesNative,
                    sourceSampleRate: sourceSampleRate,
                    targetSampleRate: 48000
                )
                if resampled.isEmpty {
                    // Fallback: use native samples at original rate
                    micSamples48k = micSamplesNative
                    actualMicRate = sourceSampleRate  // Track that we're NOT at 48kHz
                    
                    // CRITICAL: Disable AEC since sample rates don't match (per r7x9 review)
                    // AEC expects both streams at 48kHz - mismatched rates cause:
                    // - Incorrect echo prediction (time alignment breaks)
                    // - Potential buffer overruns/underruns
                    // - Degraded or non-functional echo cancellation
                    //
                    // Atomic check-and-set to prevent TOCTOU race condition:
                    // Multiple audio callback threads could otherwise observe the same state
                    // and trigger duplicate warnings.
                    let shouldShowWarning = aecDisabledLock.withLock {
                        if !$0 {
                            $0 = true  // Atomically mark as disabled
                            return true  // First time - need to warn
                        }
                        return false
                    }
                    
                    if shouldShowWarning {
                        // Rate-limited warning (per 9ebe review) - show only once per session
                        // Atomic check-and-set to prevent duplicate warnings from concurrent threads
                        let shouldWarn = warningShownLock.withLock {
                            if !$0 {
                                $0 = true  // Atomically mark as warned
                                return true
                            }
                            return false
                        }
                        
                        if shouldWarn {
                            // Log to diagnostics
                            Task {
                                await DiagnosticLogger.shared.log(.aec,
                                    "RESAMPLE_FALLBACK: Disabling AEC - mic at \(sourceSampleRate)Hz, cannot resample to 48kHz")
                            }
                            
                            // Show user warning
                            Task { @MainActor in
                                warningManager.addWarning(
                                    .microphone,
                                    message: "Echo cancellation disabled",
                                    details: "Microphone resampling failed (using \(sourceSampleRate)Hz). Echo may be present in recording.",
                                    canRetry: false
                                )
                            }
                        }
                    }
                } else {
                    micSamples48k = resampled
                }
            }
        } else {
            micSamples48k = micSamplesNative
        }
        
        // Determine if AEC should be used for this buffer
        // AEC is disabled if: user disabled it, OR resampling failed (sample rate mismatch)
        let effectiveAECEnabled = isAECEnabled && !aecWasDisabled && actualMicRate == 48000
        
        // TIMING: Apply AEC at consistent 48kHz (system audio is always 48kHz)
        // Note: timestamp no longer passed - AEC uses sample-count synchronization
        let aecStart = CACurrentMediaTime()
        let processedSamples: [Float]
        if effectiveAECEnabled {
            processedSamples = aecService.processMicrophoneAudio(
                microphoneSamples: micSamples48k
            )
        } else {
            processedSamples = micSamples48k
        }
        timing.aec = CACurrentMediaTime() - aecStart
        
        // TIMING: Convert to stereo CMSampleBuffer for file output (FileOutputService expects 48kHz stereo)
        // Use actualMicRate for correct sample rate metadata
        let fileStart = CACurrentMediaTime()
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        if let processedBuffer = EchoCancellationServiceNLMS.createSampleBuffer(
            from: processedSamples,
            timestamp: timestamp,
            sourceSampleRate: actualMicRate,
            targetSampleRate: 48000
        ) {
            fileService.appendAudioBuffer(processedBuffer, type: .microphone)
        } else {
            // Fallback: save original if conversion fails
            fileService.appendAudioBuffer(buffer, type: .microphone)
        }
        timing.fileOutput = CACurrentMediaTime() - fileStart
        
        // Skip microphone audio for transcription if muted
        if isMicMuted {
            // Still record timing for muted case
            timing.total = CACurrentMediaTime() - callbackStart
            let timingSnapshot = timing
            let micFlush = timingStateLock.withLock { state -> (shouldFlush: Bool, snapshot: [CallbackTiming]) in
                if state.micTimings.count < 200 {
                    state.micTimings.append(timingSnapshot)
                }
                state.micTimingFlushCount += 1
                if state.micTimingFlushCount % 100 == 0 {
                    let snapshot = state.micTimings
                    state.micTimings.removeAll(keepingCapacity: true)
                    return (true, snapshot)
                }
                return (false, [])
            }
            if micFlush.shouldFlush {
                let stats = computeTimingStats(micFlush.snapshot)
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "MIC_CALLBACK_TIMING: total(min=\(String(format: "%.2f", stats.total.min))ms, " +
                        "p50=\(String(format: "%.2f", stats.total.p50))ms, " +
                        "p95=\(String(format: "%.2f", stats.total.p95))ms, " +
                        "max=\(String(format: "%.2f", stats.total.max))ms) " +
                        "components(extract=\(String(format: "%.2f", stats.extract))ms, " +
                        "aec=\(String(format: "%.2f", stats.aec))ms, " +
                        "file=\(String(format: "%.2f", stats.fileOutput))ms, " +
                        "resample=\(String(format: "%.2f", stats.resample))ms, " +
                        "transcription=\(String(format: "%.2f", stats.transcription))ms)")
                }
            }
            return
        }
        
        // TIMING: Feed to transcription coordinator (handles buffering during model load)
        // Use high-quality AVAudioConverter resampling from actualMicRate to 16kHz
        let resampleStart = CACurrentMediaTime()
        let resampled = TranscriptionService.resampleSamples(
            samples: processedSamples,
            sourceSampleRate: Double(actualMicRate),
            sourceChannels: 1,  // Mic is mono
            targetSampleRate: 16000,
            targetChannels: 1,
            isInterleaved: false
        )
        timing.resample = CACurrentMediaTime() - resampleStart
        
        // TIMING: Transcription buffering
        let transcriptionStart = CACurrentMediaTime()
        if let resampled = resampled {
            Task { @MainActor in
                transcriptionCoordinator.bufferMicrophoneAudio(resampled)
            }
        }
        timing.transcription = CACurrentMediaTime() - transcriptionStart
        
        timing.total = CACurrentMediaTime() - callbackStart
        let timingSnapshot = timing
        
        // Collect timing (no allocation if within capacity)
        let micFlush = timingStateLock.withLock { state -> (shouldFlush: Bool, snapshot: [CallbackTiming]) in
            if state.micTimings.count < 200 {
                state.micTimings.append(timingSnapshot)
            }
            state.micTimingFlushCount += 1
            if state.micTimingFlushCount % 100 == 0 {
                let snapshot = state.micTimings
                state.micTimings.removeAll(keepingCapacity: true)
                return (true, snapshot)
            }
            return (false, [])
        }
        if micFlush.shouldFlush {
            let stats = computeTimingStats(micFlush.snapshot)
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "MIC_CALLBACK_TIMING: total(min=\(String(format: "%.2f", stats.total.min))ms, " +
                    "p50=\(String(format: "%.2f", stats.total.p50))ms, " +
                    "p95=\(String(format: "%.2f", stats.total.p95))ms, " +
                    "max=\(String(format: "%.2f", stats.total.max))ms) " +
                    "components(extract=\(String(format: "%.2f", stats.extract))ms, " +
                    "aec=\(String(format: "%.2f", stats.aec))ms, " +
                    "file=\(String(format: "%.2f", stats.fileOutput))ms, " +
                    "resample=\(String(format: "%.2f", stats.resample))ms, " +
                    "transcription=\(String(format: "%.2f", stats.transcription))ms)")
            }
        }
    }
    
    // MARK: - Session Management
    
    /// Create a new recording session
    func createSession() -> RecordingSession {
        return RecordingSession()
    }
    
    /// Update audio level for the active session (throttled to ~30fps)
    private func updateAudioLevel(_ level: Float, type: AudioStreamType) {
        guard let session = activeSession else { return }
        let now = Date()
        
        switch type {
        case .microphone:
            guard now.timeIntervalSince(lastMicLevelUpdate) >= levelUpdateInterval else { return }
            lastMicLevelUpdate = now
            session.microphoneLevel = level
        case .system:
            guard now.timeIntervalSince(lastSystemLevelUpdate) >= levelUpdateInterval else { return }
            lastSystemLevelUpdate = now
            session.systemAudioLevel = level
        }
    }
    
    // MARK: - Recording Actions
    
    /// Quick start recording with all system audio (no app selection needed)
    func quickStartRecording() {
        guard activeSession == nil else {
            return  // Already recording
        }
        
        // Create a new session with no app filter (captures all system audio)
        let session = createSession()
        session.selectedApp = nil  // All system audio
        
        // Use saved microphone preference, or fall back to default if none set
        if microphoneManager.selectedDeviceID == nil {
            if let defaultMic = microphoneManager.currentDefaultDevice {
                microphoneManager.setSelectedDeviceID(defaultMic.id)
            }
        }
        
        // Ensure live transcription mode
        transcriptionCoordinator.setTranscriptionMode(.live)
        
        // Start recording
        startRecording(for: session)
    }
    
    /// Start recording for a session
    func startRecording(for session: RecordingSession) {
        // Only one session can record at a time
        guard activeSession == nil else {
            session.showError(.alreadyRecording)
            return
        }
        
        // Set activeSession immediately so UI shows recording view right away
        activeSession = session
        let mutedState = session.isMicrophoneMuted
        isMicrophoneMutedLock.withLock { $0 = mutedState }
        
        // Mark as initializing (loading model)
        session.isInitializing = true
        
        // Notify ViewModel that session started
        onSessionStarted?(session)
        
        Task {
            await startRecordingAsync(for: session)
        }
    }
    
    private func startRecordingAsync(for session: RecordingSession) async {
        // Clear any previous warnings at start of new recording
        warningManager.clearAll()
        
        // Reset AEC fallback state for new recording session
        aecDisabledDueToFallbackLock.withLock { $0 = false }
        hasShownResamplingWarningLock.withLock { $0 = false }
        
        // Reset timing diagnostics for new recording session
        // This ensures each recording logs timing stats every ~2 seconds from the start
        Self.timingStateLock.withLock { state in
            state.sysBufferDiagCount = 0
            state.sysTimingFlushCount = 0
            state.micTimingFlushCount = 0
            state.systemTimings.removeAll(keepingCapacity: true)
            state.micTimings.removeAll(keepingCapacity: true)
        }
        
        do {
            // Start file output FIRST
            session.outputDirectory = try fileOutputService.startWriting()
            
            // Configure microphone preference before starting capture
            // Pass selected mic device to AudioCaptureService for AVAudioEngine capture
            let selectedMicID = microphoneManager.selectedDeviceID
            await audioCaptureService.setMicrophoneDevice(selectedMicID)
            
            // CRITICAL: Ensure audio handlers are configured BEFORE starting capture
            // This fixes the race condition where handlers weren't set when capture started
            
            await ensureAudioHandlersConfigured()
            
            // Start audio capture IMMEDIATELY (before model check)
            if let app = session.selectedApp {
                try await audioCaptureService.startCapture(forBundleIdentifier: app.bundleIdentifier)
            } else {
                try await audioCaptureService.startCapture()
            }
            
            // Audio is now flowing and being saved to disk ✅
            session.recordingStartTime = Date()
            session.state = .recording
            session.startDisplayTimer()
            echoCancellationService.reset()
            echoCancellationService.startDriftMonitoring()
            
            // Mark initialization as completing audio setup
            session.isInitializing = false
            
            // NOW try transcription (async, non-blocking)
            Task {
                await prepareTranscriptionAsync(for: session)
            }
        } catch let error as AudioCaptureError {
            handleCaptureError(error, for: session)
        } catch {
            handleGenericError(error, for: session)
        }
    }
    
    private func prepareTranscriptionAsync(for session: RecordingSession) async {
        // Set modelLoading indicator
        session.isModelLoading = true
        
        transcriptionCoordinator.resetForNewRecording()
        let modelState = await transcriptionCoordinator.prepareModel()
        
        switch modelState {
        case .notAvailable:
            session.isModelLoading = false
            session.isRecordingOnly = true
            // Continue recording without transcription
            
        case .loading:
            // Keep indicator showing, coordinator buffers audio
            break
            
        case .ready:
            session.isModelLoading = false
            transcriptionCoordinator.setTranscriptHandler { [weak session] segment in
                Task { @MainActor in
                    session?.appendTranscriptSegment(segment)
                }
            }
            transcriptionCoordinator.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
            
        case .failed(let error):
            session.isModelLoading = false
            session.isRecordingOnly = true
            // Log error but continue recording audio
            logger.error("Model loading failed: \(error), continuing audio-only recording")
            
            // Propagate warning to UI
            let details = """
                Transcription model failed to load.
                Error: \(error.localizedDescription)
                
                Recording will continue without transcription.
                You can re-transcribe later from the saved audio files.
                """
            warningManager.addWarning(.modelLoading, message: "Transcription unavailable", details: details, canRetry: false)
        }
    }
    
    private func handleCaptureError(_ error: AudioCaptureError, for session: RecordingSession) {
        let muesliError: MuesliError
        switch error {
        case .noContentToCapture:
            muesliError = .noAudioContent
        case .permissionDenied, .streamStartFailed:
            muesliError = .screenRecordingDenied
        default:
            muesliError = .captureStartFailed(underlying: error)
        }
        
        // Add context for specific cases
        if case .noContentToCapture = error, let app = session.selectedApp {
            session.showErrorMessage("Could not find \(app.name). Make sure it's running and has a window open.")
        } else {
            session.showError(muesliError)
        }
        cleanupFailedSession(session)
    }
    
    private func handleGenericError(_ error: Error, for session: RecordingSession) {
        let errorMsg = error.localizedDescription
        
        let muesliError: MuesliError
        if errorMsg.contains("TCC") || errorMsg.contains("declined") || errorMsg.contains("permission") {
            muesliError = .screenRecordingDenied
        } else {
            muesliError = .captureStartFailed(underlying: error)
        }
        session.showError(muesliError)
        cleanupFailedSession(session)
    }
    
    private func cleanupFailedSession(_ session: RecordingSession) {
        session.isInitializing = false
        session.state = .idle
        activeSession = nil
        resetMuteState()
        
        if fileOutputService.isWriting {
            Task {
                _ = try? await fileOutputService.stopWriting()
            }
        }
    }
    
    /// Stop recording for a session
    func stopRecording(for session: RecordingSession) {
        guard session.id == activeSession?.id else { return }
        
        // Check if title is empty - show prompt sheet
        if session.meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingStopSession = session
            showTitlePromptSheet = true
            return
        }
        
        // Title is set, proceed with stop
        performStopRecording(for: session)
    }
    
    /// Called after title prompt is confirmed
    func confirmStopRecording() {
        guard let session = pendingStopSession else { return }
        pendingStopSession = nil
        performStopRecording(for: session)
    }
    
    /// Discard the current recording without saving
    func discardRecording() {
        guard let session = pendingStopSession ?? activeSession else { return }
        pendingStopSession = nil
        showTitlePromptSheet = false
        
        Task {
            await discardRecordingAsync(for: session)
        }
    }
    
    private func discardRecordingAsync(for session: RecordingSession) async {
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            try await audioCaptureService.stopCapture()
            echoCancellationService.reset()
            await transcriptionCoordinator.stopTranscription()
            let directory = try? await fileOutputService.stopWriting()
            
            if let directory = directory {
                try? FileManager.default.removeItem(at: directory)
            }
        } catch {
            // Errors during discard can be ignored
        }
        
        session.state = .idle
        activeSession = nil
        resetMuteState()
    }
    
    private func performStopRecording(for session: RecordingSession) {
        Task {
            await stopRecordingAsync(for: session)
        }
    }
    
    private func stopRecordingAsync(for session: RecordingSession) async {
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            try await audioCaptureService.stopCapture()
            echoCancellationService.reset()
            await transcriptionCoordinator.stopTranscription()
            
            // Stop file writing and get output directory
            let directory: URL
            do {
                directory = try await fileOutputService.stopWriting()
            } catch {
                session.showError(.outputDirectoryCreationFailed)
                session.state = .completed
                activeSession = nil
                resetMuteState()
                return
            }
            
            session.outputDirectory = directory
            
            // Handle post-processing transcription if needed
            if transcriptionCoordinator.transcriptionMode == .postProcessing {
                await handlePostProcessingTranscription(for: session, directory: directory)
            }
            
            // Finalize transcript
            session.finalizeTranscript()
            
            // Save transcript blocks to file
            do {
                try fileOutputService.saveTranscriptBlocks(
                    session.transcriptBlocks,
                    title: session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle,
                    date: session.recordingStartTime ?? Date(),
                    to: directory,
                    filename: nil  // Use default "transcript.md"
                )
            } catch {
                session.showError(.transcriptSaveFailed(underlying: error))
                // Continue - we have audio files even if transcript save failed
            }
            
            // Check if we have audio but no transcript (model wasn't ready during recording)
            // If so, auto-trigger reprocessing once the model becomes ready
            let hasAudioFiles = FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio.caf").path) ||
                                FileManager.default.fileExists(atPath: directory.appendingPathComponent("microphone.caf").path)
            let hasEmptyTranscript = session.transcriptBlocks.isEmpty
            
            if hasAudioFiles && hasEmptyTranscript {
                if let meeting = createMeetingHistoryItem(from: directory) {
                    logger.info("Recording has audio but empty transcript, auto-triggering reprocessing")
                    transcriptionCoordinator.autoReprocessWhenReady(meeting: meeting)
                }
            }
            
            // Export meeting to exports directory (if enabled)
            await exportMeetingIfEnabled(directory: directory)
        } catch {
            session.showError(.transcriptSaveFailed(underlying: error))
        }
        
        // Mark session as completed
        session.state = .completed
        session.canResume = true
        
        // Notify completion
        onSessionCompleted?(session, session.outputDirectory)
        onRefreshHistory?()
        
        activeSession = nil
        resetMuteState()
    }
    
    /// Export meeting to exports directory if export is enabled
    private func exportMeetingIfEnabled(directory: URL) async {
        // Check if export is enabled in preferences
        guard preferencesManager.exportEnabled else {
            logger.debug("Export disabled, skipping export")
            return
        }
        
        // Load the meeting from history to get full metadata
        // We need to create a temporary MeetingHistoryItem from the just-saved directory
        guard let meeting = createMeetingHistoryItem(from: directory) else {
            logger.error("Failed to create meeting item for export")
            return
        }
        
        do {
            try await exportService.exportMeeting(meeting)
            
            // Also update the manifest with all meetings
            // Get all meetings from history
            let meetingHistoryService = MeetingHistoryService()
            let allMeetings = meetingHistoryService.discoverMeetings()
            try exportService.generateManifest(for: allMeetings)
            
            logger.info("Successfully exported meeting: \(meeting.title)")
        } catch {
            logger.error("Failed to export meeting: \(error.localizedDescription)")
            // Don't show error to user - export failures are non-critical
        }
    }
    
    /// Create a MeetingHistoryItem from a directory URL (for immediate export after recording)
    private func createMeetingHistoryItem(from directory: URL) -> MeetingHistoryItem? {
        let fileManager = FileManager.default
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        
        guard fileManager.fileExists(atPath: transcriptURL.path) else {
            return nil
        }
        
        // Parse date from folder name: YYYY-MM-DD_HH-MM_[UUID]
        let folderName = directory.lastPathComponent
        let components = folderName.components(separatedBy: "_")
        var date = Date()
        
        if components.count >= 2 {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm"
            if let parsed = dateFormatter.date(from: "\(components[0])_\(components[1])") {
                date = parsed
            }
        }
        
        // Read transcript to get title
        var title = "Meeting"
        if let content = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            if let firstLine = lines.first, firstLine.hasPrefix("# ") {
                title = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if title.isEmpty {
                    title = "Meeting"
                }
            }
        }
        
        // Check for audio files
        let audioURL = directory.appendingPathComponent("audio.caf")
        let micURL = directory.appendingPathComponent("microphone.caf")
        let hasAudio = fileManager.fileExists(atPath: audioURL.path)
        let hasMicrophone = fileManager.fileExists(atPath: micURL.path)
        
        // Extract UUID from folder name
        let id = components.count >= 3 ? UUID(uuidString: components[2]) ?? UUID() : UUID()
        
        return MeetingHistoryItem(
            id: id,
            title: title,
            date: date,
            directory: directory,
            hasAudio: hasAudio,
            hasMicrophone: hasMicrophone
        )
    }
    
    private func handlePostProcessingTranscription(for session: RecordingSession, directory: URL) async {
        session.transcriptText = "Processing transcript..."
        
        let systemAudioURL = directory.appendingPathComponent("audio.caf")
        let micAudioURL = directory.appendingPathComponent("microphone.caf")
        
        do {
            session.transcriptText = ""
            try await transcriptionService.transcribePostProcessing(
                systemAudioURL: FileManager.default.fileExists(atPath: systemAudioURL.path) ? systemAudioURL : nil,
                micAudioURL: FileManager.default.fileExists(atPath: micAudioURL.path) ? micAudioURL : nil,
                startTime: session.recordingStartTime ?? Date()
            )
        } catch {
            session.showError(.postProcessingFailed(underlying: error))
        }
    }
    
    // MARK: - Model Error Handling
    
    func startRecordingWithoutTranscription() {
        guard let session = sessionPendingModelDecision else { return }
        sessionPendingModelDecision = nil
        showModelErrorAlert = false
        
        // Recording is already in progress (audio capture started), just dismiss the alert
        // The session will continue recording without transcription
        // Mark session as recording-only mode
        session.isRecordingOnly = true
    }
    
    func cancelRecordingDueToModelError() {
        sessionPendingModelDecision = nil
        showModelErrorAlert = false
    }
    
    // MARK: - Capture Interruption
    
    private func handleCaptureInterrupted(error: Error?) {
        guard let session = activeSession else { return }
        
        session.wasInterrupted = true
        session.interruptionReason = "The captured app was closed"
        
        Task {
            await stopRecordingAfterInterruption(for: session)
        }
    }
    
    private func stopRecordingAfterInterruption(for session: RecordingSession) async {
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            echoCancellationService.reset()
            await transcriptionCoordinator.stopTranscription()
            
            // Stop file writing and get output directory
            let directory: URL
            do {
                directory = try await fileOutputService.stopWriting()
            } catch {
                session.state = .completed
                session.showError(.outputDirectoryCreationFailed)
                activeSession = nil
                resetMuteState()
                return
            }
            
            session.outputDirectory = directory
            
            if transcriptionCoordinator.transcriptionMode == .postProcessing {
                await handlePostProcessingTranscription(for: session, directory: directory)
            }
            
            session.finalizeTranscript()
            
            // Save transcript blocks
            do {
                try fileOutputService.saveTranscriptBlocks(
                    session.transcriptBlocks,
                    title: session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle,
                    date: session.recordingStartTime ?? Date(),
                    to: directory,
                    filename: nil
                )
            } catch {
                session.showError(.transcriptSaveFailed(underlying: error))
                // Continue - we have audio files even if transcript save failed
            }
        } catch {
            session.showError(.transcriptSaveFailed(underlying: error))
        }
        
        session.state = .completed
        // Show success message with interruption reason
        if let reason = session.interruptionReason {
            session.showErrorMessage("Recording saved. \(reason)")
        } else {
            session.showErrorMessage("Recording saved. The stream was interrupted.")
        }
        
        onRefreshHistory?()
        activeSession = nil
        resetMuteState()
    }
    
    // MARK: - Resume Recording
    
    func resumeRecording(for meeting: MeetingHistoryItem) {
        guard meeting.canResume else { return }
        guard activeSession == nil else { return }
        
        Task {
            await resumeRecordingAsync(for: meeting)
        }
    }
    
    private func resumeRecordingAsync(for meeting: MeetingHistoryItem) async {
        do {
            // Reset retry budget for a fresh recording session
            transcriptionCoordinator.resetForNewRecording()
            
            let modelState = await transcriptionCoordinator.prepareModel()
            
            switch modelState {
            case .notAvailable:
                logger.error("Cannot resume: No transcription model available")
                warningManager.addWarning(
                    .modelLoading,
                    message: "No transcription model available",
                    details: "Please download a transcription model from Preferences before resuming recording.",
                    canRetry: false
                )
                return
            case .failed(let error):
                logger.error("Cannot resume: Model failed to load: \(error)")
                warningManager.addWarning(
                    .modelLoading,
                    message: "Model failed to load",
                    details: "Error: \(error.localizedDescription)\n\nPlease try restarting the app or re-downloading the model from Preferences.",
                    canRetry: false
                )
                return
            case .loading, .ready:
                break
            }
            
            let session = createSession()
            session.parentMeeting = meeting
            session.resumeCount = meeting.segmentCount
            session.segmentNumber = meeting.segmentCount + 1
            session.meetingTitle = meeting.title
            session.selectedApp = nil
            
            activeSession = session
            let mutedState = session.isMicrophoneMuted
            isMicrophoneMutedLock.withLock { $0 = mutedState }
            
            // Notify ViewModel that session started
            onSessionStarted?(session)
            onSplitViewVisibilityChanged?(true)
            
        transcriptionCoordinator.setTranscriptHandler { [weak session] (segment: TranscriptionService.TranscriptSegment) in
            Task { @MainActor in
                guard let session = session else { return }
                session.appendTranscriptSegment(segment)
            }
        }
            
            session.outputDirectory = try fileOutputService.resumeWriting(
                to: meeting.directory,
                segmentNumber: session.segmentNumber
            )
            
            // Pass selected mic device to AudioCaptureService for AVAudioEngine capture
            let selectedMicID = microphoneManager.selectedDeviceID
            await audioCaptureService.setMicrophoneDevice(selectedMicID)
            
            // CRITICAL: Ensure audio handlers are configured BEFORE starting capture
            await ensureAudioHandlersConfigured()
            
            try await audioCaptureService.startCapture()
            
            session.isInitializing = false
            session.state = .recording
            session.recordingStartTime = Date()
            session.transcriptText = ""
            session.transcriptBlocks = []
            session.resetTranscript()
            session.startDisplayTimer()
            
            transcriptionCoordinator.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
        } catch let error as AudioCaptureError {
            if let session = activeSession {
                handleCaptureError(error, for: session)
            }
        } catch {
            if let session = activeSession {
                handleGenericError(error, for: session)
            }
        }
    }
    
    // MARK: - Re-transcription
    
    func retranscribeWithPostProcessing(for session: RecordingSession) {
        guard session.canRetranscribe, !session.isRetranscribing else { return }
        
        Task {
            await retranscribeWithPostProcessingAsync(for: session)
        }
    }
    
    private func retranscribeWithPostProcessingAsync(for session: RecordingSession) async {
        guard let directory = session.outputDirectory else {
            session.showError(.meetingDirectoryNotFound)
            return
        }
        
        session.isRetranscribing = true
        
        // Reset retry budget for a fresh model load attempt
        transcriptionCoordinator.resetForNewRecording()
        
        let modelState = await transcriptionCoordinator.prepareModel()
        
        switch modelState {
        case .notAvailable:
            session.isRetranscribing = false
            session.showError(.modelNotFound)
            return
        case .failed(let error):
            session.isRetranscribing = false
            session.showError(.modelLoadFailed(underlying: error))
            return
        case .loading, .ready:
            break
        }
        
        let previousMode = transcriptionCoordinator.transcriptionMode
        transcriptionCoordinator.setTranscriptionMode(.postProcessing)
        
        transcriptionCoordinator.setTranscriptHandler { [weak session] (segment: TranscriptionService.TranscriptSegment) in
            Task { @MainActor in
                guard let session = session else { return }
                session.appendTranscriptSegment(segment)
            }
        }
        
        let systemAudioURL = directory.appendingPathComponent("audio.caf")
        let micAudioURL = directory.appendingPathComponent("microphone.caf")
        
        do {
            session.resetTranscript()
            
            try await transcriptionService.transcribePostProcessing(
                systemAudioURL: FileManager.default.fileExists(atPath: systemAudioURL.path) ? systemAudioURL : nil,
                micAudioURL: FileManager.default.fileExists(atPath: micAudioURL.path) ? micAudioURL : nil,
                startTime: session.recordingStartTime ?? Date()
            )
            
            session.finalizeTranscript()
            
            let title = session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle
            do {
                try fileOutputService.saveTranscriptBlocks(
                    session.transcriptBlocks,
                    title: title,
                    date: session.recordingStartTime ?? Date(),
                    to: directory,
                    filename: nil  // Use default "transcript.md"
                )
            } catch {
                session.showError(.transcriptSaveFailed(underlying: error))
                // Continue - retranscription succeeded even if save failed
            }
        } catch {
            session.showError(.postProcessingFailed(underlying: error))
        }
        
        transcriptionCoordinator.setTranscriptionMode(previousMode)
        session.isRetranscribing = false
    }
    
    // MARK: - Microphone Mute
    
    func toggleMicrophoneMute() {
        guard let session = activeSession else { return }
        session.isMicrophoneMuted.toggle()
        let mutedState = session.isMicrophoneMuted
        isMicrophoneMutedLock.withLock { $0 = mutedState }
    }
    
    private func resetMuteState() {
        isMicrophoneMutedLock.withLock { $0 = false }
    }

    // MARK: - Microphone Device Selection
    
    func handleMicrophoneDeviceChange(_ deviceID: String?) {
        guard let session = activeSession, session.isRecording else { return }
        
        Task {
            await audioCaptureService.setMicrophoneDevice(deviceID)
        }
    }
}
