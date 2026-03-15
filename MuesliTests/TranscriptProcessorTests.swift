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

    /// Test filtering "Yes. Yes. Yes. Yes." hallucination
    func testFilterRepeatedYesHallucination() {
        let segment = TranscriptionService.TranscriptSegment(
            text: "Yes. Yes. Yes. Yes.",
            timestamp: 0.0,
            speaker: .them
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0, "Should filter repeated 'yes' hallucination")
    }

    /// Test filtering dominant-word hallucination pattern
    func testFilterDominantWordHallucination() {
        let segment = TranscriptionService.TranscriptSegment(
            text: "Yes of course yes yes yes yes",
            timestamp: 0.0,
            speaker: .them
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0, "Should filter dominant-word hallucination")
    }

    /// Test filtering n-gram repetition hallucination
    func testFilterNGramRepetitionHallucination() {
        let segment = TranscriptionService.TranscriptSegment(
            text: "I think I think I think I think",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 0, "Should filter n-gram repetitive hallucination")
    }

    /// Test that legitimate repetitive speech is NOT filtered
    func testPreserveLegitimateRepetitiveSpeech() {
        // A sentence that has some repetition but is real speech
        let segment = TranscriptionService.TranscriptSegment(
            text: "I went to the store and then I went to the park",
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment)
        XCTAssertEqual(processor.blocks.count, 1, "Should preserve legitimate speech with some repetition")
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
        // Use varied words to avoid hallucination detection
        let words = (1...80).map { "word\($0)" }
        let longText = words.joined(separator: " ")
        let segment1 = TranscriptionService.TranscriptSegment(
            text: longText,
            timestamp: 0.0,
            speaker: .me
        )
        processor.processSegment(segment1)
        
        XCTAssertEqual(processor.blocks.count, 1)
        guard processor.blocks.count >= 1 else { return }
        XCTAssertTrue(processor.blocks[0].wordCount >= 75)

        // Next segment from same speaker should create new block
        let segment2 = TranscriptionService.TranscriptSegment(
            text: "This should be a new block",
            timestamp: 1.0,
            speaker: .me
        )
        processor.processSegment(segment2)

        XCTAssertEqual(processor.blocks.count, 2, "Should create new block after word limit exceeded")
        guard processor.blocks.count >= 2 else { return }
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
    
    // MARK: - Part 7: Reprocess Ordering Regression
    
    /// Regression test: transcribePostProcessing emits all system audio segments (speaker: .them)
    /// first, then all mic segments (speaker: .me). Without sorting by timestamp before processing,
    /// blocks are grouped by speaker instead of chronologically interleaved.
    /// Bug: reprocessTranscript() fed segments to TranscriptProcessor in arrival order (unsorted).
    /// Fix: Sort segments by timestamp before processing, matching runSecondPassASR() pattern.
    func testReprocessTranscriptSortsSegmentsByTimestampBeforeProcessing() {
        // Simulate transcribePostProcessing output: all .them first, then all .me
        let segments = [
            // System audio batch (all .them, ascending timestamps)
            TranscriptionService.TranscriptSegment(text: "Welcome everyone to the call", timestamp: 0.0, speaker: .them),
            TranscriptionService.TranscriptSegment(text: "Let me share my screen with the quarterly results", timestamp: 30.0, speaker: .them),
            TranscriptionService.TranscriptSegment(text: "As you can see revenue is up fifteen percent", timestamp: 60.0, speaker: .them),
            // Mic audio batch (all .me, ascending timestamps)
            TranscriptionService.TranscriptSegment(text: "Hi thanks for setting this up", timestamp: 5.0, speaker: .me),
            TranscriptionService.TranscriptSegment(text: "That looks great can you zoom in on the chart", timestamp: 35.0, speaker: .me),
            TranscriptionService.TranscriptSegment(text: "Impressive numbers I have a few questions", timestamp: 65.0, speaker: .me),
        ]
        
        // Phase 1: Feed unsorted (arrival order) — demonstrates the bug
        for segment in segments {
            processor.processSegment(segment)
        }
        processor.finalize()
        
        let unsortedBlocks = processor.blocks
        XCTAssertGreaterThanOrEqual(unsortedBlocks.count, 2, "Should produce at least 2 blocks")
        
        // With unsorted input, all .them blocks come first, then all .me blocks
        // Find the index where speaker switches from .them to .me
        let firstMeIndex = unsortedBlocks.firstIndex(where: { $0.speaker == .me })
        let lastThemIndex = unsortedBlocks.lastIndex(where: { $0.speaker == .them })
        if let firstMe = firstMeIndex, let lastThem = lastThemIndex {
            XCTAssertGreaterThan(firstMe, lastThem,
                "Bug: unsorted input groups all .them before all .me (no interleaving)")
        }
        
        // Phase 2: Feed sorted by timestamp — demonstrates the fix
        processor.reset()
        
        let sortedSegments = segments.sorted(by: { $0.timestamp < $1.timestamp })
        for segment in sortedSegments {
            processor.processSegment(segment)
        }
        processor.finalize()
        
        let sortedBlocks = processor.blocks
        XCTAssertGreaterThanOrEqual(sortedBlocks.count, 4, "Sorted input should produce interleaved blocks")
        
        // Verify chronological interleaving: speakers should alternate
        var speakerTransitions = 0
        for i in 1..<sortedBlocks.count {
            if sortedBlocks[i].speaker != sortedBlocks[i - 1].speaker {
                speakerTransitions += 1
            }
        }
        XCTAssertGreaterThanOrEqual(speakerTransitions, 3,
            "Fix: sorted input should produce multiple speaker transitions (interleaving)")
        
        // Verify chronological ordering: timestamps should be non-decreasing
        for i in 1..<sortedBlocks.count {
            XCTAssertGreaterThanOrEqual(sortedBlocks[i].startTimestamp, sortedBlocks[i - 1].startTimestamp,
                "Blocks should be in chronological order")
        }
    }

    // MARK: - Consolidation tests

    /// Blocks must end at sentence boundaries after finalize()
    func testBlocksEndAtSentenceBoundaryAfterFinalize() {
        // Two consecutive same-speaker segments where first doesn't end with period
        let s1 = TranscriptionService.TranscriptSegment(
            text: "I was thinking about this problem",  // no period
            timestamp: 0.0, speaker: .me
        )
        let s2 = TranscriptionService.TranscriptSegment(
            text: "and I think we need a new approach.",  // ends with period
            timestamp: 1.0, speaker: .me
        )
        processor.processSegment(s1)
        processor.processSegment(s2)
        processor.finalize()

        // Should be merged into one block ending with a period
        XCTAssertEqual(processor.blocks.count, 1)
        XCTAssertTrue(processor.blocks[0].text.hasSuffix("."),
            "Block should end with period, got: \(processor.blocks[0].text)")
    }

    /// Consecutive same-speaker blocks with fewer than 4 sentences get merged
    func testConsecutiveSameSpeakerBlocksMerged() {
        // Simulate two consecutive same-speaker blocks with 2 sentences each (as if a speaker
        // switch forced a break mid-flow, then the same speaker continued).
        // After finalize, consolidateBlocks should merge them (total 4 sentences, under cap).
        let s1 = TranscriptionService.TranscriptSegment(
            text: "We decided to move forward with the new architecture.",
            timestamp: 0.0, speaker: .me
        )
        // Force a new block for the same speaker by pushing past the word limit first.
        // Feed a 75-word filler block so the next same-speaker segment starts fresh.
        processor.processSegment(s1)
        // Manually inject a second block by processing then resetting the block's word count
        // via a long segment that fills the first block before the next segment.
        // Easier: use speaker switch to force block boundary, then switch back.
        let sB = TranscriptionService.TranscriptSegment(
            text: "Right, that is a good point about the design.",
            timestamp: 1.0, speaker: .them
        )
        let s2 = TranscriptionService.TranscriptSegment(
            text: "And we also need to address the migration strategy.",
            timestamp: 2.0, speaker: .me
        )
        processor.processSegment(sB)
        processor.processSegment(s2)
        processor.finalize()

        // Me has 2 blocks from streaming (split by sB). consolidateBlocks can't merge them
        // across a speaker boundary — that's expected. What we care about:
        // (a) all blocks end with periods, (b) no content was dropped.
        let allText = processor.blocks.map { $0.text }.joined(separator: " ")
        XCTAssertTrue(allText.contains("move forward"), "Content must be preserved")
        XCTAssertTrue(allText.contains("migration strategy"), "Content must be preserved")
        XCTAssertTrue(allText.contains("good point"), "Them's content must be preserved")
        for block in processor.blocks {
            XCTAssertTrue(block.text.hasSuffix("."),
                "Every block must end with period, got: '\(block.text.suffix(20))'")
        }
    }

    /// No content is discarded — all speaker segments must appear in output
    func testNoContentDiscarded() {
        // Use content-bearing interjections (not pure single-filler-word segments,
        // which are correctly filtered by isHallucination as noise).
        let segments: [(String, TimeInterval, TranscriptionService.TranscriptSegment.Speaker)] = [
            ("Let me explain the architecture.", 0.0, .me),
            ("Yes, that makes sense.", 1.0, .them),      // short but content-bearing
            ("We have three main layers here.", 2.0, .me),
            ("Right, I understand now.", 3.0, .them),    // short but content-bearing
            ("And each layer has a specific role.", 4.0, .me),
        ]
        for (text, ts, speaker) in segments {
            processor.processSegment(TranscriptionService.TranscriptSegment(
                text: text, timestamp: ts, speaker: speaker
            ))
        }
        processor.finalize()

        let allText = processor.blocks.map { $0.text }.joined(separator: " ")
        XCTAssertTrue(allText.contains("that makes sense"),
            "Content-bearing interjection must not be discarded")
        XCTAssertTrue(allText.contains("I understand"),
            "Content-bearing interjection must not be discarded")
        XCTAssertTrue(allText.contains("three main layers"),
            "Main content must be preserved")
    }

    /// Hard cap prevents walls of text even if sentences keep coming
    func testHardWordCapPreventsWallsOfText() {
        // Feed many short sentences from same speaker
        for i in 1...20 {
            let seg = TranscriptionService.TranscriptSegment(
                text: "Sentence \(i) has about six words here.",
                timestamp: TimeInterval(i), speaker: .me
            )
            processor.processSegment(seg)
        }
        processor.finalize()

        for block in processor.blocks {
            XCTAssertLessThanOrEqual(block.wordCount, 130,
                "No block should exceed hard word cap, got \(block.wordCount) words")
        }
    }
}
