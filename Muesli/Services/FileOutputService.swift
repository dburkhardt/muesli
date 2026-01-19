@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os.log

/// Service responsible for saving audio recordings and transcripts to disk
/// Uses a combination of actor isolation (for setup/teardown) and manual locking (for real-time buffer writing)
final class FileOutputService: @unchecked Sendable, FileOutputServiceProtocol {
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "FileOutputService")
    
    // MARK: - Types
    
    enum OutputError: Error, LocalizedError {
        case directoryCreationFailed
        case assetWriterCreationFailed(underlying: Error)
        case assetWriterNotReady
        case alreadyWriting
        case notWriting
        case finalizationFailed
        
        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed:
                return "Failed to create output directory"
            case .assetWriterCreationFailed(let error):
                return "Failed to create audio writer: \(error.localizedDescription)"
            case .assetWriterNotReady:
                return "Audio writer not ready"
            case .alreadyWriting:
                return "Already writing to file"
            case .notWriting:
                return "Not currently writing"
            case .finalizationFailed:
                return "Failed to finalize recording"
            }
        }
    }
    
    // MARK: - Properties
    
    // Separate writers for system audio and microphone (CAF doesn't support multiple tracks)
    private var systemWriter: AVAssetWriter?
    private var systemAudioInput: AVAssetWriterInput?
    private var systemSessionStarted = false
    
    private var micWriter: AVAssetWriter?
    private var microphoneInput: AVAssetWriterInput?
    private var micSessionStarted = false
    
    private var outputDirectory: URL?
    
    private var _isWriting = false
    var isWriting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isWriting
    }
    
    // Thread safety lock for buffer writing
    private let lock = NSLock()
    
    // Buffer queues for handling backpressure (when writer isn't ready)
    private var systemBufferQueue: [CMSampleBuffer] = []
    private var micBufferQueue: [CMSampleBuffer] = []
    private let maxQueuedBuffers = 10  // ~200ms of audio at typical buffer sizes
    
    /// Callback for file output warnings (message, details)
    var onWarning: ((String, String) -> Void)?
    
    // Configurable base output path
    private var customOutputPath: URL?
    
    // Default output path (Application Support - no special permissions required)
    private static let defaultOutputPath: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Muesli/Recordings", isDirectory: true)
    }()
    
    // Current base output path (custom or default)
    private var baseOutputPath: URL {
        customOutputPath ?? Self.defaultOutputPath
    }
    
    // MARK: - Initialization
    
    init() {
        // Load saved output directory from UserDefaults
        if let savedPath = UserDefaults.standard.string(forKey: "outputDirectory") {
            customOutputPath = URL(fileURLWithPath: savedPath)
        }
    }
    
    // MARK: - Output Directory Configuration
    
    /// Set a custom output directory
    func setOutputDirectory(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        customOutputPath = url
    }
    
    /// Get the current output directory
    func getOutputDirectory() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return baseOutputPath
    }
    
    // MARK: - Public API
    
    /// Start writing audio to a new file
    /// - Parameter segmentNumber: Optional segment number (1 = first segment, 2+ = resumed segments). Defaults to 1.
    /// - Returns: The URL of the output directory
    func startWriting(segmentNumber: Int = 1) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        
        guard !_isWriting else {
            throw OutputError.alreadyWriting
        }
        
        // Create output directory
        let directory = try createOutputDirectory()
        self.outputDirectory = directory
        
        do {
            // Create TWO separate writers - CAF doesn't support multiple audio tracks
            
            // Determine filenames based on segment number
            let systemFilename = segmentNumber == 1 ? "audio.caf" : "audio_\(segmentNumber).caf"
            let micFilename = segmentNumber == 1 ? "microphone.caf" : "microphone_\(segmentNumber).caf"
            
            // Writer 1: System audio (48kHz, stereo, Float32)
            let systemURL = directory.appendingPathComponent(systemFilename)
            // Delete existing file if present (AVAssetWriter fails if file exists)
            try? FileManager.default.removeItem(at: systemURL)
            let sysWriter = try AVAssetWriter(outputURL: systemURL, fileType: .caf)
            
            let systemSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: systemSettings)
            sysInput.expectsMediaDataInRealTime = true
            sysWriter.add(sysInput)
            sysWriter.startWriting()
            
            // Check system writer started successfully
            guard sysWriter.status == .writing else {
                throw OutputError.assetWriterNotReady
            }
            
            // Writer 2: Microphone audio (48kHz, stereo, Float32 - high fidelity)
            let micURL = directory.appendingPathComponent(micFilename)
            // Delete existing file if present
            try? FileManager.default.removeItem(at: micURL)
            let micWr = try AVAssetWriter(outputURL: micURL, fileType: .caf)
            
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micIn.expectsMediaDataInRealTime = true
            micWr.add(micIn)
            micWr.startWriting()
            
            // Check mic writer started successfully
            guard micWr.status == .writing else {
                throw OutputError.assetWriterNotReady
            }
            
            self.systemWriter = sysWriter
            self.systemAudioInput = sysInput
            self.systemSessionStarted = false
            self.systemBufferQueue = []  // Clear any stale buffers
            
            self.micWriter = micWr
            self.microphoneInput = micIn
            self.micSessionStarted = false
            self.micBufferQueue = []  // Clear any stale buffers
            
            self._isWriting = true
            
            return directory
        } catch {
            throw OutputError.assetWriterCreationFailed(underlying: error)
        }
    }
    
    /// Append an audio sample buffer to the file
    /// - Parameters:
    ///   - buffer: The audio sample buffer to write
    ///   - type: Whether this is system audio or microphone audio
    /// This method is thread-safe and can be called from any thread
    func appendAudioBuffer(_ buffer: CMSampleBuffer, type: AudioCaptureService.AudioType) {
        lock.lock()
        defer { lock.unlock() }
        
        guard _isWriting else { return }
        
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(buffer)
        
        // #region agent log
        // Sample the incoming buffer to check for non-zero data
        var maxSample: Float = 0.0
        var sampleCount = 0
        if let dataBuffer = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            if status == noErr, let data = dataPointer {
                let floatCount = length / 4
                sampleCount = floatCount
                let floatPointer = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
                for i in 0..<min(floatCount, 100) {
                    let absVal = abs(floatPointer[i])
                    if absVal > maxSample { maxSample = absVal }
                }
            }
        }
        struct FileLogCounter { nonisolated(unsafe) static var system = 0; nonisolated(unsafe) static var mic = 0; nonisolated(unsafe) static var micFirstLogged = false }
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let typeStr = type == .system ? "system" : "microphone"
        if type == .system { FileLogCounter.system += 1 } else { FileLogCounter.mic += 1 }
        let counter = type == .system ? FileLogCounter.system : FileLogCounter.mic
        // Log first mic buffer unconditionally
        if type == .microphone && !FileLogCounter.micFirstLogged {
            FileLogCounter.micFirstLogged = true
            let firstLogEntry = "{\"hypothesisId\":\"E\",\"location\":\"FileOutputService.appendAudioBuffer\",\"message\":\"FIRST microphone buffer received\",\"data\":{\"maxSample\":\(maxSample),\"sampleCount\":\(sampleCount),\"isWriting\":\(_isWriting)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let firstData = firstLogEntry.data(using: .utf8) {
                if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
                if let firstHandle = FileHandle(forWritingAtPath: logPath) { firstHandle.seekToEndOfFile(); firstHandle.write(firstData); firstHandle.closeFile() }
            }
        }
        if counter <= 3 || counter % 100 == 0 {
            let logEntry = "{\"hypothesisId\":\"D\",\"location\":\"FileOutputService.appendAudioBuffer\",\"message\":\"Buffer received for writing\",\"data\":{\"type\":\"\(typeStr)\",\"maxSample\":\(maxSample),\"sampleCount\":\(sampleCount),\"bufferNum\":\(counter)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
            if let data = logEntry.data(using: .utf8) {
                if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
                if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
            }
        }
        // #endregion
        
        switch type {
        case .system:
            guard let writer = systemWriter, let input = systemAudioInput else { return }
            guard writer.status == .writing else { return }
            
            if !systemSessionStarted {
                writer.startSession(atSourceTime: presentationTime)
                systemSessionStarted = true
            }
            
            // Add new buffer to queue
            systemBufferQueue.append(buffer)
            
            // Drain queue while writer is ready
            drainBufferQueue(&systemBufferQueue, to: input)
            
        case .microphone:
            // #region agent log
            struct MicWriterLogTracker { nonisolated(unsafe) static var firstWriteLogged = false }
            if !MicWriterLogTracker.firstWriteLogged {
                MicWriterLogTracker.firstWriteLogged = true
                let writerNil = micWriter == nil
                let inputNil = microphoneInput == nil
                let writerStatus = micWriter?.status.rawValue ?? -1
                let logEntry = "{\"hypothesisId\":\"E\",\"location\":\"FileOutputService.appendAudioBuffer.microphone\",\"message\":\"First mic write attempt\",\"data\":{\"micWriterNil\":\(writerNil),\"micInputNil\":\(inputNil),\"writerStatus\":\(writerStatus),\"micSessionStarted\":\(micSessionStarted)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
                if let data = logEntry.data(using: .utf8) {
                    if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
                }
            }
            // #endregion
            
            guard let writer = micWriter, let input = microphoneInput else { return }
            guard writer.status == .writing else { return }
            
            if !micSessionStarted {
                // #region agent log
                let sessionLogEntry = "{\"hypothesisId\":\"E\",\"location\":\"FileOutputService.appendAudioBuffer.microphone\",\"message\":\"Starting mic session\",\"data\":{\"presentationTime\":\(presentationTime.seconds)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000)}\n"
                if let sessionData = sessionLogEntry.data(using: .utf8) {
                    if let sessionHandle = FileHandle(forWritingAtPath: logPath) { sessionHandle.seekToEndOfFile(); sessionHandle.write(sessionData); sessionHandle.closeFile() }
                }
                // #endregion
                writer.startSession(atSourceTime: presentationTime)
                micSessionStarted = true
            }
            
            // Add new buffer to queue
            micBufferQueue.append(buffer)
            
            // Drain queue while writer is ready
            drainBufferQueue(&micBufferQueue, to: input)
        }
    }
    
    /// Drain buffer queue to writer input, dropping oldest if queue overflows
    /// Call with lock held
    private func drainBufferQueue(_ queue: inout [CMSampleBuffer], to input: AVAssetWriterInput) {
        // Write as many queued buffers as possible
        while !queue.isEmpty && input.isReadyForMoreMediaData {
            let buffer = queue.removeFirst()
            let success = input.append(buffer)
            
            // If append failed, the writer can no longer accept input
            // Re-queue the buffer and break to avoid dropping subsequent buffers
            if !success {
                queue.insert(buffer, at: 0)
                break
            }
        }
        
        // If queue is overflowing, drop oldest buffers with warning
        // This is a last resort - means we're falling seriously behind
        if queue.count > maxQueuedBuffers {
            let dropCount = queue.count - maxQueuedBuffers
            logger.warning("Dropping \(dropCount) audio buffers due to write backpressure")
            
            // Propagate warning to UI
            let details = """
                Audio buffer overflow - dropping oldest buffers.
                Dropped: \(dropCount) buffers
                Queue size: \(maxQueuedBuffers)
                
                This may indicate disk write speed issues or high system load.
                Some audio data may be lost.
                """
            onWarning?("Audio buffers dropped", details)
            
            queue.removeFirst(dropCount)
        }
    }
    
    /// Stop writing and finalize both audio files
    /// - Parameter completion: Called with the output directory URL on success, or error on failure
    func stopWriting(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        lock.lock()
        
        guard _isWriting else {
            lock.unlock()
            completion(.failure(OutputError.notWriting))
            return
        }
        
        guard let directory = outputDirectory else {
            lock.unlock()
            completion(.failure(OutputError.notWriting))
            return
        }
        
        // Final drain of any remaining queued buffers
        if let input = systemAudioInput {
            drainBufferQueue(&systemBufferQueue, to: input)
            if !self.systemBufferQueue.isEmpty {
                let count = self.systemBufferQueue.count
                logger.warning("\(count) system audio buffers lost on stop")
                
                let details = """
                    \(count) system audio buffers could not be written.
                    Some audio data at the end of the recording may be lost.
                    """
                onWarning?("Audio data lost on stop", details)
            }
        }
        if let input = microphoneInput {
            drainBufferQueue(&micBufferQueue, to: input)
            if !self.micBufferQueue.isEmpty {
                let count = self.micBufferQueue.count
                logger.warning("\(count) microphone audio buffers lost on stop")
                
                let details = """
                    \(count) microphone audio buffers could not be written.
                    Some audio data at the end of the recording may be lost.
                    """
                onWarning?("Audio data lost on stop", details)
            }
        }
        
        // Mark inputs as finished
        if systemSessionStarted {
            systemAudioInput?.markAsFinished()
        }
        if micSessionStarted {
            microphoneInput?.markAsFinished()
        }
        
        // Capture writers for finalization
        let sysWr = systemWriter
        let micWr = micWriter
        
        // Clear state before unlocking
        self.systemWriter = nil
        self.systemAudioInput = nil
        self.systemSessionStarted = false
        self.systemBufferQueue = []
        self.micWriter = nil
        self.microphoneInput = nil
        self.micSessionStarted = false
        self.micBufferQueue = []
        self._isWriting = false
        
        lock.unlock()
        
        // Finalize both writers
        let group = DispatchGroup()
        var finalSuccess = true
        
        if let sysWr = sysWr {
            group.enter()
            sysWr.finishWriting {
                if sysWr.status != .completed { finalSuccess = false }
                group.leave()
            }
        }
        
        if let micWr = micWr {
            group.enter()
            micWr.finishWriting {
                if micWr.status != .completed { finalSuccess = false }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            if finalSuccess {
                completion(.success(directory))
            } else {
                completion(.failure(OutputError.finalizationFailed))
            }
        }
    }
    
    /// Async wrapper for stopWriting
    func stopWriting() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            stopWriting { result in
                continuation.resume(with: result)
            }
        }
    }
    
    /// Resume writing to an existing directory with a new segment
    /// - Parameters:
    ///   - directory: The existing output directory
    ///   - segmentNumber: The segment number (2, 3, 4, etc.)
    /// - Returns: The URL of the output directory
    func resumeWriting(to directory: URL, segmentNumber: Int) throws -> URL {
        guard segmentNumber > 1 else {
            throw OutputError.notWriting
        }
        
        // Verify directory exists
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw OutputError.directoryCreationFailed
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        guard !_isWriting else {
            throw OutputError.alreadyWriting
        }
        
        self.outputDirectory = directory
        
        do {
            // Determine filenames based on segment number
            let systemFilename = "audio_\(segmentNumber).caf"
            let micFilename = "microphone_\(segmentNumber).caf"
            
            // Writer 1: System audio (48kHz, stereo, Float32)
            let systemURL = directory.appendingPathComponent(systemFilename)
            // Delete existing file if present (AVAssetWriter fails if file exists)
            try? FileManager.default.removeItem(at: systemURL)
            let sysWriter = try AVAssetWriter(outputURL: systemURL, fileType: .caf)
            
            let systemSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: systemSettings)
            sysInput.expectsMediaDataInRealTime = true
            sysWriter.add(sysInput)
            sysWriter.startWriting()
            
            // Check system writer started successfully
            guard sysWriter.status == .writing else {
                throw OutputError.assetWriterNotReady
            }
            
            // Writer 2: Microphone audio (48kHz, stereo, Float32 - high fidelity)
            let micURL = directory.appendingPathComponent(micFilename)
            // Delete existing file if present
            try? FileManager.default.removeItem(at: micURL)
            let micWr = try AVAssetWriter(outputURL: micURL, fileType: .caf)
            
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micIn.expectsMediaDataInRealTime = true
            micWr.add(micIn)
            micWr.startWriting()
            
            // Check mic writer started successfully
            guard micWr.status == .writing else {
                throw OutputError.assetWriterNotReady
            }
            
            self.systemWriter = sysWriter
            self.systemAudioInput = sysInput
            self.systemSessionStarted = false
            self.systemBufferQueue = []  // Clear any stale buffers
            
            self.micWriter = micWr
            self.microphoneInput = micIn
            self.micSessionStarted = false
            self.micBufferQueue = []  // Clear any stale buffers
            
            self._isWriting = true
            
            return directory
        } catch {
            throw OutputError.assetWriterCreationFailed(underlying: error)
        }
    }
    
    /// Save transcript to markdown file (legacy plain text format)
    /// - Parameters:
    ///   - transcript: The transcript text
    ///   - title: Meeting title
    ///   - date: Recording date
    ///   - directory: Output directory
    func saveTranscript(_ transcript: String, title: String, date: Date, to directory: URL) throws {
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        
        let markdown = """
        # \(title.isEmpty ? "Meeting" : title)
        \(dateFormatter.string(from: date))
        
        ## Transcript
        
        \(transcript.isEmpty ? "_No transcript recorded_" : transcript)
        """
        
        try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }
    
    /// Save transcript blocks to markdown file (chat-style block format)
    /// - Parameters:
    ///   - blocks: Array of transcript blocks to save
    ///   - title: Meeting title
    ///   - date: Recording date
    ///   - directory: Output directory
    ///   - filename: Optional filename (defaults to "transcript.md" if nil)
    func saveTranscriptBlocks(
        _ blocks: [TranscriptBlock],
        title: String,
        date: Date,
        to directory: URL,
        filename: String? = nil
    ) throws {
        let actualFilename = filename ?? "transcript.md"
        let transcriptURL = directory.appendingPathComponent(actualFilename)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        
        var markdown = """
        # \(title.isEmpty ? "Meeting" : title)
        \(dateFormatter.string(from: date))
        
        ## Transcript
        
        """
        
        if blocks.isEmpty {
            markdown += "_No transcript recorded_"
        } else {
            for block in blocks {
                let speakerLabel = block.speaker == .me ? "**Me**" : "**Them**"
                let timestamp = TimeFormatting.formatTimestamp(block.startTimestamp, style: .compact)
                
                markdown += """
                
                \(speakerLabel) _[\(timestamp)]_
                
                \(block.text)
                
                """
            }
        }
        
        try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Private Helpers
    
    private func createOutputDirectory() throws -> URL {
        let fileManager = FileManager.default
        let basePath = baseOutputPath
        
        // Ensure base directory exists
        if !fileManager.fileExists(atPath: basePath.path) {
            try fileManager.createDirectory(at: basePath, withIntermediateDirectories: true)
        }
        
        // Create folder name with timestamp and UUID for uniqueness
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = dateFormatter.string(from: Date())
        let uuid = UUID().uuidString
        let folderName = "\(timestamp)_\(uuid)"
        
        let directory = basePath.appendingPathComponent(folderName, isDirectory: true)
        
        // Create the directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        
        return directory
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        // Remove or replace characters that aren't safe for filenames
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        var sanitized = name.components(separatedBy: invalidChars).joined(separator: "-")
        
        // Replace spaces with hyphens
        sanitized = sanitized.replacingOccurrences(of: " ", with: "-")
        
        // Limit length
        if sanitized.count > 50 {
            sanitized = String(sanitized.prefix(50))
        }
        
        // Default if empty
        if sanitized.isEmpty {
            sanitized = "Meeting"
        }
        
        return sanitized
    }
}
