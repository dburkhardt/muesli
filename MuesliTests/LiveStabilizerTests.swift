@testable import Muesli
import XCTest

final class LiveStabilizerTests: XCTestCase {
    func testOverlapDuplicateSuppression() async {
        let stabilizer = LiveStabilizer(
            agreementWindow: 1,
            overlapDuration: 1.5,
            jitterMs: 0,
            maxDraftTokens: 40,
            similarityThreshold: 0.70,
            draftEmitIntervalMs: 0
        )

        let first = TranscriptionService.TranscriptSegment(text: "hello world this is", timestamp: 0, speaker: .them)
        let second = TranscriptionService.TranscriptSegment(text: "this is a test", timestamp: 5, speaker: .them)
        _ = await stabilizer.ingest(first)
        let output = await stabilizer.ingest(second)
        let flush = await stabilizer.flushAll()

        let combined = (output.committedSegments + flush.committedSegments)
            .map(\.text)
            .joined(separator: " ")
            .lowercased()
        XCTAssertFalse(combined.contains("this is this is"))
    }

    func testFlushEmitsDraftOnce() async {
        let stabilizer = LiveStabilizer(agreementWindow: 2, draftEmitIntervalMs: 0)
        let segment = TranscriptionService.TranscriptSegment(text: "draft only text", timestamp: 0, speaker: .me)

        _ = await stabilizer.ingest(segment)
        let flush1 = await stabilizer.flushAll()
        let flush2 = await stabilizer.flushAll()

        XCTAssertEqual(flush1.committedSegments.count, 1)
        XCTAssertEqual(flush2.committedSegments.count, 0)
    }

    func testEmptySegmentIsIgnored() async {
        let stabilizer = LiveStabilizer(agreementWindow: 1, draftEmitIntervalMs: 0)
        let empty = TranscriptionService.TranscriptSegment(text: "   ", timestamp: 0, speaker: .me)

        let output = await stabilizer.ingest(empty)
        let flush = await stabilizer.flushAll()

        XCTAssertEqual(output.committedSegments.count, 0)
        XCTAssertTrue(output.draftUpdates.isEmpty)
        XCTAssertEqual(flush.committedSegments.count, 0)
    }

    func testMultiSpeakerSegmentsAreIsolated() async {
        let stabilizer = LiveStabilizer(agreementWindow: 1, draftEmitIntervalMs: 0)
        let meSegment = TranscriptionService.TranscriptSegment(text: "I said this", timestamp: 0, speaker: .me)
        let themSegment = TranscriptionService.TranscriptSegment(text: "they said that", timestamp: 1, speaker: .them)

        let meOutput = await stabilizer.ingest(meSegment)
        let themOutput = await stabilizer.ingest(themSegment)
        let flush = await stabilizer.flushAll()

        // With agreementWindow=1, segments may commit during ingest or flushAll — collect all
        let allSegments = meOutput.committedSegments + themOutput.committedSegments + flush.committedSegments
        XCTAssertFalse(allSegments.isEmpty, "Should have emitted at least some segments")

        let speakers = Set(allSegments.map(\.speaker))
        XCTAssertTrue(speakers.contains(.me), "Should have a .me segment")
        XCTAssertTrue(speakers.contains(.them), "Should have a .them segment")
        let texts = allSegments.map(\.text)
        XCTAssertFalse(texts.contains(where: { $0.contains("they said") && $0.contains("I said") }),
                       "Segments from different speakers should not be merged")
    }

    func testConcurrentIngestionDoesNotCrash() async {
        let stabilizer = LiveStabilizer(agreementWindow: 1, draftEmitIntervalMs: 0)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let seg = TranscriptionService.TranscriptSegment(
                        text: "word\(i) word\(i+1)",
                        timestamp: TimeInterval(i),
                        speaker: i.isMultiple(of: 2) ? .me : .them
                    )
                    _ = await stabilizer.ingest(seg)
                }
            }
        }

        let flush = await stabilizer.flushAll()
        XCTAssertGreaterThan(flush.committedSegments.count + flush.draftUpdates.count, 0,
                             "Should have produced at least some output from concurrent ingestion")
    }

    func testHighSimilarityOverlapIsDropped() async {
        let stabilizer = LiveStabilizer(
            agreementWindow: 1,
            overlapDuration: 2.0,
            jitterMs: 0,
            maxDraftTokens: 40,
            similarityThreshold: 0.60,
            draftEmitIntervalMs: 0
        )
        let first = TranscriptionService.TranscriptSegment(
            text: "the quick brown fox jumps",
            timestamp: 0,
            speaker: .me
        )
        let second = TranscriptionService.TranscriptSegment(
            text: "the quick brown fox jumps over the lazy dog",
            timestamp: 1,
            speaker: .me
        )
        _ = await stabilizer.ingest(first)
        let output = await stabilizer.ingest(second)
        let flush = await stabilizer.flushAll()

        let allText = (output.committedSegments + flush.committedSegments)
            .map(\.text).joined(separator: " ").lowercased()
        XCTAssertFalse(allText.contains("the quick brown fox jumps the quick brown fox jumps"),
                       "High-overlap prefix should be stripped from second segment")
    }
}
