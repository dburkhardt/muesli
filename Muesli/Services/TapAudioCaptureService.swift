//
//  TapAudioCaptureService.swift
//  Muesli
//
//  Core Audio Tap-based audio capture service.
//  Orchestrates: TapManager -> Synchronizer -> AEC -> Worker -> Output
//

import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os.lock
import os.log
import QuartzCore

// MARK: - Frame Metadata Ring

/// Fixed-capacity ring for per-frame timestamp metadata.
/// Stores one entry per 10ms frame, with overwrite-on-overflow behavior.
final class AudioFrameMetadataRing {
    private let capacity: Int
    private var hostTimes: [UInt64]
    private var startSampleIndices: [Int64]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var count: Int = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacityFrames: Int) {
        self.capacity = max(1, capacityFrames)
        self.hostTimes = [UInt64](repeating: 0, count: self.capacity)
        self.startSampleIndices = [Int64](repeating: 0, count: self.capacity)
    }

    @discardableResult
    func push(hostTime: UInt64, startSampleIndex: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if count == capacity {
            // Drop oldest metadata if full.
            readIndex = (readIndex + 1) % capacity
            count -= 1
        }

        hostTimes[writeIndex] = hostTime
        startSampleIndices[writeIndex] = startSampleIndex
        writeIndex = (writeIndex + 1) % capacity
        count += 1
        return true
    }

    func pop() -> (hostTime: UInt64, startSampleIndex: Int64)? {
        lock.lock()
        defer { lock.unlock() }

        guard count > 0 else { return nil }

        let metadata = (
            hostTime: hostTimes[readIndex],
            startSampleIndex: startSampleIndices[readIndex]
        )
        readIndex = (readIndex + 1) % capacity
        count -= 1
        return metadata
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        count = 0
    }
}

// MARK: - Tap Audio Capture Service

