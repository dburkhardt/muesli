//
//  TapAudioCaptureService.swift
//  Muesli
//
//  Core Audio Tap-based audio capture service.
//  Replaces ScreenCaptureKit-based AudioCaptureService for macOS 26+.
//  Orchestrates: TapManager -> Synchronizer -> AEC -> Worker -> Output
//

import Foundation
import CoreMedia
import AVFoundation
import AudioToolbox
import os.log
import QuartzCore

// MARK: - Tap Audio Capture Service

/// Core Audio Tap-based audio capture service
/// Captures system audio via taps and microphone via AVAudioEngine
/// Provides synchronized, echo-cancelled audio for transcription
///
/// This service is API-compatible with AudioCaptureService for easy migration.
actor TapAudioCaptureService: AudioCaptureServiceProtocol {

    // MARK: - Types

    /// Audio type identifier - uses shared AudioStreamType for compatibility
    typealias AudioType = AudioStreamType

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.muesli.app", category: "TapAudioCaptureService")

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

    /// Microphone sample rate (detected at start)
    private var microphoneSampleRate: Double = 48000

    // MARK: - Callbacks

    private var bufferHandler: AudioBufferHandler?
    private var interruptedHandler: StreamInterruptedHandler?
    private var levelHandler: AudioLevelHandler?
    private var warningHandler: AudioWarningHandler?

    // MARK: - CMSampleBuffer Creation State

    /// Pre-allocated format description for system audio (stereo 48kHz Float32)
    private var systemFormatDesc: CMFormatDescription?

    /// Pre-allocated format description for mic audio (mono Float32)
    private var micFormatDesc: CMFormatDescription?

    /// Whether format descriptions have been set up
    private var formatDescriptionsInitialized = false

    // MARK: - Initialization

    init() {
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

    // MARK: - Public API (API-compatible with AudioCaptureService)

    /// Set the microphone device to use
    func setMicrophoneDevice(_ deviceID: String?) {
        selectedMicrophoneDeviceID = deviceID
        
        guard isRecording else { return }
        
        logger.info("Switching microphone device during tap capture: \(deviceID ?? "system default")")
        stopMicrophoneCapture()
        synchronizer.reset()
        aecProcessor.reset()
        
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

        print("[TAP DEBUG] Starting tap-based audio capture...")
        logger.info("Starting tap-based audio capture")

        // Detect device topology
        topologyMode = CoreAudioHelpers.detectTopologyMode()
        print("[TAP DEBUG] Detected topology: \(topologyMode)")
        logger.info("Detected topology: \(String(describing: self.topologyMode))")

        // Configure synchronizer and AEC for topology
        synchronizer.configure(topologyMode: topologyMode)
        aecProcessor.configure(topology: topologyMode)

        // Set up route change listener
        setupRouteChangeListener()

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
        } catch {
            print("[TAP DEBUG] ERROR: tapManager.start() failed: \(error)")
            logger.error("Failed to start tap: \(error.localizedDescription)")

            // Degrade to mic-only mode
            tapManager.degradeToMicOnly(reason: error.localizedDescription)
            warningHandler?(.systemAudio, "System audio unavailable", "Recording microphone only: \(error.localizedDescription)", false)
        }

        // Start microphone capture
        do {
            try startMicrophoneCapture()
        } catch {
            logger.error("Failed to start microphone: \(error.localizedDescription)")
            throw AudioCaptureError.microphoneStartFailed(error)
        }

        // Start audio worker
        let worker = AudioWorker(synchronizer: synchronizer, aecProcessor: aecProcessor)
        worker.start { [weak self] renderSamples, captureSamples, frameIndex in
            self?.handleProcessedAudio(renderSamples: renderSamples, captureSamples: captureSamples, frameIndex: frameIndex)
        }
        audioWorker = worker

        // Start runtime RMS monitoring for the tap
        // If rollingRMS stays near-zero for >3 seconds during an active recording,
        // fire the warningHandler to alert the user (catches real permission revocation
        // without false positives from excluded-process audio).
        if tapManager.state == .running {
            let handler = self.warningHandler
            Task { [weak self] in
                // Wait 3 seconds before checking
                try? await Task.sleep(for: .seconds(3))
                guard let self = self, await self.isRecording else { return }
                let rms = self.tapManager.currentRMSLevel
                if rms < 0.0001 {
                    await MainActor.run {
                        handler?(.systemAudio, "No system audio detected",
                            "No system audio picked up yet — is anything playing? If you're on a call or playing media and still see this, check that System Audio Recording permission is granted.",
                            false)
                    }
                }
            }
        }

        isRecording = true
        logger.info("Tap-based audio capture started")

        let logTopology = self.topologyMode
        Task {
            await DiagnosticLogger.shared.log(.aec,
                "TAP_CAPTURE_START: topology=\(logTopology)")
        }
    }

    /// Start audio capture for a specific app (for API compatibility - tap captures all audio anyway)
    /// - Parameter bundleIdentifier: Ignored - tap captures all system audio except Muesli
    func startCapture(forBundleIdentifier bundleIdentifier: String) async throws {
        // Note: Core Audio tap captures all system audio except Muesli
        // The bundle identifier is ignored for compatibility with the old API
        logger.info("startCapture(forBundleIdentifier:) called - tap captures all system audio")
        try await startCapture()
    }

    /// Stop audio capture
    func stopCapture() async throws {
        guard isRecording else {
            throw AudioCaptureError.notRecording
        }

        logger.info("Stopping tap-based audio capture")

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

        // Mic audio format: mono 48kHz Float32 (will be updated if different sample rate detected)
        var micASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &micASBD,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &micFormatDesc
        )
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
        let totalSamples = count * 2  // Stereo: frameCount * 2 channels
        
        // Push to synchronizer for transcription pipeline
        synchronizer.pushRender(samples: samples, count: totalSamples, sampleTime: sampleTime, hostTime: hostTime)
        
        // Create CMSampleBuffer for file output (raw 48kHz stereo)
        // This is done here to preserve the original audio quality
        let sampleArray = Array(UnsafeBufferPointer(start: samples, count: totalSamples))
        let timestamp = CACurrentMediaTime()

        Task { [weak self] in
            await self?.deliverRawSystemAudio(samples: sampleArray, timestamp: timestamp)
        }
    }

    /// Handle processed audio from worker
    private nonisolated func handleProcessedAudio(
        renderSamples: [Float],
        captureSamples: [Float],
        frameIndex: Int64
    ) {
        Task {
            await self.deliverProcessedAudio(renderSamples: renderSamples, captureSamples: captureSamples, frameIndex: frameIndex)
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
    
    /// Deliver raw microphone audio for file output (48kHz mono)
    private func deliverRawMicAudio(samples: [Float], timestamp: Double) {
        ensureFormatDescriptionsInitialized()

        guard !samples.isEmpty else { return }

        // Create CMSampleBuffer with correct format (mono Float32 at actual mic sample rate)
        if let buffer = createCMSampleBuffer(
            from: samples,
            channels: 1,  // Mono
            sampleRate: microphoneSampleRate,
            timestamp: timestamp,
            formatDesc: micFormatDesc
        ) {
            bufferHandler?(buffer, .microphone)
        }
        
        // Calculate and deliver audio level
        let level = calculateRMSFromArray(samples)
        levelHandler?(level, .microphone)
    }
    
    /// Deliver processed audio to callbacks (for transcription - NOT file output)
    private func deliverProcessedAudio(
        renderSamples: [Float],
        captureSamples: [Float],
        frameIndex: Int64
    ) {
        // Note: File output is now handled by deliverRawSystemAudio and deliverRawMicAudio
        // This method is kept for transcription pipeline but doesn't write to files anymore
        
        // The processed 16kHz mono audio would go to transcription service
        // For now, we just skip this as file output is handled elsewhere
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
        let inputNode = engine.inputNode

        // Set device if specified
        if let deviceID = selectedMicrophoneDeviceID {
            setMicrophoneInputDevice(engine: engine, deviceID: deviceID)
        }

        // Get format (prefer 48kHz)
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let tapSampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 48000
        microphoneSampleRate = tapSampleRate

        // Update mic format description if sample rate differs
        if tapSampleRate != 48000 {
            var micASBD = AudioStreamBasicDescription(
                mSampleRate: tapSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            CMAudioFormatDescriptionCreate(
                allocator: nil,
                asbd: &micASBD,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &micFormatDesc
            )
        }

        // Install tap
        guard let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.microphoneStartFailed(NSError(domain: "TapAudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create tap format"]))
        }

        inputNode.installTap(onBus: 0, bufferSize: 480, format: tapFormat) { [weak self] buffer, time in
            self?.handleMicrophoneBuffer(buffer, time: time)
        }

        try engine.start()
        microphoneEngine = engine

        logger.info("Microphone capture started at \(tapSampleRate)Hz")
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
        let sampleTime = time.isSampleTimeValid ? time.sampleTime : 0
        let hostTime = time.hostTime

        // Push directly to synchronizer (RT-safe - uses OSAllocatedUnfairLock)
        synchronizer.pushCapture(
            samples: samples,
            count: frameLength,
            sampleTime: Float64(sampleTime),
            hostTime: hostTime
        )

        // Create array for async delivery to file output (raw mono at mic sample rate)
        let sampleArray = Array(UnsafeBufferPointer(start: samples, count: frameLength))
        let timestamp = CACurrentMediaTime()
        
        Task { [weak self] in
            await self?.deliverRawMicAudio(samples: sampleArray, timestamp: timestamp)
        }
    }

    /// Set microphone input device
    private func setMicrophoneInputDevice(engine: AVAudioEngine, deviceID: String) {
        // Find device by UID
        let devices = CoreAudioHelpers.getAllDevices()
        for device in devices {
            if let uid = try? CoreAudioHelpers.getDeviceUID(device), uid == deviceID {
                do {
                    try engine.inputNode.auAudioUnit.setDeviceID(device)
                    logger.debug("Set microphone device: \(deviceID)")
                    return
                } catch {
                    logger.warning("Failed to set microphone device: \(error)")
                }
            }
        }
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
            synchronizer.configure(topologyMode: newTopology)
            aecProcessor.configure(topology: newTopology)
        }

        // Reset synchronizer to handle the discontinuity
        synchronizer.reset()
        aecProcessor.reset()

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
