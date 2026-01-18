import XCTest
@testable import Muesli

/// Tests for v0.1.2 polish features
@MainActor
final class PolishFeaturesTests: XCTestCase {
    
    // MARK: - ClipboardHelper Tests
    
    func testClipboardHelperFormatAsPlainText() {
        // Create test transcript blocks
        let blocks = [
            TranscriptBlock(
                speaker: .me,
                text: "Hello, this is a test.",
                startTimestamp: 10.5,
                endTimestamp: 12.0
            ),
            TranscriptBlock(
                speaker: .them,
                text: "Yes, I can hear you clearly.",
                startTimestamp: 13.0,
                endTimestamp: 15.5
            )
        ]
        
        // Format as plain text
        let plainText = ClipboardHelper.formatAsPlainText(blocks)
        
        // Verify format
        XCTAssertTrue(plainText.contains("[00:10] Me: Hello, this is a test."))
        XCTAssertTrue(plainText.contains("[00:13] Them: Yes, I can hear you clearly."))
        XCTAssertFalse(plainText.contains("**"), "Plain text should not contain markdown formatting")
    }
    
    func testClipboardHelperFormatAsMarkdown() {
        // Create test transcript blocks
        let blocks = [
            TranscriptBlock(
                speaker: .me,
                text: "Testing markdown format.",
                startTimestamp: 5.0,
                endTimestamp: 7.0
            )
        ]
        
        // Format as markdown
        let markdown = ClipboardHelper.formatAsMarkdown(blocks)
        
        // Verify markdown formatting
        XCTAssertTrue(markdown.contains("**[00:05]** **Me**: Testing markdown format."))
        XCTAssertTrue(markdown.contains("**"), "Markdown should contain bold formatting")
    }
    
    func testClipboardHelperEmptyBlocks() {
        let emptyBlocks: [TranscriptBlock] = []
        
        let plainText = ClipboardHelper.formatAsPlainText(emptyBlocks)
        let markdown = ClipboardHelper.formatAsMarkdown(emptyBlocks)
        
        XCTAssertEqual(plainText, "")
        XCTAssertEqual(markdown, "")
    }
    
    // MARK: - PreferencesManager Audio Chunk Duration Tests
    
    func testAudioChunkDurationDefaultValue() {
        let prefs = PreferencesManager()
        
        // Default should be 5.0 seconds
        XCTAssertEqual(prefs.audioChunkDuration, 5.0, accuracy: 0.01)
    }
    
    func testAudioChunkDurationValidRange() {
        let prefs = PreferencesManager()
        
        // Set to minimum
        prefs.audioChunkDuration = 2.0
        XCTAssertEqual(prefs.audioChunkDuration, 2.0, accuracy: 0.01)
        
        // Set to maximum
        prefs.audioChunkDuration = 10.0
        XCTAssertEqual(prefs.audioChunkDuration, 10.0, accuracy: 0.01)
        
        // Set to mid-range
        prefs.audioChunkDuration = 6.5
        XCTAssertEqual(prefs.audioChunkDuration, 6.5, accuracy: 0.01)
    }
    
    func testAudioChunkDurationClampingBelowRange() {
        let prefs = PreferencesManager()
        
        // Try to set below minimum (should clamp to 2.0)
        prefs.audioChunkDuration = 1.0
        XCTAssertEqual(prefs.audioChunkDuration, 2.0, accuracy: 0.01)
        
        prefs.audioChunkDuration = -5.0
        XCTAssertEqual(prefs.audioChunkDuration, 2.0, accuracy: 0.01)
    }
    
    func testAudioChunkDurationClampingAboveRange() {
        let prefs = PreferencesManager()
        
        // Try to set above maximum (should clamp to 10.0)
        prefs.audioChunkDuration = 15.0
        XCTAssertEqual(prefs.audioChunkDuration, 10.0, accuracy: 0.01)
        
        prefs.audioChunkDuration = 100.0
        XCTAssertEqual(prefs.audioChunkDuration, 10.0, accuracy: 0.01)
    }
    
