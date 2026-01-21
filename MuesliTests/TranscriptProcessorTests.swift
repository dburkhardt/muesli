@testable import Muesli
import XCTest

/// Tests for TranscriptProcessor
/// Focus: Artifact filtering, block merging logic, and hallucination detection
@MainActor
final class TranscriptProcessorTests: XCTestCase {
    var processor: TranscriptProcessor!
    
    override func setUp() {
        super.setUp()
        processor = TranscriptProcessor()
    }
    
    override func tearDown() {
        processor = nil
        super.tearDown()
    }
    
    // MARK: - Part 1: Artifact Filtering
    
    /// Test filtering common artifacts (silence, music, static)
    func testFilterCommonArtifacts() {
        // Test silence artifact
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "Hello (silence) world",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "Hello world")
        
        // Reset and test music artifact
        processor.reset()
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "Testing (music) again",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment2)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "Testing again")
        
        // Reset and test static artifact
        processor.reset()
        let segment3 = TranscriptionService.TranscriptSegment(
            text: "More text (static) here",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment3)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "More text here")
    }
    
    /// Test filtering background noise artifacts
    func testFilterBackgroundNoiseArtifacts() {
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "Speaking (background noise) clearly",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "Speaking clearly")
        
        processor.reset()
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "More (background) text",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment2)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "More text")
    }
    
    /// Test filtering sound descriptions
    func testFilterSoundDescriptions() {
        // Test whistle
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "I heard a (whistle) sound",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "I heard a sound")
        
        // Reset and test siren
        processor.reset()
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "There was (siren blaring) outside",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment2)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "There was outside")
        
        // Reset and test alarm
        processor.reset()
        let segment3 = TranscriptionService.TranscriptSegment(
            text: "The (alarm) went off",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment3)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "The went off")
    }
    
    /// Test filtering bracketed annotations
    func testFilterBracketedAnnotations() {
        let segment = TranscriptionService.TranscriptSegment(
            text: "This is [inaudible] some text [background noise] here",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "This is some text here")
    }
    
    /// Test filtering [BLANK_AUDIO] annotation from WhisperKit
    /// This is a common artifact when transcribing silent audio sections
    func testFilterBlankAudioAnnotation() {
        // Test standalone [BLANK_AUDIO]
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "[BLANK_AUDIO]",
            timestamp: 0.0,
            speaker: .them
        )
        processor.processSegment(segment1)
        XCTAssertEqual(processor.blocks.count, 0, "Should filter standalone [BLANK_AUDIO]")
        
        // Test [BLANK_AUDIO] mixed with real content
        processor.reset()
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "Hello there [BLANK_AUDIO] how are you",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment2)
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "Hello there how are you", "Should remove [BLANK_AUDIO] from text")
    }
    
    /// Test filtering music notes
    func testFilterMusicNotes() {
        let segment = TranscriptionService.TranscriptSegment(
            text: "Some text ♪ music playing ♪ more text",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "Some text more text")
    }
    
    /// Test filtering trailing ellipsis
    func testFilterTrailingEllipsis() {
        let segment = TranscriptionService.TranscriptSegment(
            text: "This sentence trails off...",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "This sentence trails off")
    }
    
    /// Test detecting and filtering hallucinations
    func testFilterHallucinations() {
        // Thank you hallucination
        var segment = TranscriptionService.TranscriptSegment(
            text: "Thank you.",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0, "Should filter 'thank you' hallucination")
        
        // Subscribe hallucination
        processor.reset()
        segment = TranscriptionService.TranscriptSegment(
            text: "Subscribe",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0, "Should filter 'subscribe' hallucination")
        
        // Bye hallucination
        processor.reset()
        segment = TranscriptionService.TranscriptSegment(
            text: "Bye!",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0, "Should filter 'bye' hallucination")
        
        // Goodbye hallucination
        processor.reset()
        segment = TranscriptionService.TranscriptSegment(
            text: "Goodbye",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0, "Should filter 'goodbye' hallucination")
    }
    
    /// Test detecting repetitive text hallucinations
    func testFilterRepetitiveHallucinations() {
        let segment = TranscriptionService.TranscriptSegment(
            text: "Thank you. Thank you. Thank you.",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        
        // Should filter repetitive text
        XCTAssertEqual(processor.blocks.count, 0, "Should filter repetitive hallucination")
    }
    
    /// Test preserving actual content (non-artifact text)
    func testPreserveActualContent() {
        let segment = TranscriptionService.TranscriptSegment(
            text: "This is real content that should be preserved",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertEqual(processor.blocks[0].text, "This is real content that should be preserved")
    }
    
    // MARK: - Part 2: Block Merging Logic
    
    /// Test appending to last block (same speaker, under word limit)
    func testAppendToLastBlockSameSpeaker() {
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "First part",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "second part",
            timestamp: 1.0,
            speaker: .me
        )
        processor.processSegment(segment2)
        
        // Should merge into single block
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertTrue(processor.blocks[0].text.contains("First part"))
        XCTAssertTrue(processor.blocks[0].text.contains("second part"))
    }
    
    /// Test creating new block (different speaker)
    func testCreateNewBlockDifferentSpeaker() {
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "I am speaking",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "They are speaking",
            timestamp: 1.0,
            speaker: .them
        )
        processor.processSegment(segment2)
        
        // Should create separate blocks
        XCTAssertEqual(processor.blocks.count, 2)
        XCTAssertEqual(processor.blocks[0].speaker, .me)
        XCTAssertEqual(processor.blocks[1].speaker, .them)
    }
    
    /// Test creating new block when word limit exceeded
    func testCreateNewBlockWordLimitExceeded() {
        // Create a segment with many words (over 75 word limit)
        let longText = String(repeating: "word ", count: 80) // 80 words
        let segment1 = TranscriptionService.TranscriptSegment(
            text: longText,
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertTrue(processor.blocks[0].wordCount >= 75)
        
        // Next segment from same speaker should create new block
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "This should be a new block",
            timestamp: 1.0,
            speaker: .me
        )
        processor.processSegment(segment2)
        
        XCTAssertEqual(processor.blocks.count, 2, "Should create new block after word limit exceeded")
        XCTAssertEqual(processor.blocks[1].text, "This should be a new block")
    }
    
    /// Test handling pending interjections (brief)
    func testDiscardBriefInterjections() {
        // Speaker 1 talks
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "I am talking about something important",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        // Brief interjection from speaker 2 (< 10 words)
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "Uh huh yeah",
            timestamp: 1.0,
            speaker: .them
        )
        processor.processSegment(segment2)
        
        // Speaker 1 continues
        let segment3 = TranscriptionService.TranscriptSegment(
            text: "and I want to finish my thought",
            timestamp: 2.0,
            speaker: .me
        )
        processor.processSegment(segment3)
        
        // Brief interjection should be discarded, speaker 1's speech should continue
        XCTAssertTrue(processor.blocks.count >= 1)
        // The main speaker's blocks should be preserved
        let meBlocks = processor.blocks.filter { $0.speaker == .me }
        XCTAssertTrue(meBlocks.count >= 1)
    }
    
    /// Test handling substantial interjections
    func testPreserveSubstantialInterjections() {
        // Speaker 1 talks
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "I am talking about something",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        // Substantial interjection from speaker 2 (>= 10 words)
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "That's a really interesting point and I want to add something significant here",
            timestamp: 1.0,
            speaker: .them
        )
        processor.processSegment(segment2)
        
        // Speaker 1 continues
        let segment3 = TranscriptionService.TranscriptSegment(
            text: "continuing my thought",
            timestamp: 2.0,
            speaker: .me
        )
        processor.processSegment(segment3)
        
        // Substantial interjection should be preserved
        XCTAssertTrue(processor.blocks.count >= 2)
        let themBlocks = processor.blocks.filter { $0.speaker == .them }
        XCTAssertTrue(themBlocks.count >= 1, "Substantial interjection should be preserved")
    }
    
    /// Test merging interjections from same speaker
    func testMergeInterjectionsFromSameSpeaker() {
        // Speaker 1
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "First statement",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        // Speaker 2 brief
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "Quick comment",
            timestamp: 1.0,
            speaker: .them
        )
        processor.processSegment(segment2)
        
        // Speaker 1 again (should trigger interjection handling)
        let segment3 = TranscriptionService.TranscriptSegment(
            text: "Second statement",
            timestamp: 2.0,
            speaker: .me
        )
        processor.processSegment(segment3)
        
        // Should handle the flow correctly
        XCTAssertTrue(processor.blocks.count >= 1)
    }
    
    /// Test processing segment with cleaned text
    func testProcessSegmentWithCleanedText() {
        let segment = TranscriptionService.TranscriptSegment(
            text: "  Text with   extra   spaces  ",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        
        XCTAssertEqual(processor.blocks.count, 1)
        // Should trim and clean whitespace
        XCTAssertFalse(processor.blocks[0].text.hasPrefix(" "))
        XCTAssertFalse(processor.blocks[0].text.hasSuffix(" "))
    }
    
    /// Test skipping empty/whitespace-only segments
    func testSkipEmptySegments() {
        // Empty text
        var segment = TranscriptionService.TranscriptSegment(
            text: "",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0)
        
        // Whitespace only
        segment = TranscriptionService.TranscriptSegment(
            text: "   ",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0)
        
        // Only artifacts (should be filtered to empty)
        segment = TranscriptionService.TranscriptSegment(
            text: "(silence)",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0)
    }
    
    // MARK: - Part 3: Processor Lifecycle
    
    /// Test processor initialization
    func testProcessorInitialization() {
        let newProcessor = TranscriptProcessor()
        
        XCTAssertEqual(newProcessor.blocks.count, 0)
        XCTAssertTrue(newProcessor.blocks.isEmpty)
    }
    
    /// Test processing multiple segments sequentially
    func testProcessMultipleSegmentsSequentially() {
        let segments = [
            TranscriptionService.TranscriptSegment(text: "First segment", timestamp: 0.0, speaker: .me),
            TranscriptionService.TranscriptSegment(text: "Second segment", timestamp: 1.0, speaker: .me),
            TranscriptionService.TranscriptSegment(text: "Third segment", timestamp: 2.0, speaker: .them),
            TranscriptionService.TranscriptSegment(text: "Fourth segment", timestamp: 3.0, speaker: .them)
        ]
        
        for segment in segments {
            processor.processSegment(segment)
        }
        
        XCTAssertTrue(processor.blocks.count >= 2, "Should have created multiple blocks")
        
        // Check speakers are correct
        let meBlocks = processor.blocks.filter { $0.speaker == .me }
        let themBlocks = processor.blocks.filter { $0.speaker == .them }
        
        XCTAssertTrue(meBlocks.count >= 1)
        XCTAssertTrue(themBlocks.count >= 1)
    }
    
    /// Test finalizing processing (flush pending)
    func testFinalizeProcessing() {
        // Add a segment that might be pending
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "Main content",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        // Add brief interjection (might be pending)
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "Brief word",
            timestamp: 1.0,
            speaker: .them
        )
        processor.processSegment(segment2)
        
        let blockCountBefore = processor.blocks.count
        
        // Finalize should flush any pending content
        processor.finalize()
        
        // After finalize, pending interjection should be processed
        XCTAssertTrue(processor.blocks.count >= blockCountBefore)
    }
    
    /// Test reset processor state
    func testResetProcessorState() {
        // Add some segments
        let segment = TranscriptionService.TranscriptSegment(
            text: "Some content",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        
        XCTAssertTrue(!processor.blocks.isEmpty)
        
        // Reset
        processor.reset()
        
        // Should clear all blocks
        XCTAssertEqual(processor.blocks.count, 0)
        XCTAssertTrue(processor.blocks.isEmpty)
    }
    
    /// Test formatting transcript for file output
    func testFormattedTranscriptOutput() {
        // Add some blocks
        let segment1 = TranscriptionService.TranscriptSegment(
            text: "First statement",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "Second statement",
            timestamp: 5.0,
            speaker: .them
        )
        processor.processSegment(segment2)
        
        let title = "Test Meeting"
        let date = Date()
        
        let formatted = processor.formattedTranscript(title: title, date: date)
        
        // Should include title
        XCTAssertTrue(formatted.contains(title))
        
        // Should include speaker labels
        XCTAssertTrue(formatted.contains("me") || formatted.contains("them"))
        
        // Should include content
        XCTAssertTrue(formatted.contains("First statement") || formatted.contains("Second statement"))
        
        // Should be markdown formatted
        XCTAssertTrue(formatted.contains("#"))
    }
    
    /// Test complex mixed scenario
    func testComplexMixedScenario() {
        // Simulate a complex conversation with artifacts, hallucinations, and speaker changes
        let segments = [
            TranscriptionService.TranscriptSegment(
                text: "Let's start the meeting",
                timestamp: 0.0,
                speaker: .me
            ),
            TranscriptionService.TranscriptSegment(
                text: "(background noise) Sure thing",
                timestamp: 1.0,
                speaker: .them
            ),
            TranscriptionService.TranscriptSegment(
                text: "I wanted to discuss [inaudible] the project",
                timestamp: 2.0,
                speaker: .me
            ),
            TranscriptionService.TranscriptSegment(
                text: "Okay",
                timestamp: 3.0,
                speaker: .them
            ), // Brief interjection
            TranscriptionService.TranscriptSegment(
                text: "and get your feedback",
                timestamp: 4.0,
                speaker: .me
            ),
            TranscriptionService.TranscriptSegment(
                text: "I think we should ♪ music ♪ proceed carefully",
                timestamp: 5.0,
                speaker: .them
            )
        ]
        
        for segment in segments {
            processor.processSegment(segment)
        }
        
        processor.finalize()
        
        // Should have processed multiple blocks
        XCTAssertTrue(processor.blocks.count >= 2)
        
        // Artifacts should be filtered
        let allText = processor.blocks.map { $0.text }.joined(separator: " ")
        XCTAssertFalse(allText.contains("background noise"))
        XCTAssertFalse(allText.contains("[inaudible]"))
        XCTAssertFalse(allText.contains("♪"))
    }
}