/// Core Audio Tap-based audio capture service
/// Captures system audio via taps and microphone via AVAudioEngine
/// Provides synchronized, echo-cancelled audio for transcription
///
actor TapAudioCaptureService: AudioCaptureServiceProtocol {
    // MARK: - Types

    /// Audio type identifier - uses shared AudioStreamType for compatibility
    typealias AudioType = AudioStreamType

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.muesli.app", category: "TapAudioCaptureService")

    /// Permission check for screen recording (injected for testability)
    private let checkPermission: @Sendable () async -> Bool

    /// Closure to query whether AEC is enabled (RT-safe: reads OSAllocatedUnfairLock).
    private let isAECEnabled: @Sendable () -> Bool

    /// Tap manager for system audio
    private let tapManager = CoreAudioTapManager()

    /// Microphone capture engine (AVAudioEngine-based)
    private var microphoneEngine: AVAudioEngine?

    /// Audio synchronizer (nonisolated for RT-safe access from IOProc)
    /// The synchronizer uses internal locking (NSLock/OSAllocatedUnfairLock) for thread safety
    private nonisolated(unsafe) let synchronizer = AudioSynchronizer()

    /// AEC processor
    private let aecProcessor = AECProcessor()

    /// Audio worker thread
    private var audioWorker: AudioWorker?

    /// Route change listener token
    private var routeChangeToken: RouteChangeListenerToken?

    /// Current device topology mode
    private var topologyMode: DeviceTopologyMode = .unknown

    /// Whether currently recording
    private(set) var isRecording = false

    /// Selected microphone device ID
    private var selectedMicrophoneDeviceID: String?

    /// Snapshot of the real system default input device, captured BEFORE the
    /// aggregate device is created. Used as a fallback when setting the mic device
    /// on AVAudioEngine to avoid latching onto the aggregate. Session-scoped.
    private var preAggregateDefaultInputDeviceID: AudioDeviceID?

    /// Microphone sample rate (detected at start)
    private var microphoneSampleRate: Double = 48000

    /// Dedicated render ring for AEC timing feed (48kHz mono).
    private nonisolated(unsafe) let renderRingForAEC = TapCaptureRing(capacityMs: 600)

    /// Dedicated capture ring for AEC timing feed (48kHz mono).
    private nonisolated(unsafe) let captureRingForAEC = MicCaptureRing(capacityMs: 250)

    /// Frame metadata rings for AEC feed streams.
    private nonisolated(unsafe) let renderMetadataRingForAEC = AudioFrameMetadataRing(capacityFrames: 128)
    private nonisolated(unsafe) let captureMetadataRingForAEC = AudioFrameMetadataRing(capacityFrames: 128)

    /// Running sample-index counters for debug/metadata propagation.
    private nonisolated(unsafe) let renderSampleIndexCounter = OSAllocatedUnfairLock(initialState: Int64(0))
    private nonisolated(unsafe) let captureSampleIndexCounter = OSAllocatedUnfairLock(initialState: Int64(0))

    /// Last metadata fallback in case sample and metadata rings briefly diverge.
    private nonisolated(unsafe) let lastRenderMetadata = OSAllocatedUnfairLock(
        initialState: (hostTime: UInt64(0), startSampleIndex: Int64(0))
    )
    private nonisolated(unsafe) let lastCaptureMetadata = OSAllocatedUnfairLock(
        initialState: (hostTime: UInt64(0), startSampleIndex: Int64(0))
    )

    /// Pre-allocated downmix scratch used on the tap callback thread.
    private nonisolated(unsafe) let renderDownmixScratch = OSAllocatedUnfairLock(
        initialState: [Float](repeating: 0, count: 4096)
    )

    /// Dedicated file-output ring for raw stereo system audio (RT-safe push from IOProc).
    /// 600ms × 48kHz × 2ch = 57600 samples.
    private nonisolated(unsafe) let fileOutputRenderRing = TapCaptureRing(capacitySamples: 57600)

    /// File output drain timer task handle.
    private var fileOutputDrainTask: Task<Void, Never>?

    /// Current session ID for log correlation (short 8-char UUID prefix)
    private var currentSessionID: String = "none"

    // MARK: - Callbacks

    private var bufferHandler: AudioBufferHandler?
    private var interruptedHandler: StreamInterruptedHandler?
    private var levelHandler: AudioLevelHandler?
    private var warningHandler: AudioWarningHandler?
    private var processedMicHandler: ProcessedMicHandler?
    private var processedRenderHandler: ProcessedRenderHandler?

    // MARK: - CMSampleBuffer Creation State

    /// Pre-allocated format description for system audio (stereo 48kHz Float32)
    private var systemFormatDesc: CMFormatDescription?

    /// Whether format descriptions have been set up
    private var formatDescriptionsInitialized = false

    // MARK: - Initialization

    init(
        checkPermission: @escaping @Sendable () async -> Bool = {
            // Use cached tap-probe result from PermissionManager, NOT CGPreflightScreenCaptureAccess().
            // CGPreflight only checks the Screen Recording TCC bucket, but Core Audio taps use the
            // System Audio Recording bucket — a separate permission entry.
            UserDefaults.standard.bool(forKey: "systemAudioPermissionGranted")
        },
        isAECEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.checkPermission = checkPermission
        self.isAECEnabled = isAECEnabled
        print("[TAP DEBUG] TapAudioCaptureService.init() called - CREATED")
        logger.info("TapAudioCaptureService initialized")
        // Format descriptions are set up lazily on first use to avoid actor isolation issues in init
    }

    /// Ensure format descriptions are initialized (called before use)
    private func ensureFormatDescriptionsInitialized() {
        guard !formatDescriptionsInitialized else { return }
        setupFormatDescriptions()
        formatDescriptionsInitialized = true
    }

    // MARK: - Public API

    /// Set the microphone device to use
    func setMicrophoneDevice(_ deviceID: String?) {
        selectedMicrophoneDeviceID = deviceID
        
        guard isRecording else { return }
        
        // Re-snapshot the current default input. The aggregate is already running,
        // so the current default reflects real hardware (user may have plugged in
        // a new device since recording started).
        preAggregateDefaultInputDeviceID = try? CoreAudioHelpers.getDefaultInputDevice()

        logger.info("Switching microphone device during tap capture: \(deviceID ?? "system default")")
        stopMicrophoneCapture()
        synchronizer.reset()
        aecProcessor.reset()
        resetAECRingsAndCounters()
        
        do {
            try startMicrophoneCapture()
        } catch {
            logger.error("Failed to restart microphone after device switch: \(error.localizedDescription)")
            warningHandler?(
                .microphone,
                "Microphone switch failed",
                "Could not switch to the selected microphone. Error: \(error.localizedDescription)",
                true
            )
        }
    }

    /// Set callback for audio buffers (for file output)
    func setBufferHandler(_ handler: @escaping AudioBufferHandler) {
        bufferHandler = handler
    }

    /// Set callback for stream interruption
    func setInterruptedHandler(_ handler: @escaping StreamInterruptedHandler) {
        interruptedHandler = handler
    }

    /// Set callback for audio level updates
    func setLevelHandler(_ handler: @escaping AudioLevelHandler) {
        levelHandler = handler
    }

    /// Set callback for warnings
    func setWarningHandler(_ handler: @escaping AudioWarningHandler) {
        warningHandler = handler
    }

    /// Set callback for processed microphone frames (AEC output, 48kHz mono).
    func setProcessedMicHandler(_ handler: @escaping ProcessedMicHandler) {
        processedMicHandler = handler
    }

    /// Set callback for processed render/system frames (48kHz mono).
    func setProcessedRenderHandler(_ handler: @escaping ProcessedRenderHandler) {
        processedRenderHandler = handler
    }

    /// Start audio capture (captures all system audio)
    func startCapture() async throws {
        print("[TAP DEBUG] TapAudioCaptureService.startCapture() called")
        guard !isRecording else {
            print("[TAP DEBUG] ERROR: Already recording")
            throw AudioCaptureError.alreadyRecording
        }

        guard bufferHandler != nil else {
            print("[TAP DEBUG] ERROR: Buffer handler not set")
            throw AudioCaptureError.bufferHandlerNotSet
        }

        // Check permission before attempting tap creation.
        // If cache says false, still attempt the tap — permission may have been granted
        // externally (e.g., via System Settings). The tap attempt itself is the authoritative check.
        let hasPermission = await checkPermission()
        if !hasPermission {
            logger.warning("Cached tap permission is false — will attempt tap anyway (may have been granted externally)")
        }

        print("[TAP DEBUG] Starting tap-based audio capture...")
        logger.info("Starting tap-based audio capture")

        // Detect device topology
        topologyMode = CoreAudioHelpers.detectTopologyMode()
        print("[TAP DEBUG] Detected topology: \(topologyMode)")
        logger.info("Detected topology: \(String(describing: self.topologyMode))")

        // Log the AEC initialization sequence. The order here is critical:
        // 1. resetForNewSession() — full reset, no cooldown carry-over (vs reset() which carries cooldown)
        // 2. aecProcessor.reset() — clear WebRTC AEC3 internal state
        // 3. configure() — set topology-aware mode AFTER reset so mode is applied to fresh state
        // Any deviation from this order (e.g., configure before reset) can leave stale delay
        // estimates in the AEC3 filter, causing the "stable but non-converging" failure mode.
        let logTopologyForInit = self.topologyMode
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "AEC_INIT_SEQUENCE: topology=\(logTopologyForInit), steps=[resetForNewSession, aecReset, syncConfigure, aecConfigure]")
        }

        // Configure synchronizer and AEC for topology
        currentSessionID = String(UUID().uuidString.prefix(8))
        synchronizer.resetForNewSession()
        aecProcessor.reset()
        synchronizer.configure(topologyMode: topologyMode, sessionID: currentSessionID)
        aecProcessor.configure(topology: topologyMode, sessionID: currentSessionID, synchronizer: synchronizer)
        resetAECRingsAndCounters()

        // Set up route change listener
        setupRouteChangeListener()

        // Brief settling delay before starting the tap.
        // A permission probe tap (from handleDidBecomeActive or pre-recording permission check)
        // may have run just before this point. Although the probe calls AudioDeviceStop +
        // AudioDeviceDestroyIOProcID + destroyDevice() synchronously, macOS releases the
        // audio hardware route asynchronously. If the recording tap starts too quickly,
        // it races with the still-live probe aggregate device and receives silence on its
        // render ring for ~20 seconds — preventing AEC3 from converging.
        // 300ms is enough for macOS to complete the async aggregate device teardown.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            if let token = routeChangeToken {
                CoreAudioHelpers.removeRouteChangeListener(token)
                routeChangeToken = nil
            }
            throw error
        }

        // Snapshot the real system default input BEFORE creating the aggregate device.
        // After aggregate creation, macOS may transiently report the aggregate as the
        // default input, which would cause AVAudioEngine to latch onto it.
        preAggregateDefaultInputDeviceID = try? CoreAudioHelpers.getDefaultInputDevice()
        if let devID = preAggregateDefaultInputDeviceID {
            let uid = (try? CoreAudioHelpers.getDeviceUID(devID)) ?? "unknown"
            logger.info("Pre-aggregate default input: \(uid) (AudioDeviceID: \(devID))")
        }

        // Start the tap for system audio
        do {
            print("[TAP DEBUG] Calling tapManager.start()...")
            try tapManager.start(
                configuration: TapConfiguration(
                    sampleRate: 48000,
                    channelCount: 2,
                    frameQuantum: 480,
                    excludedProcessIDs: [],
                    isExclusive: false
                ),
                callback: { [weak self] samples, frameCount, sampleTime, hostTime in
                    self?.handleTapAudio(samples: samples, frameCount: frameCount, sampleTime: sampleTime, hostTime: hostTime)
                }
            )
            print("[TAP DEBUG] tapManager.start() succeeded")
            // Tap succeeded — ensure cache reflects granted permission
            UserDefaults.standard.set(true, forKey: "systemAudioPermissionGranted")
        } catch {
            print("[TAP DEBUG] ERROR: tapManager.start() failed: \(error)")
            logger.error("Failed to start tap: \(error.localizedDescription)")

            // Invalidate stale cache so future launches don't assume permission is granted
            UserDefaults.standard.set(false, forKey: "systemAudioPermissionGranted")

            // Degrade to mic-only mode
            tapManager.degradeToMicOnly(reason: error.localizedDescription)
            warningHandler?(.systemAudio, "System audio unavailable", "Recording microphone only: \(error.localizedDescription)", false)
        }

        // Start microphone capture
        // Brief delay to let render ring accumulate lead before mic capture begins.
        // Cancellation-safe: if cancelled during sleep, clean up all startup side effects.
        do {
            try await Task.sleep(for: .milliseconds(50))
        } catch {
            // Cancelled during priming — clean up tap and route listener before propagating
            tapManager.stop()
            if let token = routeChangeToken {
                CoreAudioHelpers.removeRouteChangeListener(token)
                routeChangeToken = nil
            }
            throw error
        }

        do {
            try startMicrophoneCapture()
        } catch {
            logger.error("Failed to start microphone: \(error.localizedDescription)")
            // Clean up tap and route listener so no partial-start state is left behind
            tapManager.stop()
            if let token = routeChangeToken {
                CoreAudioHelpers.removeRouteChangeListener(token)
                routeChangeToken = nil
            }
            throw AudioCaptureError.microphoneStartFailed(error)
        }

        // Start audio worker
        let worker = AudioWorker(
            synchronizer: synchronizer,
            aecProcessor: aecProcessor,
            popRenderAECFrame: { [weak self] destination in
                self?.popRenderAECFrame(into: destination)
            },
            popCaptureAECFrame: { [weak self] destination in
                self?.popCaptureAECFrame(into: destination)
            },
            isAECEnabled: isAECEnabled
        )
        worker.start(
            micCallback: { [weak self] frame in
                self?.handleProcessedMicFrame(frame)
            },
            renderCallback: { [weak self] frame in
                self?.handleProcessedRenderFrame(frame)
            }
        )
        audioWorker = worker

        // Start file-output drain loop (every 50ms, drains RT-safe ring to actor for CMSampleBuffer delivery)
        fileOutputDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drainFileOutputRings()
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }

        // Note: No system audio warning removed — the app supports personal dictation
        // (mic-only) as a valid use case. Absence of system audio is not an error.

        isRecording = true
        logger.info("Tap-based audio capture started")

        let logTopology = self.topologyMode
        // Read raw UserDefaults as tri-state so fresh installs log "unset" instead of
        // a misleading "false" (bool(forKey:) collapses unset → false).
        let aecStoredObj = UserDefaults.standard.object(forKey: "echoCancellationEnabled")
        let logAECStoredPref: String = aecStoredObj.map { "\($0 as? Bool ?? false)" } ?? "unset"
        let logAECEffective = isAECEnabled()
        #if DEBUG
        let logBuild = "DEBUG"
        if UserDefaults.standard.bool(forKey: "aecDebugForceOff") && !logAECEffective {
            logger.warning("AEC_DEBUG_OVERRIDE_ACTIVE: AEC forced off via aecDebugForceOff defaults key")
        }
        #else
        let logBuild = "RELEASE"
        #endif
        // Detect if this session started after permission recovery: the UserDefaults key was
        // previously unset (false) and was just written to true by the tap-start code above.
        // We read it here after the tap succeeded, so it reflects the real post-recovery state.
        let logPermissionWasCached = UserDefaults.standard.object(forKey: "systemAudioPermissionGranted") != nil
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "TAP_CAPTURE_START: topology=\(logTopology), aecStoredPref=\(logAECStoredPref), aecEffective=\(logAECEffective), build=\(logBuild), permissionWasCached=\(logPermissionWasCached)")
        }
    }

    /// Stop audio capture
    func stopCapture() async throws {
        guard isRecording else {
            throw AudioCaptureError.notRecording
        }

        logger.info("Stopping tap-based audio capture")

        // Stop file-output drain
        fileOutputDrainTask?.cancel()
        fileOutputDrainTask = nil

        // Stop audio worker
        audioWorker?.stop()
        audioWorker = nil

        // Stop tap
        tapManager.stop()

        // Stop microphone
        stopMicrophoneCapture()

        // Remove route change listener
        if let token = routeChangeToken {
            CoreAudioHelpers.removeRouteChangeListener(token)
            routeChangeToken = nil
        }

        // Reset state
        synchronizer.reset()
        aecProcessor.reset()
        resetAECRingsAndCounters()
        preAggregateDefaultInputDeviceID = nil

        isRecording = false
        logger.info("Tap-based audio capture stopped")

        Task {
            await DiagnosticLogger.shared.log(.aec, "TAP_CAPTURE_STOP")
        }
    }

    // MARK: - Private Implementation

    /// Setup format descriptions for CMSampleBuffer creation
    private func setupFormatDescriptions() {
        // System audio format: stereo 48kHz Float32
        var systemASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,  // 2 channels * 4 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &systemASBD,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &systemFormatDesc
        )

        // Note: Mic format description is NOT pre-allocated here.
        // It is created per-buffer in createCMSampleBuffer() using the actual
        // microphoneSampleRate, which avoids a race condition where this method
        // would overwrite the correct rate with a default 48kHz value.
    }

    /// Handle audio from tap (RT callback - minimal work)
    /// RT-SAFE: No allocations, no locks (beyond ring buffer's unfair lock), no async/await
    private nonisolated func handleTapAudio(
        samples: UnsafePointer<Float>,
        frameCount: UInt32,
        sampleTime: Float64,
        hostTime: UInt64
    ) {
        let count = Int(frameCount)
        guard count > 0 else { return }

        let totalSamples = count * 2  // Stereo: frameCount * 2 channels
        let startSampleIndex = renderSampleIndexCounter.withLock { index -> Int64 in
            let start = index
            index += Int64(count)
            return start
        }

        // Downmix to mono using pre-allocated scratch, then feed synchronizer + AEC render ring.
        // nonisolated(unsafe) to suppress Sendable warning — pointer is valid for duration of withLock.
        nonisolated(unsafe) let samplesRef = samples
        renderDownmixScratch.withLock { scratch in
            guard count <= scratch.count else { return }
            for i in 0..<count {
                scratch[i] = (samplesRef[i * 2] + samplesRef[i * 2 + 1]) * 0.5
            }

            scratch.withUnsafeBufferPointer { monoPtr in
                guard let baseAddress = monoPtr.baseAddress else { return }
                synchronizer.pushRender(
                    samples: baseAddress,
                    count: count,
                    sampleTime: sampleTime,
                    hostTime: hostTime
                )
                _ = renderRingForAEC.push(
                    samples: baseAddress,
                    count: count,
                    sampleTime: sampleTime,
                    hostTime: hostTime
                )
            }
        }
        pushRenderFrameMetadata(hostTime: hostTime, startSampleIndex: startSampleIndex, sampleCount: count)

        // Push raw stereo samples to file-output ring (RT-safe, no allocation)
        _ = fileOutputRenderRing.push(samples: samples, count: totalSamples, sampleTime: sampleTime, hostTime: hostTime)
    }

    /// Handle processed microphone frame from worker.
    private nonisolated func handleProcessedMicFrame(_ frame: AudioFrame) {
        Task {
            await self.deliverProcessedMicFrame(frame)
        }
    }

    /// Handle processed render frame from worker.
    private nonisolated func handleProcessedRenderFrame(_ frame: AudioFrame) {
        Task {
            await self.deliverProcessedRenderFrame(frame)
        }
    }

    /// Deliver raw system audio for file output (48kHz stereo)
    private func deliverRawSystemAudio(samples: [Float], timestamp: Double) {
        ensureFormatDescriptionsInitialized()

        guard !samples.isEmpty else { return }

        // Create CMSampleBuffer with correct format (48kHz stereo Float32)
        let buffer = createCMSampleBuffer(
            from: samples,
            channels: 2,  // Stereo
            sampleRate: 48000,
            timestamp: timestamp,
            formatDesc: systemFormatDesc
        )

        if let buffer = buffer {
            bufferHandler?(buffer, .system)
        }

        // Calculate and deliver audio level
        let level = calculateRMSFromArray(samples)
        levelHandler?(level, .system)
    }

    /// Drain the RT-safe file-output ring and deliver to file output (runs on actor).
    private func drainFileOutputRings() {
        let available = fileOutputRenderRing.available
        guard available > 0 else { return }

        var samples = [Float](repeating: 0, count: available)
        let popped = samples.withUnsafeMutableBufferPointer { ptr -> Bool in
            fileOutputRenderRing.pop(into: ptr.baseAddress!, count: available)
        }
        guard popped else { return }

        deliverRawSystemAudio(samples: samples, timestamp: CACurrentMediaTime())
    }
    
    /// Deliver raw microphone audio for file output (mono Float32 at actual mic sample rate)
    private func deliverRawMicAudio(samples: [Float], timestamp: Double) {
        ensureFormatDescriptionsInitialized()

        guard !samples.isEmpty else { return }

        // Create CMSampleBuffer with correct format (mono Float32 at actual mic sample rate)
        // Pass nil for formatDesc so createCMSampleBuffer creates a fresh description
        // from microphoneSampleRate — this avoids the race condition where a cached
        // micFormatDesc could be overwritten with the wrong sample rate.
        if let buffer = createCMSampleBuffer(
            from: samples,
            channels: 1,  // Mono
            sampleRate: microphoneSampleRate,
            timestamp: timestamp,
            formatDesc: nil
        ) {
            bufferHandler?(buffer, .microphone)
        }
        
        // Calculate and deliver audio level
        let level = calculateRMSFromArray(samples)
        levelHandler?(level, .microphone)
    }
    
    /// Deliver processed mic frame to callback (for transcription - NOT file output).
    private func deliverProcessedMicFrame(_ frame: AudioFrame) {
        processedMicHandler?(frame)
    }

    /// Deliver processed render frame to callback (for transcription - NOT file output).
    private func deliverProcessedRenderFrame(_ frame: AudioFrame) {
        processedRenderHandler?(frame)
    }

    /// Pop one render frame for AEC worker processing.
    private nonisolated func popRenderAECFrame(
        into destination: UnsafeMutablePointer<Float>
    ) -> (hostTime: UInt64, startSampleIndex: Int64)? {
        guard renderRingForAEC.pop(into: destination, count: AudioWorker.frameSizeSamples) else {
            return nil
        }

        if let metadata = renderMetadataRingForAEC.pop() {
            _ = lastRenderMetadata.withLock { state in
                state = metadata
            }
            return metadata
        }

        return lastRenderMetadata.withLock { state in
            state
        }
    }

    /// Pop one capture frame for AEC worker processing.
    private nonisolated func popCaptureAECFrame(
        into destination: UnsafeMutablePointer<Float>
    ) -> (hostTime: UInt64, startSampleIndex: Int64)? {
        guard captureRingForAEC.pop(into: destination, count: AudioWorker.frameSizeSamples) else {
            return nil
        }

        if let metadata = captureMetadataRingForAEC.pop() {
            _ = lastCaptureMetadata.withLock { state in
                state = metadata
            }
            return metadata
        }

        return lastCaptureMetadata.withLock { state in
            state
        }
    }

    /// Push per-frame metadata for a render callback batch.
    private nonisolated func pushRenderFrameMetadata(
        hostTime: UInt64,
        startSampleIndex: Int64,
        sampleCount: Int
    ) {
        var frameStart = startSampleIndex
        var remaining = sampleCount

        while remaining >= AudioWorker.frameSizeSamples {
            _ = renderMetadataRingForAEC.push(hostTime: hostTime, startSampleIndex: frameStart)
            let currentFrameStart = frameStart
            _ = lastRenderMetadata.withLock { state in
                state = (hostTime: hostTime, startSampleIndex: currentFrameStart)
            }
            frameStart += Int64(AudioWorker.frameSizeSamples)
            remaining -= AudioWorker.frameSizeSamples
        }
    }

    /// Push per-frame metadata for a capture callback batch.
    private nonisolated func pushCaptureFrameMetadata(
        hostTime: UInt64,
        startSampleIndex: Int64,
        sampleCount: Int
    ) {
        var frameStart = startSampleIndex
        var remaining = sampleCount

        while remaining >= AudioWorker.frameSizeSamples {
            _ = captureMetadataRingForAEC.push(hostTime: hostTime, startSampleIndex: frameStart)
            let currentFrameStart = frameStart
            _ = lastCaptureMetadata.withLock { state in
                state = (hostTime: hostTime, startSampleIndex: currentFrameStart)
            }
            frameStart += Int64(AudioWorker.frameSizeSamples)
            remaining -= AudioWorker.frameSizeSamples
        }
    }

    /// Reset dedicated AEC rings and metadata counters.
    private func resetAECRingsAndCounters() {
        renderRingForAEC.reset()
        captureRingForAEC.reset()
        renderMetadataRingForAEC.reset()
        captureMetadataRingForAEC.reset()
        fileOutputRenderRing.reset()

        _ = renderSampleIndexCounter.withLock { index in
            index = 0
        }
        _ = captureSampleIndexCounter.withLock { index in
            index = 0
        }
        _ = lastRenderMetadata.withLock { state in
            state = (hostTime: 0, startSampleIndex: 0)
        }
        _ = lastCaptureMetadata.withLock { state in
            state = (hostTime: 0, startSampleIndex: 0)
        }
    }

    /// Create CMSampleBuffer from Float samples (for FileOutputService compatibility)
    private func createCMSampleBuffer(
        from samples: [Float],
        channels: Int,
        sampleRate: Double,
        timestamp: Double,
        formatDesc: CMFormatDescription?
    ) -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }

        // Create format description if not provided
        var format = formatDesc
        if format == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(channels * 4),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(channels * 4),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            var newFormat: CMFormatDescription?
            CMAudioFormatDescriptionCreate(
                allocator: nil,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &newFormat
            )
            format = newFormat
        }

        guard let format = format else { return nil }

        // Create block buffer
        let dataSize = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let block = blockBuffer else { return nil }

        // Copy data
        status = samples.withUnsafeBufferPointer { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        guard status == noErr else { return nil }

        // Create timing info
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: samples.count / channels,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        return status == noErr ? sampleBuffer : nil
    }

    /// Start microphone capture using AVAudioEngine
    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()

        // Try to set the user-selected mic (or pre-aggregate default).
        // If this fails, the engine uses whatever macOS provides as default.
        let deviceWasSet = setMicrophoneInputDevice(
            engine: engine,
            deviceUID: selectedMicrophoneDeviceID,
            fallbackDeviceID: preAggregateDefaultInputDeviceID
        )

        let inputNode = engine.inputNode
        let actualDeviceID = inputNode.auAudioUnit.deviceID
        let actualUID = (try? CoreAudioHelpers.getDeviceUID(actualDeviceID)) ?? "unknown"
        logger.info("MIC_ENGINE_DEVICE: \(actualUID) (AudioDeviceID: \(actualDeviceID), explicitlySet: \(deviceWasSet))")
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "MIC_ENGINE_DEVICE: uid=\(actualUID), audioDeviceID=\(actualDeviceID), explicitlySet=\(deviceWasSet)")
        }

        let inputFormat = inputNode.inputFormat(forBus: 0)
        let hardwareSampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 48000
        let tapSampleRate = 48000.0
        microphoneSampleRate = tapSampleRate

        // Use the device's actual channel count to avoid installTap crashes.
        // Some devices (e.g., the aggregate tap device) are stereo; forcing mono
        // on a stereo-only device throws an uncaught NSException.
        let tapChannels: AVAudioChannelCount = inputFormat.channelCount > 0 ? min(inputFormat.channelCount, 2) : 1
        guard let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapSampleRate,
            channels: tapChannels,
            interleaved: false
        ) else {
            throw AudioCaptureError.microphoneStartFailed(NSError(domain: "TapAudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create tap format"]))
        }

        inputNode.installTap(onBus: 0, bufferSize: 480, format: tapFormat) { [weak self] buffer, time in
            self?.handleMicrophoneBuffer(buffer, time: time)
        }

        try engine.start()
        microphoneEngine = engine

        logger.info("Microphone capture started at \(tapSampleRate)Hz, channels=\(tapChannels)")
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "MIC_SAMPLE_RATE: hardware=\(hardwareSampleRate)Hz, tap=\(tapSampleRate)Hz, channels=\(tapChannels)")
        }
    }

    /// Stop microphone capture
    private func stopMicrophoneCapture() {
        if let engine = microphoneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        microphoneEngine = nil
    }

    /// Handle microphone buffer from AVAudioEngine
    /// Note: AVAudioEngine tap callbacks are on a high-priority audio thread
    /// We push directly to the synchronizer's lock-free ring buffer for RT-safety
    private nonisolated func handleMicrophoneBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let floatChannelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let samples = floatChannelData[0]

        // Use sample time if available, otherwise derive from host time
        let sampleTime: Float64 = time.isSampleTimeValid ? Float64(time.sampleTime) : Float64(-1)
        let hostTime = time.hostTime
        let startSampleIndex = captureSampleIndexCounter.withLock { index -> Int64 in
            let start = index
            index += Int64(frameLength)
            return start
        }

        // Push directly to synchronizer (RT-safe - uses OSAllocatedUnfairLock)
        synchronizer.pushCapture(
            samples: samples,
            count: frameLength,
            sampleTime: Float64(sampleTime),
            hostTime: hostTime
        )
        _ = captureRingForAEC.push(
            samples: samples,
            count: frameLength,
            sampleTime: Float64(sampleTime),
            hostTime: hostTime
        )
        pushCaptureFrameMetadata(
            hostTime: hostTime,
            startSampleIndex: startSampleIndex,
            sampleCount: frameLength
        )

        // Create array for async delivery to file output (raw mono at mic sample rate).
        // Note: AVAudioEngine tap callbacks are high-priority but NOT true RT IOProc.
        // Array allocation + Task dispatch is acceptable here. See handleTapAudio for
        // the RT-safe ring-based approach used for the true IOProc callback.
        let sampleArray = Array(UnsafeBufferPointer(start: samples, count: frameLength))
        let timestamp = CACurrentMediaTime()
        
        Task { [weak self] in
            await self?.deliverRawMicAudio(samples: sampleArray, timestamp: timestamp)
        }
    }

    /// Returns true if the UID belongs to a Muesli tap aggregate device (current or stale).
    private func isMuesliAggregateUID(_ uid: String) -> Bool {
        if uid.hasPrefix("com.muesli.tap") { return true }
        if let currentUID = tapManager.aggregateDeviceUID, uid == currentUID { return true }
        return false
    }

    /// Set the AudioDeviceID on the engine's input node using the low-level
    /// AudioUnit property API. This is more reliable than `auAudioUnit.setDeviceID()`
    /// which can succeed (readback matches) but still deliver silence.
    private func setDeviceOnInputNode(_ engine: AVAudioEngine, deviceID: AudioDeviceID) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else {
            logger.error("MIC_DEVICE_SET: inputNode has no audioUnit")
            return false
        }

        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            logger.warning("MIC_DEVICE_SET: AudioUnitSetProperty failed with status \(status)")
            return false
        }

        var readbackID: AudioDeviceID = 0
        var readbackSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &readbackID,
            &readbackSize
        )

        if readbackID != deviceID {
            logger.warning("MIC_DEVICE_SET: readback mismatch — set \(deviceID), got \(readbackID)")
            return false
        }

        return true
    }

    /// Set microphone input device with strict two-step fallback.
    /// Returns true only when a device was explicitly set AND verified.
    /// Never accepts the engine's unverified default (which may be the tap aggregate).
    private func setMicrophoneInputDevice(
        engine: AVAudioEngine,
        deviceUID: String?,
        fallbackDeviceID: AudioDeviceID?
    ) -> Bool {
        // Step 1: Try to find and set the requested device by UID
        if let deviceUID {
            if isMuesliAggregateUID(deviceUID) {
                logger.warning("MIC_DEVICE_SELECT: requested UID is a Muesli aggregate (\(deviceUID)) — skipping to fallback")
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "MIC_DEVICE_REJECT: uid=\(deviceUID), reason=muesli_aggregate")
                }
            } else {
                let allDevices = CoreAudioHelpers.getAllDevices()
                var found = false
                for device in allDevices {
                    guard let uid = try? CoreAudioHelpers.getDeviceUID(device) else { continue }
                    guard uid == deviceUID else { continue }
                    found = true

                    if setDeviceOnInputNode(engine, deviceID: device) {
                        logger.info("MIC_DEVICE_SET: \(deviceUID) (AudioDeviceID: \(device))")
                        Task {
                            await DiagnosticLogger.shared.log(.aec,
                                "MIC_DEVICE_SET: uid=\(deviceUID), audioDeviceID=\(device), step=requested")
                        }
                        return true
                    }
                }
                if !found {
                    logger.warning("MIC_DEVICE_SELECT: requested UID \(deviceUID) not found in Core Audio device list")
                    Task {
                        await DiagnosticLogger.shared.log(.aec,
                            "MIC_DEVICE_NOT_FOUND: uid=\(deviceUID)")
                    }
                }
            }
        }

        // Step 2: Fall back to pre-aggregate default AudioDeviceID
        if let fallbackID = fallbackDeviceID, fallbackID != kAudioObjectUnknown {
            let fallbackUID = try? CoreAudioHelpers.getDeviceUID(fallbackID)
            if let fallbackUID, isMuesliAggregateUID(fallbackUID) {
                logger.warning("MIC_DEVICE_SELECT: pre-aggregate fallback IS a Muesli aggregate — skipping")
            } else {
                if setDeviceOnInputNode(engine, deviceID: fallbackID) {
                    logger.info("MIC_DEVICE_SET: pre-aggregate default \(fallbackUID ?? "?") (AudioDeviceID: \(fallbackID))")
                    Task {
                        await DiagnosticLogger.shared.log(.aec,
                            "MIC_DEVICE_SET: uid=\(fallbackUID ?? "?"), audioDeviceID=\(fallbackID), step=fallback")
                    }
                    return true
                }
            }
        }

        // Both steps failed.
        let currentDeviceID = engine.inputNode.auAudioUnit.deviceID
        let currentUID = (try? CoreAudioHelpers.getDeviceUID(currentDeviceID)) ?? "unknown"
        logger.error("MIC_DEVICE_SET: FAILED — no valid device. Engine default is AudioDeviceID \(currentDeviceID) (\(currentUID))")
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "MIC_DEVICE_FAILED: engineDefault=\(currentUID) (AudioDeviceID: \(currentDeviceID))")
        }
        return false
    }

    /// Set up route change listener
    private func setupRouteChangeListener() {
        routeChangeToken = CoreAudioHelpers.addRouteChangeListener { [weak self] in
            guard let self = self else { return }
            Task { [weak self] in
                await self?.handleRouteChange()
            }
        }
    }

    /// Handle audio route change (device switch)
    private func handleRouteChange() {
        logger.info("Audio route changed, resetting synchronizer")

        // Re-detect topology
        let newTopology = CoreAudioHelpers.detectTopologyMode()

        if newTopology != topologyMode {
            topologyMode = newTopology
            synchronizer.configure(topologyMode: newTopology, sessionID: currentSessionID)
            aecProcessor.configure(topology: newTopology, sessionID: currentSessionID, synchronizer: synchronizer)
        }

        // Reset synchronizer to handle the discontinuity
        synchronizer.reset()
        aecProcessor.reset()
        resetAECRingsAndCounters()

        Task {
            await DiagnosticLogger.shared.log(.aec,
                "ROUTE_CHANGE: newTopology=\(newTopology)")
        }
    }

    /// Calculate RMS level from samples pointer
    private nonisolated func calculateRMS(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }

        var sumSquares: Float = 0
        for i in 0..<count {
            let sample = samples[i]
            sumSquares += sample * sample
        }

        let rms = sqrt(sumSquares / Float(count))
        return min(rms * 16.0, 1.0)  // Scale for UI
    }

    /// Calculate RMS level from array
    private func calculateRMSFromArray(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }

        let rms = sqrt(sumSquares / Float(samples.count))
        return min(rms * 16.0, 1.0)  // Scale for UI
    }
}