    func testAudioChunkDurationPersistence() {
        let prefs = PreferencesManager()
        
        // Set a value
        prefs.audioChunkDuration = 7.5
        
        // Create new instance - should load persisted value
        let prefs2 = PreferencesManager()
        XCTAssertEqual(prefs2.audioChunkDuration, 7.5, accuracy: 0.01)
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.audioChunkDuration)
    }
    
    func testAudioChunkDurationChangeCallback() {
        let prefs = PreferencesManager()
        var callbackReceived = false
        var receivedValue: TimeInterval = 0
        
        prefs.audioChunkDurationDidChange = { newValue in
            callbackReceived = true
            receivedValue = newValue
        }
        
        // Change the value
        prefs.audioChunkDuration = 8.0
        
        XCTAssertTrue(callbackReceived)
        XCTAssertEqual(receivedValue, 8.0, accuracy: 0.01)
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.audioChunkDuration)
    }
    
    // MARK: - TranscriptionService Chunk Duration Tests
    
    func testTranscriptionServiceDefaultChunkDuration() {
        // Create service with default duration
        let service = TranscriptionService()
        
        // Can't directly access private properties, but we can verify it doesn't crash
        XCTAssertNotNil(service)
    }
    
    func testTranscriptionServiceCustomChunkDuration() {
        // Create service with custom duration
        let service = TranscriptionService(chunkDuration: 3.0)
        
        XCTAssertNotNil(service)
    }
    
    func testTranscriptionServiceChunkDurationClamping() {
        // Test clamping - these should not crash
        let service1 = TranscriptionService(chunkDuration: 1.0)  // Below minimum
        let service2 = TranscriptionService(chunkDuration: 15.0) // Above maximum
        
        XCTAssertNotNil(service1)
        XCTAssertNotNil(service2)
    }
    
    // MARK: - TranscriptProcessor Hallucination Detection Tests
    
    func testTranscriptProcessorFiltersCommonHallucinations() {
        let processor = TranscriptProcessor()
        
        // Test common hallucinations that should be filtered
        let hallucinations = [
            "thank you",
            "Thanks for watching",
            "like and subscribe",
            "bye",
            "goodbye"
        ]
        
        for text in hallucinations {
            let segment = TranscriptionService.TranscriptSegment(
                text: text,
                timestamp: 1.0,
                speaker: .them
            )
            
            processor.processSegment(segment)
        }
        
        // All hallucinations should be filtered - no blocks created
        XCTAssertEqual(processor.blocks.count, 0, "Hallucinations should be filtered out")
    }
    
    func testTranscriptProcessorFiltersHallucinationsWithPunctuation() {
        let processor = TranscriptProcessor()
        
        // Test hallucinations with punctuation (the bug we just fixed)
        let hallucinationsWithPunctuation = [
            "Thank you.",
            "Thanks for watching!",
            "Bye.",
            "Goodbye!",
            "Subscribe.",
            "You.",
            "Okay.",
        ]
        
        for text in hallucinationsWithPunctuation {
            processor.reset()
            let segment = TranscriptionService.TranscriptSegment(
                text: text,
                timestamp: 1.0,
                speaker: .them
            )
            
            processor.processSegment(segment)
            
            // Each should be filtered despite having punctuation
            XCTAssertEqual(processor.blocks.count, 0, "'\(text)' with punctuation should be filtered")
        }
    }
    
    func testTranscriptProcessorFiltersFillerWordsWithPunctuation() {
        let processor = TranscriptProcessor()
        
        let fillersWithPunctuation = [
            "Uh.",
            "Um...",
            "Hmm?",
            "Yeah!",
            "Okay."
        ]
        
        for filler in fillersWithPunctuation {
            processor.reset()
            let segment = TranscriptionService.TranscriptSegment(
                text: filler,
                timestamp: 1.0,
                speaker: .me
            )
            
            processor.processSegment(segment)
            
            // Filler words with punctuation should still be filtered
            XCTAssertEqual(processor.blocks.count, 0, "'\(filler)' should be filtered despite punctuation")
        }
    }
    
    func testTranscriptProcessorFiltersRepetitiveTextWithPunctuation() {
        let processor = TranscriptProcessor()
        
        // Test "Thank you. Thank you. Thank you." pattern
        let repetitiveWithPunctuation = TranscriptionService.TranscriptSegment(
            text: "Okay. Okay. Okay.",
            timestamp: 1.0,
            speaker: .them
        )
        
        processor.processSegment(repetitiveWithPunctuation)
        
        // Should be filtered as repetitive hallucination
        XCTAssertEqual(processor.blocks.count, 0, "Repetitive text with punctuation should be filtered")
    }
    
    func testTranscriptProcessorFiltersHyphenatedHallucinations() {
        let processor = TranscriptProcessor()
        
        // Test hyphenated hallucinations with and without punctuation
        let hyphenatedTests = [
            "bye-bye",
            "Bye-bye.",
            "Bye-bye!",
            "bye-bye?",
        ]
        
        for text in hyphenatedTests {
            processor.reset()
            let segment = TranscriptionService.TranscriptSegment(
                text: text,
                timestamp: 1.0,
                speaker: .them
            )
            
            processor.processSegment(segment)
            
            // Should be filtered despite having hyphens
            XCTAssertEqual(processor.blocks.count, 0, "'\(text)' should be filtered (hyphenated hallucination)")
        }
    }
    
    func testTranscriptProcessorPreservesHyphensInValidContent() {
        let processor = TranscriptProcessor()
        
        // Valid content with hyphens should NOT be filtered
        let validSegment = TranscriptionService.TranscriptSegment(
            text: "We need a follow-up meeting for the next quarter.",
            timestamp: 1.0,
            speaker: .me
        )
        
        processor.processSegment(validSegment)
        
        // Valid content with hyphens should create a block
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks.first?.text, "We need a follow-up meeting for the next quarter.")
    }
    
    func testTranscriptProcessorAllowsValidContent() {
        let processor = TranscriptProcessor()
        
        let validSegment = TranscriptionService.TranscriptSegment(
            text: "Let's discuss the quarterly results.",
            timestamp: 1.0,
            speaker: .me
        )
        
        processor.processSegment(validSegment)
        
        // Valid content should create a block
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks.first?.text, "Let's discuss the quarterly results.")
    }
    
    func testTranscriptProcessorFiltersRepetitiveText() {
        let processor = TranscriptProcessor()
        
        // Repetitive text (same word repeated)
        let repetitive = TranscriptionService.TranscriptSegment(
            text: "okay okay okay",
            timestamp: 1.0,
            speaker: .them
        )
        
        processor.processSegment(repetitive)
        
        // Should be filtered as hallucination
        XCTAssertEqual(processor.blocks.count, 0, "Repetitive text should be filtered")
    }
    
    func testTranscriptProcessorFiltersFillerWords() {
        let processor = TranscriptProcessor()
        
        let fillers = ["uh", "um", "hmm"]
        
        for filler in fillers {
            let segment = TranscriptionService.TranscriptSegment(
                text: filler,
                timestamp: 1.0,
                speaker: .me
            )
            
            processor.processSegment(segment)
        }
        
        // Short filler words should be filtered
        XCTAssertEqual(processor.blocks.count, 0, "Filler words should be filtered")
    }
    
    func testTranscriptProcessorFiltersArtifacts() {
        let processor = TranscriptProcessor()
        
        let artifacts = [
            "(silence)",
            "(music)",
            "[background noise]",
            "(applause)"
        ]
        
        for artifact in artifacts {
            let segment = TranscriptionService.TranscriptSegment(
                text: artifact,
                timestamp: 1.0,
                speaker: .them
            )
            
            processor.processSegment(segment)
        }
        
        // Artifacts should be filtered
        XCTAssertEqual(processor.blocks.count, 0, "Artifacts should be filtered out")
    }
    
    // MARK: - Cleanup
    
    override func tearDown() {
        super.tearDown()
        
        // Clean up UserDefaults
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.audioChunkDuration)
    }
}
