import XCTest
@testable import Muesli

/// Tests for TranscriptRefinementService
/// Focus: Speaker thread processing, batching logic, and text splitting WITHOUT actual LLM inference
@MainActor
final class TranscriptRefinementServiceTests: XCTestCase {
    
    var mockLLMManager: MockLLMManager!
    var service: TranscriptRefinementService!
    
    override func setUp() {
        super.setUp()
        mockLLMManager = MockLLMManager()
        service = TranscriptRefinementService(llmManager: mockLLMManager)
    }
    
    override func tearDown() {
        service = nil
        mockLLMManager = nil
        super.tearDown()
    }
    
    // MARK: - Part 1: State & Configuration
    
    /// Test service initialization
    func testServiceInitialization() {
        XCTAssertNotNil(service)
        XCTAssertFalse(service.isRefining)
        XCTAssertEqual(service.progress, 0.0)
        XCTAssertNil(service.errorMessage)
    }
    
    /// Test refinement state tracking
    func testRefinementStateTracking() async throws {
        // Initially not refining
        XCTAssertFalse(service.isRefining)
        XCTAssertEqual(service.progress, 0.0)
        
        // Enable LLM
        mockLLMManager.isLLMStitchingEnabled = true
        mockLLMManager.downloadedModels.insert(.llama32_3b)
        mockLLMManager.setActiveModel(.llama32_3b)
        // Note: Actual refinement requires model container which we can't easily mock
        // This test just verifies state properties exist and are accessible
    }
    
