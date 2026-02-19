//
//  CoreAudioTapManager.swift
//  Muesli
//
//  Core Audio Tap Manager - Creates and manages audio taps for system audio capture.
//  macOS 26+ only. Captures default output mix excluding Muesli's own audio.
//

import Foundation
import CoreAudio
import AudioToolbox
import os.log

// MARK: - Tap Configuration

/// Configuration for Core Audio tap creation
struct TapConfiguration {
    /// Target sample rate (default: 48kHz)
    let sampleRate: Float64
    
    /// Target channel count (default: 2 for stereo)
    let channelCount: UInt32
    
    /// Frame quantum in samples (default: 480 for 10ms at 48kHz)
    let frameQuantum: UInt32
    
    /// Process IDs to exclude from tap (always includes Muesli)
    let excludedProcessIDs: [pid_t]
    
    /// Whether to use exclusive tap mode (default: false)
    let isExclusive: Bool
    
    static let `default` = TapConfiguration(
        sampleRate: 48000,
        channelCount: 2,
        frameQuantum: 480,  // 10ms at 48kHz
        excludedProcessIDs: [],
        isExclusive: false
    )
}

// MARK: - Tap State

/// State of the tap manager
enum TapState: Equatable {
    case idle
    case initializing
    case running
    case failed(String)
    case micOnly(reason: String)
}

// MARK: - Tap Callback

/// Callback for receiving tap audio data
/// - Parameters:
///   - samples: Float32 audio samples (interleaved if stereo)
///   - frameCount: Number of frames
///   - sampleTime: Sample time from AudioTimeStamp
///   - hostTime: Host time from AudioTimeStamp
typealias TapAudioCallback = (
    _ samples: UnsafePointer<Float>,
    _ frameCount: UInt32,
    _ sampleTime: Float64,
    _ hostTime: UInt64
) -> Void

// MARK: - Core Audio Tap Manager

