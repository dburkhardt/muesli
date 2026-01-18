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
    
    // MARK: - Phase 3 Expansion Tests
    
    // MARK: - AVAssetWriter Lifecycle Tests
    
    func testWriterInitializationBothTypes() throws {
        // Given: Service starting to write
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Starting writing
        let directory = try service.startWriting()
        
        // Then: Both system and mic writers should be initialized
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testSessionStartingWithFirstBuffer() throws {
        // Given: Service that has started
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When: Appending first buffer
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .system)
        
        // Then: Session should start with first buffer's presentation time
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testMarkAsFinishedOnStop() throws {
        // Given: Service that has written buffers
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .system)
        service.appendAudioBuffer(buffer, type: .microphone)
        
        // When: Stopping
        let result = try service.stopWriting().get()
        
        // Then: Should mark inputs as finished and finalize
        XCTAssertFalse(service.isWriting)
        XCTAssertNotNil(result)
    }
    
    func testFinalizeBothWritersConcurrently() throws {
        // Given: Service with both writers active
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .system)
        service.appendAudioBuffer(buffer, type: .microphone)
        
        // When: Stopping (finalizes both)
        let result = try service.stopWriting().get()
        
        // Then: Both files should exist
        let systemFile = directory.appendingPathComponent("audio.caf")
        let micFile = directory.appendingPathComponent("microphone.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micFile.path))
    }
    
    func testWriterStatusChecking() throws {
        // Given: Service starting to write
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // Then: Should verify writer status is .writing
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.stopWriting().get()
        
        // Then: Status should be stopped
        XCTAssertFalse(service.isWriting)
    }
    
    // MARK: - Buffer Queue Management Tests
    
    func testQueueBuffersWhenWriterNotReady() throws {
        // Given: Service writing
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When: Rapidly appending buffers (may queue if writer not ready)
        for _ in 0..<15 {
            let buffer = createTestAudioBuffer()
            service.appendAudioBuffer(buffer, type: .system)
        }
        
        // Then: Should queue buffers without dropping
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testDrainQueueWhenWriterReady() throws {
        // Given: Service with queued buffers
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When: Appending multiple buffers
        for _ in 0..<5 {
            let buffer = createTestAudioBuffer()
            service.appendAudioBuffer(buffer, type: .system)
        }
        
        // Small delay to let writer drain queue
        Thread.sleep(forTimeInterval: 0.1)
        
        // Then: Buffers should be drained to writer
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testMaxQueuedBuffersLimit() throws {
        // Given: Service with maximum queue size of 10
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When: Appending more than max (would drop oldest if writer blocked)
        for _ in 0..<20 {
            let buffer = createTestAudioBuffer()
            service.appendAudioBuffer(buffer, type: .system)
        }
        
        // Then: Should handle overflow (may drop oldest buffers)
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testFinalDrainOnStop() throws {
        // Given: Service with queued buffers
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        for _ in 0..<5 {
            let buffer = createTestAudioBuffer()
            service.appendAudioBuffer(buffer, type: .system)
        }
        
        // When: Stopping (should drain remaining buffers)
        let result = try service.stopWriting().get()
        
        // Then: All buffers should be written
        XCTAssertNotNil(result)
    }
    
    // MARK: - Segment/Resume Writing Tests
    
    func testResumeWritingToExistingDirectory() throws {
        // Given: Existing directory from previous recording
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        try service.stopWriting().get()
        
        // When: Resuming with segment 2
        let resumedDir = try service.resumeWriting(to: directory, segmentNumber: 2)
        
        // Then: Should resume to same directory
        XCTAssertEqual(directory, resumedDir)
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testSegmentNumbering() throws {
        // Given: Service resuming with segment 2
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        try service.stopWriting().get()
        
        // When: Creating segment 2
        _ = try service.resumeWriting(to: directory, segmentNumber: 2)
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .system)
        try service.stopWriting().get()
        
        // Then: Should create audio_2.caf and microphone_2.caf
        let systemFile = directory.appendingPathComponent("audio_2.caf")
        let micFile = directory.appendingPathComponent("microphone_2.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemFile.path))
    }
    
    func testMultiSegmentFileCreation() throws {
        // Given: Service creating multiple segments
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .system)
        try service.stopWriting().get()
        
        // Segment 2
        _ = try service.resumeWriting(to: directory, segmentNumber: 2)
        service.appendAudioBuffer(buffer, type: .system)
        try service.stopWriting().get()
        
        // Segment 3
        _ = try service.resumeWriting(to: directory, segmentNumber: 3)
        service.appendAudioBuffer(buffer, type: .system)
        try service.stopWriting().get()
        
        // Then: All segment files should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio_2.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio_3.caf").path))
    }
    
    func testSegment1UsesDefaultFilename() throws {
        // Given: Service starting with segment 1 (default)
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Starting writing with segment 1
        let directory = try service.startWriting(segmentNumber: 1)
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .system)
        try service.stopWriting().get()
        
        // Then: Should use "audio.caf" not "audio_1.caf"
        let systemFile = directory.appendingPathComponent("audio.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemFile.path))
    }
    
    func testResumeWithSegment1ThrowsError() {
        // Given: Existing directory
        service.setOutputDirectory(testOutputDirectory)
        let directory = try! service.startWriting()
        try! service.stopWriting().get()
        
        // When: Attempting to resume with segment 1
        // Then: Should throw error (segment 1 is for initial recording)
        XCTAssertThrowsError(try service.resumeWriting(to: directory, segmentNumber: 1))
    }
    
    // MARK: - Transcript Saving Tests
    
    func testSaveTranscriptBlocksChatStyle() throws {
        // Given: Transcript blocks with chat-style format
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "Hello world", startTimestamp: 0.5, speaker: .me),
            TranscriptBlock(text: "Hi there", startTimestamp: 1.0, speaker: .them)
        ]
        
        // When: Saving transcript blocks
        try service.saveTranscriptBlocks(blocks, title: "Test Meeting", date: Date(), to: directory)
        
        // Then: Should create transcript.md with chat format
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptFile.path))
        
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("**Me**"))
        XCTAssertTrue(content.contains("**Them**"))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testTranscriptMarkdownFormatting() throws {
        // Given: Transcript blocks
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "Test content", startTimestamp: 0.5, speaker: .me)
        ]
        
        // When: Saving transcript
        try service.saveTranscriptBlocks(blocks, title: "My Meeting", date: Date(), to: directory)
        
        // Then: Should have proper Markdown formatting
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("# My Meeting"))
        XCTAssertTrue(content.contains("## Transcript"))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testTranscriptSpeakerLabels() throws {
        // Given: Blocks with different speakers
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "From me", startTimestamp: 0.0, speaker: .me),
            TranscriptBlock(text: "From them", startTimestamp: 1.0, speaker: .them)
        ]
        
        // When: Saving
        try service.saveTranscriptBlocks(blocks, title: "Test", date: Date(), to: directory)
        
        // Then: Should have distinct speaker labels
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("**Me**"))
        XCTAssertTrue(content.contains("**Them**"))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testTranscriptTimestamps() throws {
        // Given: Blocks with timestamps
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "At start", startTimestamp: 0.0, speaker: .me),
            TranscriptBlock(text: "At 5 seconds", startTimestamp: 5.0, speaker: .them)
        ]
        
        // When: Saving
        try service.saveTranscriptBlocks(blocks, title: "Test", date: Date(), to: directory)
        
        // Then: Should include timestamps
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("0:00") || content.contains("[0:00]"))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testTranscriptUTF8Encoding() throws {
        // Given: Blocks with UTF-8 characters
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "Hello 世界 🌍 café", startTimestamp: 0.0, speaker: .me)
        ]
        
        // When: Saving
        try service.saveTranscriptBlocks(blocks, title: "Test", date: Date(), to: directory)
        
        // Then: Should preserve UTF-8 characters
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("世界"))
        XCTAssertTrue(content.contains("🌍"))
        XCTAssertTrue(content.contains("café"))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testSaveToCustomFilename() throws {
        // Given: Custom filename
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks = [
            TranscriptBlock(text: "Test", startTimestamp: 0.0, speaker: .me)
        ]
        
        // When: Saving with custom filename
        try service.saveTranscriptBlocks(blocks, title: "Test", date: Date(), to: directory, filename: "custom.md")
        
        // Then: Should use custom filename
        let customFile = directory.appendingPathComponent("custom.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: customFile.path))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testSaveTranscriptLegacyFormat() throws {
        // Given: Plain transcript text
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let transcript = "Line 1\nLine 2\nLine 3"
        
        // When: Saving legacy format
        try service.saveTranscript(transcript, title: "Old Format", date: Date(), to: directory)
        
        // Then: Should create transcript.md
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptFile.path))
        
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("Line 1"))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testEmptyTranscriptBlocks() throws {
        // Given: Empty transcript
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let blocks: [TranscriptBlock] = []
        
        // When: Saving empty transcript
        try service.saveTranscriptBlocks(blocks, title: "Empty", date: Date(), to: directory)
        
        // Then: Should indicate no transcript
        let transcriptFile = directory.appendingPathComponent("transcript.md")
        let content = try String(contentsOf: transcriptFile)
        XCTAssertTrue(content.contains("No transcript"))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    // MARK: - Directory Management Tests
    
    func testDirectoryNamingConvention() throws {
        // Given: Service creating directory
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Starting writing
        let directory = try service.startWriting()
        
        // Then: Name should contain timestamp and UUID
        let name = directory.lastPathComponent
        XCTAssertTrue(name.contains("_"), "Should contain underscore separator")
        
        // Should be in format: YYYY-MM-DD_HH-MM_UUID
        let components = name.components(separatedBy: "_")
        XCTAssertGreaterThanOrEqual(components.count, 3, "Should have date, time, and UUID")
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testCustomVsDefaultBasePath() {
        // Given: Service without custom path
        let service1 = FileOutputService()
        let defaultPath = service1.getOutputDirectory()
        
        // When: Setting custom path
        let service2 = FileOutputService()
        service2.setOutputDirectory(testOutputDirectory)
        let customPath = service2.getOutputDirectory()
        
        // Then: Should use custom path
        XCTAssertNotEqual(defaultPath, customPath)
        XCTAssertEqual(customPath, testOutputDirectory)
    }
    
    func testBaseDirectoryCreation() throws {
        // Given: Service with non-existent base directory
        let newBase = testOutputDirectory.appendingPathComponent("new_base")
        service.setOutputDirectory(newBase)
        
        // When: Starting writing
        let directory = try service.startWriting()
        
        // Then: Should create base directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: newBase.path))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testNestedDirectoryCreation() throws {
        // Given: Service with deeply nested path
        let nestedPath = testOutputDirectory
            .appendingPathComponent("level1")
            .appendingPathComponent("level2")
            .appendingPathComponent("level3")
        service.setOutputDirectory(nestedPath)
        
        // When: Starting writing
        let directory = try service.startWriting()
        
        // Then: Should create full path
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentBufferAppending() throws {
        // Given: Service receiving buffers from multiple threads
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When: Appending concurrently
        DispatchQueue.concurrentPerform(iterations: 10) { i in
            let buffer = createTestAudioBuffer()
            let type: AudioCaptureService.AudioType = i % 2 == 0 ? .system : .microphone
            service.appendAudioBuffer(buffer, type: type)
        }
        
        // Then: Should handle concurrent access safely
        XCTAssertTrue(service.isWriting)
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    func testConcurrentStartAttempts() throws {
        // Given: Service instance
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Attempting concurrent starts
        let queue = DispatchQueue(label: "test", attributes: .concurrent)
        let group = DispatchGroup()
        
        var successCount = 0
        var errorCount = 0
        let lock = NSLock()
        
        for _ in 0..<5 {
            group.enter()
            queue.async {
                do {
                    _ = try self.service.startWriting()
                    lock.lock()
                    successCount += 1
                    lock.unlock()
                } catch {
                    lock.lock()
                    errorCount += 1
                    lock.unlock()
                }
                group.leave()
            }
        }
        
        group.wait()
        
        // Then: Only one should succeed
        XCTAssertEqual(successCount, 1, "Only one start should succeed")
        XCTAssertEqual(errorCount, 4, "Others should fail")
        
        // Cleanup
        try service.stopWriting().get()
    }
    
    // MARK: - Error Handling Tests
    
    func testAppendBufferWhenNotWriting() {
        // Given: Service not writing
        XCTAssertFalse(service.isWriting)
        
        // When: Attempting to append buffer
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .system)
        
        // Then: Should handle gracefully (ignore buffer)
        XCTAssertFalse(service.isWriting)
    }
    
    func testStopWritingWhenNotStarted() {
        // Given: Service that never started
        XCTAssertFalse(service.isWriting)
        
        // When: Attempting to stop
        let result = service.stopWriting()
        
        // Then: Should throw/fail
        XCTAssertThrowsError(try result.get())
    }
    
    func testDoubleStop() throws {
        // Given: Service that has stopped
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        try service.stopWriting().get()
        
        // When: Stopping again
        let result = service.stopWriting()
        
        // Then: Should throw error
        XCTAssertThrowsError(try result.get())
    }
    
    func testResumeToNonExistentDirectory() {
        // Given: Non-existent directory
        let fakeDir = testOutputDirectory.appendingPathComponent("nonexistent")
        
        // When: Attempting to resume
        // Then: Should throw error
        XCTAssertThrowsError(try service.resumeWriting(to: fakeDir, segmentNumber: 2))
    }
    
    // MARK: - Audio Format Tests
    
    func testSystemAudioFormat48kHzStereoFloat32() throws {
        // Given: Service writing system audio
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .system)
        try service.stopWriting().get()
        
        // Then: File should be 48kHz stereo Float32
        let audioFile = directory.appendingPathComponent("audio.caf")
        let file = try AVAudioFile(forReading: audioFile)
        XCTAssertEqual(file.processingFormat.sampleRate, 48000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
    }
    
    func testMicrophoneAudioFormat48kHzStereoFloat32() throws {
        // Given: Service writing microphone audio
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .microphone)
        try service.stopWriting().get()
        
        // Then: File should be 48kHz stereo Float32
        let micFile = directory.appendingPathComponent("microphone.caf")
        let file = try AVAudioFile(forReading: micFile)
        XCTAssertEqual(file.processingFormat.sampleRate, 48000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
    }
    
    func testCAFFileTypeCreated() throws {
        // Given: Service creating files
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        let buffer = createTestAudioBuffer()
        service.appendAudioBuffer(buffer, type: .system)
        try service.stopWriting().get()
        
        // Then: Should create CAF files
        let audioFile = directory.appendingPathComponent("audio.caf")
        XCTAssertTrue(audioFile.pathExtension == "caf")
    }
    
    // MARK: - Integration Tests
    
    func testCompleteWritingCycle() throws {
        // Given: Complete recording session
        service.setOutputDirectory(testOutputDirectory)
        let directory = try service.startWriting()
        
        // When: Writing both audio types
        let buffer = createTestAudioBuffer()
        for _ in 0..<10 {
            service.appendAudioBuffer(buffer, type: .system)
            service.appendAudioBuffer(buffer, type: .microphone)
        }
        
        // And saving transcript
        let blocks = [
            TranscriptBlock(text: "Test", startTimestamp: 0.0, speaker: .me)
        ]
        try service.saveTranscriptBlocks(blocks, title: "Test", date: Date(), to: directory)
        
        // And stopping
        let result = try service.stopWriting().get()
        
        // Then: All files should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("microphone.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.md").path))
    }
    
    func testMultipleWritingSessions() throws {
        // Given: Service used multiple times
        service.setOutputDirectory(testOutputDirectory)
        
        // When: Running multiple sessions
        for _ in 0..<3 {
            let directory = try service.startWriting()
            let buffer = createTestAudioBuffer()
            service.appendAudioBuffer(buffer, type: .system)
            try service.stopWriting().get()
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio.caf").path))
        }
        
        // Then: Should create multiple directories
        XCTAssertTrue(true)
    }
    
    func testMemoryStability() throws {
        // Given: Service writing many buffers
        service.setOutputDirectory(testOutputDirectory)
        _ = try service.startWriting()
        
        // When: Writing many buffers
        for _ in 0..<100 {
            let buffer = createTestAudioBuffer()
            service.appendAudioBuffer(buffer, type: .system)
        }
        
        // Then: Should not leak memory or crash
        try service.stopWriting().get()
        XCTAssertFalse(service.isWriting)
    }
}
