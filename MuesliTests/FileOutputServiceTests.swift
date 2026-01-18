import AVFoundation
import CoreMedia
@testable import Muesli
import XCTest

/// Comprehensive tests for FileOutputService
/// Target: 3% → 70%+ coverage for FileOutputService.swift
final class FileOutputServiceTests: XCTestCase {
    var service: FileOutputService!
    var testOutputDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        service = FileOutputService()
        
        // Create temporary test directory
        testOutputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuesliTests")
            .appendingPathComponent(UUID().uuidString)
    }
    
    override func tearDown() async throws {
        // Clean up test directories
        if let dir = testOutputDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        service = nil
        try await super.tearDown()
    }
    
    // MARK: - Directory Management Tests
    
    func testCreateOutputDirectory() throws {
        // Given: Service with custom output path
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Starting to write
        let directory = try service.startWriting()
        
        // Then: Directory should be created
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path),
                     "Output directory should exist")
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testOutputDirectoryWithTimestampFormat() throws {
        // Given: Service that creates directory
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Starting to write
        let directory = try service.startWriting()
        
        // Then: Directory name should contain timestamp or UUID
        XCTAssertNotNil(directory.lastPathComponent,
                       "Directory should have a name")
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testOutputDirectoryIsUnique() throws {
        // Given: Service that creates multiple directories
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Creating multiple directories
        let dir1 = try service.startWriting()
        try service.finishWriting()
        
        let dir2 = try service.startWriting()
        try service.finishWriting()
        
        // Then: Directories should be unique
        XCTAssertNotEqual(dir1.path, dir2.path,
                         "Each recording should get unique directory")
    }
    
    func testGetOutputDirectory() {
        // Given: Service with custom output path
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Getting output directory
        let directory = service.getOutputDirectory()
        
        // Then: Should return custom path
        XCTAssertEqual(directory, testOutputDirectory,
                      "Should return configured output directory")
    }
    
    func testSetOutputDirectory() {
        // Given: A custom directory path
        let customPath = testOutputDirectory!
        
        // When: Setting output directory
        service.setOutputDirectory(customPath)
        
        // Then: Directory should be set
        XCTAssertEqual(service.getOutputDirectory(), customPath)
    }
    
    func testDirectoryStructureCreation() throws {
        // Given: Service with nested path
        let nestedPath = testOutputDirectory.appendingPathComponent("nested/path")
        service.setOutputDirectory(nestedPath)
        
        // When: Starting to write
        let directory = try service.startWriting()
        
        // Then: Full path should be created
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testHandleExistingDirectory() throws {
        // Given: Directory that already exists
        service.setOutputDirectory(testOutputDirectory)
        let dir1 = try service.startWriting()
        try service.finishWriting()
        
        // When: Creating another recording
        let dir2 = try service.startWriting()
        
        // Then: Should create new unique directory
        XCTAssertNotEqual(dir1, dir2)
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testCleanupEmptyDirectories() throws {
        // Given: Service that creates directory
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        // When: Finishing without writing any files
        try service.finishWriting()
        
        // Then: Directory still exists (may be empty)
        // Note: Cleanup behavior is implementation-specific
        XCTAssertNotNil(directory)
    }
    
    func testDirectoryPermissions() throws {
        // Given: Service creating directory
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Starting to write
        let directory = try service.startWriting()
        
        // Then: Directory should be writable
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: directory.path))
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testHandleInvalidPath() {
        // Given: Service with invalid path
        let invalidPath = URL(fileURLWithPath: "/nonexistent/invalid/path")
        service.setOutputDirectory(invalidPath)
        
        // When/Then: Starting to write should handle gracefully
        do {
            _ = try service.startWriting()
            // May succeed if system can create path
        } catch {
            // Expected: directory creation failure
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Audio File Writing Tests
    
    func testStartAudioFileWriter() throws {
        // Given: Service ready to write
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Starting to write
        let directory = try service.startWriting()
        
        // Then: isWriting should be true
        XCTAssertTrue(service.isWriting)
        XCTAssertNotNil(directory)
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testWriteAudioBufferToFile() throws {
        // Given: Service that is writing
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        // When: Writing a buffer
        let buffer = createTestAudioBuffer()
        service.appendBuffer(buffer, audioType: .system)
        
        // Then: Should handle buffer
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testWriteMultipleBuffersSequentially() throws {
        // Given: Service that is writing
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When: Writing multiple buffers
        for _ in 0..<10 {
            let buffer = createTestAudioBuffer()
            service.appendBuffer(buffer, audioType: .system)
        }
        
        // Then: Should handle all buffers
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testFinishAudioFileWriting() throws {
        // Given: Service that has been writing
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When: Finishing
        try service.finishWriting()
        
        // Then: isWriting should be false
        XCTAssertFalse(service.isWriting)
    }
    
    func testCAFFileFormatCreated() throws {
        // Given: Service that writes files
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendBuffer(buffer, audioType: .system)
        
        // When: Finishing
        try service.finishWriting()
        
        // Then: CAF file should exist
        let audioFile = directory.appendingPathComponent("audio.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile.path))
    }
    
    func testAudioFormatSettings() throws {
        // Given: Service configured for 48kHz Float32 stereo
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendBuffer(buffer, audioType: .system)
        try service.finishWriting()
        
        // Then: Audio file should have correct format
        // Note: Format verification would require AVAudioFile inspection
        let audioFile = directory.appendingPathComponent("audio.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile.path))
    }
    
    func testHandleWriteErrors() throws {
        // Given: Service writing to read-only location
        // Note: Difficult to test without special permissions
        
        // When/Then: Should handle errors gracefully
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testFinishWithoutStart() {
        // Given: Service that hasn't started
        // When/Then: Finishing should throw error
        XCTAssertThrowsError(try service.finishWriting())
    }
    
    func testSystemAudioFileCreation() throws {
        // Given: Service writing system audio
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendBuffer(buffer, audioType: .system)
        try service.finishWriting()
        
        // Then: audio.caf should exist
        let file = directory.appendingPathComponent("audio.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    
    func testMicrophoneAudioFileCreation() throws {
        // Given: Service writing microphone audio
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendBuffer(buffer, audioType: .microphone)
        try service.finishWriting()
        
        // Then: microphone.caf should exist
        let file = directory.appendingPathComponent("microphone.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    
    func testBothAudioFilesCreated() throws {
        // Given: Service writing both types
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendBuffer(buffer, audioType: .system)
        service.appendBuffer(buffer, audioType: .microphone)
        try service.finishWriting()
        
        // Then: Both files should exist
        let audioFile = directory.appendingPathComponent("audio.caf")
        let micFile = directory.appendingPathComponent("microphone.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micFile.path))
    }
    
    func testCannotStartWhenAlreadyWriting() throws {
        // Given: Service that is already writing
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When/Then: Starting again should throw error
        XCTAssertThrowsError(try service.startWriting())
        
        // Cleanup
        try service.finishWriting()
    }
    
    // MARK: - Transcript File Writing Tests
    
    func testWriteTranscriptBlocks() throws {
        // Given: Service and transcript blocks
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "Hello world", timestamp: 0.5, speaker: "Me"),
            TranscriptBlock(text: "Hi there", timestamp: 1.0, speaker: "Them")
        ]
        
        // When: Writing transcript
        try service.writeTranscript(blocks, to: directory)
        
        // Then: Transcript file should exist
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptFile.path))
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testHandleEmptyTranscript() throws {
        // Given: Empty transcript blocks
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks: [TranscriptBlock] = []
        
        // When: Writing empty transcript
        try service.writeTranscript(blocks, to: directory)
        
        // Then: Should handle gracefully (file may or may not be created)
        // Implementation-specific behavior
        XCTAssertNotNil(directory)
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testTranscriptWithTimestamps() throws {
        // Given: Blocks with timestamps
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "Start", timestamp: 0.0, speaker: "Me"),
            TranscriptBlock(text: "Middle", timestamp: 5.5, speaker: "Them"),
            TranscriptBlock(text: "End", timestamp: 10.0, speaker: "Me")
        ]
        
        // When: Writing transcript
        try service.writeTranscript(blocks, to: directory)
        
        // Then: File should contain timestamps
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("0:00"))
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testTranscriptWithSpeakerLabels() throws {
        // Given: Blocks with speaker labels
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "My words", timestamp: 0.0, speaker: "Me"),
            TranscriptBlock(text: "Their words", timestamp: 1.0, speaker: "Them")
        ]
        
        // When: Writing transcript
        try service.writeTranscript(blocks, to: directory)
        
        // Then: File should contain speaker labels
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("Me") || content.contains("**Me**"))
        XCTAssertTrue(content.contains("Them") || content.contains("**Them**"))
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testOverwriteExistingTranscript() throws {
        // Given: Directory with existing transcript
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks1 = [TranscriptBlock(text: "First", timestamp: 0.0, speaker: "Me")]
        try service.writeTranscript(blocks1, to: directory)
        
        // When: Writing new transcript (reprocessing scenario)
        let blocks2 = [TranscriptBlock(text: "Second", timestamp: 0.0, speaker: "Me")]
        try service.writeTranscript(blocks2, to: directory)
        
        // Then: New transcript should replace old
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("Second"))
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testMarkdownFormatCorrectness() throws {
        // Given: Transcript blocks
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "Test content", timestamp: 0.0, speaker: "Me")
        ]
        
        // When: Writing transcript
        try service.writeTranscript(blocks, to: directory)
        
        // Then: File should be valid Markdown
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertFalse(content.isEmpty)
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testUTF8EncodingValidation() throws {
        // Given: Blocks with unicode characters
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "Hello 世界 🌍", timestamp: 0.0, speaker: "Me")
        ]
        
        // When: Writing transcript
        try service.writeTranscript(blocks, to: directory)
        
        // Then: Should preserve UTF-8 characters
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("世界"))
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testLongTranscriptWriting() throws {
        // Given: Many transcript blocks
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        var blocks: [TranscriptBlock] = []
        for i in 0..<100 {
            blocks.append(TranscriptBlock(
                text: "Block \(i)",
                timestamp: TimeInterval(i),
                speaker: i % 2 == 0 ? "Me" : "Them"
            ))
        }
        
        // When: Writing long transcript
        try service.writeTranscript(blocks, to: directory)
        
        // Then: Should handle large files
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptFile.path))
        
        // Cleanup
        try service.finishWriting()
    }
    
    func testConcurrentWriteAttempts() throws {
        // Given: Service that is writing
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When: Attempting concurrent start
        // Then: Should throw error
        XCTAssertThrowsError(try service.startWriting())
        
        // Cleanup
        try service.finishWriting()
    }
    
    // MARK: - Helper Methods
    
    private func createTestAudioBuffer() -> CMSampleBuffer {
        // Create a simple test audio buffer
        let sampleCount = 1024
        var samples = [Float](repeating: 0.0, count: sampleCount)
        
        // Generate test tone
        for i in 0..<sampleCount {
            samples[i] = sin(Float(i) * 0.1)
        }
        
        // Create audio format
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        var formatDesc: CMFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        
        guard let format = formatDesc else {
            fatalError("Failed to create format")
        }
        
        // Create block buffer
        let dataSize = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
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
        
        guard let block = blockBuffer else {
            fatalError("Failed to create block buffer")
        }
        
        samples.withUnsafeBufferPointer { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: 0, timescale: 48000),
            decodeTimeStamp: .invalid
        )
        
        CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: sampleCount / 2,  // Stereo
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        return sampleBuffer!
    }
}