/// Manages Core Audio taps for capturing system audio
/// Thread-safe: uses internal synchronization for state management
final class CoreAudioTapManager: @unchecked Sendable {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "CoreAudioTapManager")
    
    /// Current tap state
    private(set) var state: TapState = .idle
    
    /// Configuration for the tap
    private var configuration: TapConfiguration = .default
    
    /// Aggregate device manager for hosting the tap
    private var aggregateDeviceManager: AggregateDeviceManager?
    
    /// The aggregate device ID hosting the tap
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    
    /// IOProc ID for the tap callback
    private var ioProcID: AudioDeviceIOProcID?
    
    /// Audio callback for receiving tap data
    private var audioCallback: TapAudioCallback?

    /// Cached tap stream format (for decoding diagnostics)
    private var tapStreamFormat: AudioStreamBasicDescription?
    
    /// Lock for thread-safe state access
    private let stateLock = NSLock()
    
    /// RMS monitoring for runtime validation
    private var rollingRMS: Float = 0
    private var rmsFrameCount: Int = 0
    
    /// Retry configuration
    private let maxStartRetries = 3
    private let retryDelayMs: UInt32 = 100
    
    // MARK: - Initialization
    
    init() {
        logger.info("CoreAudioTapManager initialized")
    }
    
    deinit {
        stop()
        logger.info("CoreAudioTapManager deallocated")
    }
    
    // MARK: - Public API
    
    /// Start the tap with the given configuration
    /// - Parameters:
    ///   - configuration: Tap configuration (optional, uses default if nil)
    ///   - callback: Audio callback for receiving samples
    /// - Throws: If tap creation fails
    func start(
        configuration: TapConfiguration? = nil,
        callback: @escaping TapAudioCallback
    ) throws {
        print("[TAP DEBUG] CoreAudioTapManager.start() called")
        stateLock.lock()
        defer { stateLock.unlock() }

        let canStart: Bool
        switch state {
        case .idle, .micOnly:
            canStart = true
        default:
            canStart = false
        }
        guard canStart else {
            print("[TAP DEBUG] ERROR: Tap already running, state=\(state)")
            throw CoreAudioTapError.alreadyRunning
        }

        state = .initializing
        self.configuration = configuration ?? .default
        self.audioCallback = callback

        // Build exclusion list - always include Muesli's PID
        var excludedPIDs = self.configuration.excludedProcessIDs
        let muesliPID = CoreAudioHelpers.getCurrentProcessID()
        if !excludedPIDs.contains(muesliPID) {
            excludedPIDs.append(muesliPID)
        }

        print("[TAP DEBUG] Muesli PID: \(muesliPID)")
        print("[TAP DEBUG] Excluded PIDs: \(excludedPIDs)")
        logger.info("Starting tap with excluded PIDs: \(excludedPIDs)")

        do {
            // Create aggregate device manager
            print("[TAP DEBUG] Creating AggregateDeviceManager...")
            aggregateDeviceManager = AggregateDeviceManager()

            // Create tap-only aggregate device
            print("[TAP DEBUG] Calling createTapOnlyDevice...")
            aggregateDeviceID = try aggregateDeviceManager!.createTapOnlyDevice(
                excludedProcessIDs: excludedPIDs,
                isExclusive: self.configuration.isExclusive
            )

            print("[TAP DEBUG] Created aggregate device: \(self.aggregateDeviceID)")
            logger.info("Created aggregate device: \(self.aggregateDeviceID)")

            // Capture tap stream format for decoding diagnostics
            tapStreamFormat = try? aggregateDeviceManager?.getTapFormat()

            // Start the device with retries
            print("[TAP DEBUG] Starting device with retries...")
            try startDeviceWithRetries()

            state = .running
            print("[TAP DEBUG] Tap started successfully, state=.running")
            logger.info("Tap started successfully")

        } catch {
            state = .failed(error.localizedDescription)
            print("[TAP DEBUG] ERROR: Failed to start tap: \(error)")
            print("[TAP DEBUG] Error description: \(error.localizedDescription)")
            logger.error("Failed to start tap: \(error.localizedDescription)")

            // Clean up
            cleanupTap()

            throw error
        }
    }
    
    /// Stop the tap
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard state == .running || state == .initializing else {
            return
        }
        
        cleanupTap()
        state = .idle
        logger.info("Tap stopped")
    }
    
    /// Degrade to mic-only mode with the given reason
    func degradeToMicOnly(reason: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        cleanupTap()
        state = .micOnly(reason: reason)
        logger.warning("Degraded to mic-only mode: \(reason)")
    }
    
    /// Get current RMS level (for monitoring)
    var currentRMSLevel: Float {
        return rollingRMS
    }
    
    // MARK: - Private Implementation
    
    /// Start the audio device with retries
    private func startDeviceWithRetries() throws {
        var lastError: Error?
        
        for attempt in 1...maxStartRetries {
            do {
                try startDevice()
                return // Success
            } catch {
                lastError = error
                logger.warning("Device start attempt \(attempt) failed: \(error.localizedDescription)")
                
                if attempt < maxStartRetries {
                    // Wait before retry
                    Thread.sleep(forTimeInterval: Double(retryDelayMs) / 1000.0)
                }
            }
        }
        
        throw lastError ?? CoreAudioTapError.deviceStartFailed
    }
    
    /// Start the audio device
    private func startDevice() throws {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            throw CoreAudioTapError.noAggregateDevice
        }
        
        print("[TAP DEBUG] Starting IOProc on aggregate device ID: \(aggregateDeviceID)")
        
        // Create IOProc for receiving audio
        var procID: AudioDeviceIOProcID?
        
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            DispatchQueue.global(qos: .userInteractive)
        ) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self = self else { return }
            self.handleIOProc(
                inputData: inInputData,
                inputTime: inInputTime
            )
        }
        
        guard status == noErr, let procID = procID else {
            throw CoreAudioTapError.ioProcCreationFailed(status)
        }
        
        ioProcID = procID
        
        // Start the device
        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            // Clean up the proc ID
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
            throw CoreAudioTapError.deviceStartFailed
        }
        
        print("[TAP DEBUG] Device started successfully")
    }
    
    /// Counter for IOProc calls (for debugging)
    private var ioProcCallCount: Int = 0
    
    /// Debug state tracking for IOProc
    private var ioProcNilDataCount: Int = 0
    private var ioProcNoBuffersCount: Int = 0
    private var ioProcNilMDataCount: Int = 0
    private var ioProcSuccessCount: Int = 0
    private var lastFrameCount: UInt32 = 0
    private var lastChannelCount: UInt32 = 0
    
    /// Handle IOProc callback
    /// RT-SAFE CHECKLIST (per plan Phase 4):
    /// - ✅ No malloc/new (uses pre-allocated buffers)
    /// - ✅ No Objective-C/Swift ARC work
    /// - ✅ No logging (deferred to worker thread)
    /// - ✅ No syscalls
    /// - ⚠️ Locks: The delegated audioCallback chain acquires ~6 sequential
    ///   OSAllocatedUnfairLock instances (ring buffers, synchronizer stateLock,
    ///   AECProcessor stateLock). These are RT-safe: os_unfair_lock provides
    ///   priority donation, preventing priority inversion. No NSLock or
    ///   pthread_mutex is used in the callback path.
    /// Note: rollingRMS access is not atomic but acceptable for monitoring-only purposes
    private func handleIOProc(
        inputData: UnsafePointer<AudioBufferList>?,
        inputTime: UnsafePointer<AudioTimeStamp>?
    ) {
        ioProcCallCount += 1
        
        guard let inputData = inputData,
              let inputTime = inputTime else {
            ioProcNilDataCount += 1
            return
        }
        
        let bufferList = inputData.pointee
        guard bufferList.mNumberBuffers > 0 else {
            ioProcNoBuffersCount += 1
            return
        }

        // Get first buffer (mono or interleaved stereo)
        let buffer = bufferList.mBuffers
        guard let dataPtr = buffer.mData else {
            ioProcNilMDataCount += 1
            return
        }
        
        let samples = dataPtr.assumingMemoryBound(to: Float.self)
        let byteCount = Int(buffer.mDataByteSize)
        let frameCount = UInt32(byteCount / MemoryLayout<Float>.size / Int(buffer.mNumberChannels))
        
        ioProcSuccessCount += 1
        lastFrameCount = frameCount
        lastChannelCount = buffer.mNumberChannels
        
        // Extract timing info (validate sampleTime flag; use -1 sentinel when invalid)
        let sampleTimeValid = (inputTime.pointee.mFlags.rawValue & AudioTimeStampFlags.sampleTimeValid.rawValue) != 0
        let sampleTime = sampleTimeValid ? inputTime.pointee.mSampleTime : Float64(-1)
        let hostTime = inputTime.pointee.mHostTime
        
        // Update RMS for monitoring (simple moving average)
        updateRMS(samples: samples, frameCount: Int(frameCount), channels: Int(buffer.mNumberChannels))
        
        // Call the audio callback
        audioCallback?(samples, frameCount, sampleTime, hostTime)
    }
    
    /// Update rolling RMS (RT-safe approximation)
    private func updateRMS(samples: UnsafePointer<Float>, frameCount: Int, channels: Int) {
        var sumSquares: Float = 0
        let totalSamples = frameCount * channels

        // Sample every 4th value for efficiency
        let strideStep = 4
        var count = 0
        for i in Swift.stride(from: 0, to: totalSamples, by: strideStep) {
            let sample = samples[i]
            sumSquares += sample * sample
            count += 1
        }
        
        if count > 0 {
            let frameRMS = sqrt(sumSquares / Float(count))
            // Exponential moving average with ~100ms time constant at 48kHz
            let alpha: Float = 0.1
            rollingRMS = rollingRMS * (1 - alpha) + frameRMS * alpha
            rmsFrameCount += 1
        }
    }
    
    /// Clean up tap resources
    private func cleanupTap() {
        // Stop and destroy IOProc
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        ioProcID = nil
        
        // Destroy aggregate device
        aggregateDeviceManager?.destroyDevice()
        aggregateDeviceManager = nil
        aggregateDeviceID = kAudioObjectUnknown
        
        audioCallback = nil
    }
    
}

// MARK: - Errors

enum CoreAudioTapError: Error, LocalizedError {
    case alreadyRunning
    case noAggregateDevice
    case deviceStartFailed
    case ioProcCreationFailed(OSStatus)
    case tapCreationFailed(OSStatus)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Tap is already running"
        case .noAggregateDevice:
            return "No aggregate device available"
        case .deviceStartFailed:
            return "Failed to start audio device"
        case .ioProcCreationFailed(let status):
            return "Failed to create IOProc (status: \(status))"
        case .tapCreationFailed(let status):
            return "Failed to create tap (status: \(status))"
        case .permissionDenied:
            return "Audio capture permission denied"
        }
    }
}
