import Foundation
import CoreMedia
@testable import Muesli_vmr

/// Mock implementation of FileOutputService for testing
final class MockFileOutputService: FileOutputServiceProtocol, @unchecked Sendable {
    
    // MARK: - State
    
    private(set) var _isWriting: Bool = false
    var isWriting: Bool { _isWriting }
    
    private var outputDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MockMeetingTranscripts")
    private var currentWriteDirectory: URL?
    
    // MARK: - Test Control Properties
    
    var shouldFailStartWriting: Bool = false
    var startWritingError: Error = FileOutputService.OutputError.directoryCreationFailed
    var shouldFailStopWriting: Bool = false
    var stopWritingError: Error = FileOutputService.OutputError.finalizationFailed
    var shouldFailResumeWriting: Bool = false
    var resumeWritingError: Error = FileOutputService.OutputError.directoryCreationFailed
    var shouldFailSaveTranscript: Bool = false
    var saveTranscriptError: Error = NSError(domain: "MockFileOutputService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock save error"])
    
    // MARK: - Call Tracking
    
    var startWritingCallCount: Int = 0
    var stopWritingCallCount: Int = 0
    var appendAudioBufferCallCount: Int = 0
    var resumeWritingCallCount: Int = 0
    var saveTranscriptCallCount: Int = 0
    var saveTranscriptBlocksCallCount: Int = 0
    var setOutputDirectoryCallCount: Int = 0
    
    var lastSegmentNumber: Int?
    var lastSavedTranscript: String?
    var lastSavedBlocks: [TranscriptBlock]?
    var lastSavedTitle: String?
    var lastSavedFilename: String?
    var appendedBufferTypes: [AudioCaptureService.AudioType] = []
    
    // MARK: - FileOutputServiceProtocol
    
    func setOutputDirectory(_ url: URL) {
        setOutputDirectoryCallCount += 1
        outputDirectory = url
    }
    
    func getOutputDirectory() -> URL {
        return outputDirectory
    }
    
    func startWriting(segmentNumber: Int = 1) throws -> URL {
        startWritingCallCount += 1
        lastSegmentNumber = segmentNumber
        
        if shouldFailStartWriting {
            throw startWritingError
        }
        
        // Create a unique directory for this recording
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = dateFormatter.string(from: Date())
        let uuid = UUID().uuidString
        let folderName = "\(timestamp)_\(uuid)"
        
        let directory = outputDirectory.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        currentWriteDirectory = directory
        _isWriting = true
        return directory
    }
    
    func appendAudioBuffer(_ buffer: CMSampleBuffer, type: AudioCaptureService.AudioType) {
        appendAudioBufferCallCount += 1
        appendedBufferTypes.append(type)
    }
    
    func stopWriting() async throws -> URL {
        stopWritingCallCount += 1
        
        if shouldFailStopWriting {
            throw stopWritingError
        }
        
        _isWriting = false
        return currentWriteDirectory ?? outputDirectory
    }
    
    func resumeWriting(to directory: URL, segmentNumber: Int) throws -> URL {
        resumeWritingCallCount += 1
        lastSegmentNumber = segmentNumber
        
        if shouldFailResumeWriting {
            throw resumeWritingError
        }
        
        currentWriteDirectory = directory
        _isWriting = true
        return directory
    }
    
    func saveTranscript(_ transcript: String, title: String, date: Date, to directory: URL) throws {
        saveTranscriptCallCount += 1
        lastSavedTranscript = transcript
        lastSavedTitle = title
        
        if shouldFailSaveTranscript {
            throw saveTranscriptError
        }
    }
    
    func saveTranscriptBlocks(_ blocks: [TranscriptBlock], title: String, date: Date, to directory: URL, filename: String = "transcript.md") throws {
        saveTranscriptBlocksCallCount += 1
        lastSavedBlocks = blocks
        lastSavedTitle = title
        lastSavedFilename = filename
        
        if shouldFailSaveTranscript {
            throw saveTranscriptError
        }
    }
    
    // MARK: - Test Helpers
    
    /// Reset all state for next test
    func reset() {
        _isWriting = false
        currentWriteDirectory = nil
        shouldFailStartWriting = false
        shouldFailStopWriting = false
        shouldFailResumeWriting = false
        shouldFailSaveTranscript = false
        startWritingCallCount = 0
        stopWritingCallCount = 0
        appendAudioBufferCallCount = 0
        resumeWritingCallCount = 0
        saveTranscriptCallCount = 0
        saveTranscriptBlocksCallCount = 0
        setOutputDirectoryCallCount = 0
        lastSegmentNumber = nil
        lastSavedTranscript = nil
        lastSavedBlocks = nil
        lastSavedTitle = nil
        lastSavedFilename = nil
        appendedBufferTypes = []
    }
}