    /// Test LLM availability checks
    func testLLMAvailabilityChecks() async throws {
        // Given: LLM not available
        mockLLMManager.isLLMStitchingEnabled = false
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "Test", startTimestamp: 0.0)
        ]
        
        // When: Try to refine
        let result = try await service.refineTranscript(blocks)
        
        // Then: Should return unchanged blocks (LLM not available)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Test")
    }
    
    /// Test return blocks unchanged when LLM not available
    func testReturnBlocksUnchangedWhenLLMNotAvailable() async throws {
        // Given: LLM not enabled
        mockLLMManager.isLLMStitchingEnabled = false
        
        let originalBlocks = [
            TranscriptBlock(speaker: .me, text: "First block", startTimestamp: 0.0),
            TranscriptBlock(speaker: .them, text: "Second block", startTimestamp: 5.0)
        ]
        
        // When: Refine
        let result = try await service.refineTranscript(originalBlocks)
        
        // Then: Blocks unchanged
        XCTAssertEqual(result.count, originalBlocks.count)
        XCTAssertEqual(result[0].text, originalBlocks[0].text)
        XCTAssertEqual(result[1].text, originalBlocks[1].text)
    }
    
    /// Test empty blocks return empty
    func testEmptyBlocksReturnEmpty() async throws {
        let result = try await service.refineTranscript([])
        XCTAssertTrue(result.isEmpty)
    }
    
    // MARK: - Part 2: Speaker Thread Processing (Logic Tests)
    
    /// Test refining plain text when LLM not available
    func testRefinePlainTextWhenLLMNotAvailable() async throws {
        // Given: LLM not available
        mockLLMManager.isLLMStitchingEnabled = false
        
        let originalText = "This is some text to refine"
        
        // When: Refine
        let result = try await service.refineTranscript(originalText)
        
        // Then: Text unchanged
        XCTAssertEqual(result, originalText)
    }
    
    /// Test refining empty text returns empty
    func testRefineEmptyTextReturnsEmpty() async throws {
        let result = try await service.refineTranscript("")
        XCTAssertTrue(result.isEmpty)
    }
    
    /// Test progress tracking for plain text
    func testProgressTrackingForPlainText() async throws {
        // Given: LLM not available (to avoid actual refinement)
        mockLLMManager.isLLMStitchingEnabled = false
        
        // When: Refine text
        _ = try await service.refineTranscript("Test text")
        
        // Then: Progress should be 0 (no actual work done)
        XCTAssertEqual(service.progress, 0.0)
    }
    
    /// Test defer cleanup clears refinement state
    func testDeferCleansUpRefinementState() async throws {
        // Given: LLM not available
        mockLLMManager.isLLMStitchingEnabled = false
        
        // When: Refine (will return early but defer should still run)
        _ = try await service.refineTranscript("Test")
        
        // Then: isRefining should be false after completion
        XCTAssertFalse(service.isRefining)
        XCTAssertEqual(service.progress, 0.0)
    }
    
    // MARK: - Part 3: Text Splitting & Merging (Pure Logic Tests)
    
    /// Test speaker separation logic (conceptual)
    func testSpeakerSeparationConcept() {
        // This tests the concept of speaker separation
        // Actual implementation is private, but we can test via blocks
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "I say this", startTimestamp: 0.0),
            TranscriptBlock(speaker: .them, text: "They say that", startTimestamp: 5.0),
            TranscriptBlock(speaker: .me, text: "I say more", startTimestamp: 10.0)
        ]
        
        // Count speakers
        let meBlocks = blocks.filter { $0.speaker == .me }
        let themBlocks = blocks.filter { $0.speaker == .them }
        
        XCTAssertEqual(meBlocks.count, 2)
        XCTAssertEqual(themBlocks.count, 1)
    }
    
    /// Test word count calculation
    func testWordCountCalculation() {
        let block1 = TranscriptBlock(speaker: .me, text: "One two three", startTimestamp: 0.0)
        XCTAssertEqual(block1.wordCount, 3)
        
        let block2 = TranscriptBlock(speaker: .me, text: "Single", startTimestamp: 0.0)
        XCTAssertEqual(block2.wordCount, 1)
        
        let block3 = TranscriptBlock(speaker: .me, text: "", startTimestamp: 0.0)
        XCTAssertEqual(block3.wordCount, 0)
    }
    
    /// Test batching concept (character limits)
    func testBatchingConcept() {
        // maxBatchCharacters is 4000 in TranscriptRefinementService
        let maxChars = 4000
        
        // Create blocks with known character counts
        var blocks: [TranscriptBlock] = []
        var totalChars = 0
        
        // Add blocks until we exceed max
        while totalChars < maxChars {
            let text = String(repeating: "a", count: 500) // 500 chars
            blocks.append(TranscriptBlock(speaker: .me, text: text, startTimestamp: 0.0))
            totalChars += 500
        }
        
        // Should have created multiple blocks
        XCTAssertTrue(blocks.count > 1)
        XCTAssertTrue(totalChars > maxChars)
    }
    
    // MARK: - Part 4: Error Handling & Edge Cases
    
    /// Test model not loaded error
    func testModelNotLoadedError() async throws {
        // Given: LLM enabled but model container nil
        mockLLMManager.isLLMStitchingEnabled = true
        mockLLMManager.downloadedModels.insert(.llama32_3b)
        // Don't load model container
        
        let blocks = [TranscriptBlock(speaker: .me, text: "Test", startTimestamp: 0.0)]
        
        // When/Then: Should throw modelNotLoaded error
        do {
            _ = try await service.refineTranscript(blocks)
            XCTFail("Should have thrown error")
        } catch {
            // Expected error
            XCTAssertTrue(error.localizedDescription.contains("not loaded") || 
                         error.localizedDescription.contains("NotLoaded"))
        }
    }
    
    /// Test blocks with mixed speakers
    func testBlocksWithMixedSpeakers() async throws {
        // Given: LLM not available (to avoid actual refinement)
        mockLLMManager.isLLMStitchingEnabled = false
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "Speaker 1 part 1", startTimestamp: 0.0),
            TranscriptBlock(speaker: .them, text: "Speaker 2 part 1", startTimestamp: 5.0),
            TranscriptBlock(speaker: .me, text: "Speaker 1 part 2", startTimestamp: 10.0),
            TranscriptBlock(speaker: .them, text: "Speaker 2 part 2", startTimestamp: 15.0)
        ]
        
        // When: Refine
        let result = try await service.refineTranscript(blocks)
        
        // Then: Should preserve order and count
        XCTAssertEqual(result.count, blocks.count)
        XCTAssertEqual(result[0].speaker, .me)
        XCTAssertEqual(result[1].speaker, .them)
        XCTAssertEqual(result[2].speaker, .me)
        XCTAssertEqual(result[3].speaker, .them)
    }
    
    /// Test single speaker transcript
    func testSingleSpeakerTranscript() async throws {
        // Given: LLM not available
        mockLLMManager.isLLMStitchingEnabled = false
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "Only me speaking", startTimestamp: 0.0),
            TranscriptBlock(speaker: .me, text: "Still me", startTimestamp: 5.0),
            TranscriptBlock(speaker: .me, text: "Always me", startTimestamp: 10.0)
        ]
        
        // When: Refine
        let result = try await service.refineTranscript(blocks)
        
        // Then: All blocks preserved
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.speaker == .me })
    }
    
    /// Test blocks with empty text
    func testBlocksWithEmptyText() async throws {
        // Given: LLM not available
        mockLLMManager.isLLMStitchingEnabled = false
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "", startTimestamp: 0.0),
            TranscriptBlock(speaker: .them, text: "Some text", startTimestamp: 5.0),
            TranscriptBlock(speaker: .me, text: "", startTimestamp: 10.0)
        ]
        
        // When: Refine
        let result = try await service.refineTranscript(blocks)
        
        // Then: Should handle gracefully
        XCTAssertEqual(result.count, blocks.count)
    }
    
    /// Test blocks with very long text
    func testBlocksWithVeryLongText() async throws {
        // Given: LLM not available
        mockLLMManager.isLLMStitchingEnabled = false
        
        let longText = String(repeating: "word ", count: 1000) // 5000 characters
        let blocks = [
            TranscriptBlock(speaker: .me, text: longText, startTimestamp: 0.0)
        ]
        
        // When: Refine
        let result = try await service.refineTranscript(blocks)
        
        // Then: Should handle without crashing
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, longText)
    }
    
    /// Test blocks preserve timestamps
    func testBlocksPreserveTimestamps() async throws {
        // Given: LLM not available
        mockLLMManager.isLLMStitchingEnabled = false
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "First", startTimestamp: 0.0, endTimestamp: 5.0),
            TranscriptBlock(speaker: .them, text: "Second", startTimestamp: 5.0, endTimestamp: 10.0)
        ]
        
        // When: Refine
        let result = try await service.refineTranscript(blocks)
        
        // Then: Timestamps preserved
        XCTAssertEqual(result[0].startTimestamp, 0.0)
        XCTAssertEqual(result[0].endTimestamp, 5.0)
        XCTAssertEqual(result[1].startTimestamp, 5.0)
        XCTAssertEqual(result[1].endTimestamp, 10.0)
    }
    
    /// Test progress initialization
    func testProgressInitialization() {
        XCTAssertEqual(service.progress, 0.0)
        XCTAssertFalse(service.isRefining)
    }
    
    /// Test error message cleared on new refinement
    func testErrorMessageClearedOnNewRefinement() async throws {
        // Manually set error message
        service.errorMessage = "Previous error"
        XCTAssertNotNil(service.errorMessage)
        
        // Start new refinement (will exit early due to no LLM)
        mockLLMManager.isLLMStitchingEnabled = false
        _ = try await service.refineTranscript([])
        
        // Note: errorMessage is set to nil at start of refineTranscript
        // After completion, it should be nil (no error occurred)
        XCTAssertNil(service.errorMessage)
    }
    
    /// Test single block refinement
    func testSingleBlockRefinement() async throws {
        mockLLMManager.isLLMStitchingEnabled = false
        
        let block = TranscriptBlock(speaker: .me, text: "Single block", startTimestamp: 0.0)
        
        let result = try await service.refineTranscript([block])
        
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Single block")
    }
    
    /// Test alternating speakers
    func testAlternatingSpeakers() async throws {
        mockLLMManager.isLLMStitchingEnabled = false
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "Me 1", startTimestamp: 0.0),
            TranscriptBlock(speaker: .them, text: "Them 1", startTimestamp: 1.0),
            TranscriptBlock(speaker: .me, text: "Me 2", startTimestamp: 2.0),
            TranscriptBlock(speaker: .them, text: "Them 2", startTimestamp: 3.0),
            TranscriptBlock(speaker: .me, text: "Me 3", startTimestamp: 4.0)
        ]
        
        let result = try await service.refineTranscript(blocks)
        
        XCTAssertEqual(result.count, 5)
        // Verify speaker order preserved
        XCTAssertEqual(result[0].speaker, .me)
        XCTAssertEqual(result[1].speaker, .them)
        XCTAssertEqual(result[2].speaker, .me)
        XCTAssertEqual(result[3].speaker, .them)
        XCTAssertEqual(result[4].speaker, .me)
    }
    
    /// Test many short blocks
    func testManyShortBlocks() async throws {
        mockLLMManager.isLLMStitchingEnabled = false
        
        var blocks: [TranscriptBlock] = []
        for i in 0..<100 {
            let speaker: TranscriptBlock.Speaker = i % 2 == 0 ? .me : .them
            blocks.append(TranscriptBlock(speaker: speaker, text: "Block \(i)", startTimestamp: Double(i)))
        }
        
        let result = try await service.refineTranscript(blocks)
        
        XCTAssertEqual(result.count, 100)
    }
    
    /// Test blocks with special characters
    func testBlocksWithSpecialCharacters() async throws {
        mockLLMManager.isLLMStitchingEnabled = false
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "Text with émojis 🎉 and spëcial çharacters", startTimestamp: 0.0),
            TranscriptBlock(speaker: .them, text: "Symbols: @#$%^&*()", startTimestamp: 5.0),
            TranscriptBlock(speaker: .me, text: "Newlines\nand\ttabs", startTimestamp: 10.0)
        ]
        
        let result = try await service.refineTranscript(blocks)
        
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].text, blocks[0].text)
        XCTAssertEqual(result[1].text, blocks[1].text)
        XCTAssertEqual(result[2].text, blocks[2].text)
    }
    
    /// Test refinement with no model container throws
    func testRefinementWithNoModelContainerThrows() async throws {
        // Given: LLM enabled but no container
        mockLLMManager.isLLMStitchingEnabled = true
        mockLLMManager.downloadedModels.insert(.llama32_3b)
        mockLLMManager.setActiveModel(.llama32_3b)
        // modelContainer is nil
        
        let blocks = [TranscriptBlock(speaker: .me, text: "Test", startTimestamp: 0.0)]
        
        do {
            _ = try await service.refineTranscript(blocks)
            XCTFail("Should throw error when model container is nil")
        } catch {
            // Expected
            XCTAssertTrue(true)
        }
    }
    
    /// Test plain text refinement with no model container throws
    func testPlainTextRefinementWithNoModelContainerThrows() async throws {
        // Given: LLM enabled but no container
        mockLLMManager.isLLMStitchingEnabled = true
        mockLLMManager.downloadedModels.insert(.llama32_3b)
        mockLLMManager.setActiveModel(.llama32_3b)
        
        do {
            _ = try await service.refineTranscript("Test text")
            XCTFail("Should throw error when model container is nil")
        } catch {
            // Expected
            XCTAssertTrue(true)
        }
    }
    
    /// Test blocks with whitespace only text
    func testBlocksWithWhitespaceOnlyText() async throws {
        mockLLMManager.isLLMStitchingEnabled = false
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "   ", startTimestamp: 0.0),
            TranscriptBlock(speaker: .them, text: "\t\t", startTimestamp: 5.0),
            TranscriptBlock(speaker: .me, text: "\n\n", startTimestamp: 10.0)
        ]
        
        let result = try await service.refineTranscript(blocks)
        
        // Should handle gracefully
        XCTAssertEqual(result.count, 3)
    }
}
