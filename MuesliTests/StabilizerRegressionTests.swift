@testable import Muesli
import XCTest

/// Regression tests for LiveStabilizer edge cases.
/// Each test is named after a real failure mode or invariant that must hold forever.
final class StabilizerRegressionTests: XCTestCase {

    // MARK: - R001: Empty pipeline produces no output

    func testR001_EmptyPipelineProducesNoOutput() async {
        let stabilizer = LiveStabilizer(agreementWindow: 2, draftEmitIntervalMs: 0)
        let flush = await stabilizer.flushAll()
        XCTAssertTrue(flush.committedSegments.isEmpty, "R001: empty flush should have no committed segments")
        XCTAssertNil(flush.draftUpdate, "R001: empty flush should have no draft update")
    }

    // MARK: - R002: Single-word segment does not duplicate

    func testR002_SingleWordSegmentDoesNotDuplicate() async {
        let stabilizer = LiveStabilizer(agreementWindow: 1, draftEmitIntervalMs: 0)
        let seg = TranscriptionService.TranscriptSegment(text: "hi", timestamp: 0, speaker: .me)
        let out1 = await stabilizer.ingest(seg)
        let out2 = await stabilizer.ingest(seg)
        let flush = await stabilizer.flushAll()

        let allText = (out1.committedSegments + out2.committedSegments + flush.committedSegments)
            .map(\.text).joined(separator: " ")
        let hiCount = allText.components(separatedBy: "hi").count - 1
        XCTAssertLessThanOrEqual(hiCount, 1, "R002: single word should not be committed more than once after identical re-injection")
    }

    // MARK: - R003: Whitespace-only segment is ignored

    func testR003_WhitespaceOnlySegmentIgnored() async {
        let stabilizer = LiveStabilizer(agreementWindow: 1, draftEmitIntervalMs: 0)
        let seg = TranscriptionService.TranscriptSegment(text: "\t  \n", timestamp: 0, speaker: .them)
        let out = await stabilizer.ingest(seg)
        XCTAssertTrue(out.committedSegments.isEmpty, "R003: whitespace segment must emit no committed segments")
        XCTAssertNil(out.draftUpdate, "R003: whitespace segment must emit no draft update")
    }

    // MARK: - R004: Speaker state is fully isolated

    func testR004_SpeakerStateIsolated() async {
        let stabilizer = LiveStabilizer(agreementWindow: 1, draftEmitIntervalMs: 0)
        let meSeg = TranscriptionService.TranscriptSegment(text: "speaker me text", timestamp: 0, speaker: .me)
        let themSeg = TranscriptionService.TranscriptSegment(text: "speaker them text", timestamp: 0.1, speaker: .them)

        let meOut = await stabilizer.ingest(meSeg)
        let themOut = await stabilizer.ingest(themSeg)
        let flush = await stabilizer.flushAll()

        let allSegments = meOut.committedSegments + themOut.committedSegments + flush.committedSegments
        for seg in allSegments where seg.speaker == .me {
            XCTAssertFalse(seg.text.contains("them"), "R004: .me segment must not contain .them text")
        }
        for seg in allSegments where seg.speaker == .them {
            XCTAssertFalse(seg.text.contains("me text"), "R004: .them segment must not contain .me text")
        }
    }

    // MARK: - R005: flushAll is idempotent

    func testR005_FlushAllIsIdempotent() async {
        let stabilizer = LiveStabilizer(agreementWindow: 2, draftEmitIntervalMs: 0)
        let seg = TranscriptionService.TranscriptSegment(text: "some words here", timestamp: 0, speaker: .me)
        _ = await stabilizer.ingest(seg)

        let flush1 = await stabilizer.flushAll()
        let flush2 = await stabilizer.flushAll()
        let flush3 = await stabilizer.flushAll()

        // First flush commits pending; subsequent flushes must find nothing left.
        XCTAssertEqual(flush2.committedSegments.count, 0, "R005: second flushAll must have no committed segments")
        XCTAssertEqual(flush3.committedSegments.count, 0, "R005: third flushAll must have no committed segments")
        _ = flush1 // used
    }

    // MARK: - R006: Agreement window of 1 commits immediately

    func testR006_AgreementWindowOneCommitsImmediately() async {
        let stabilizer = LiveStabilizer(agreementWindow: 1, draftEmitIntervalMs: 0)
        let seg = TranscriptionService.TranscriptSegment(text: "immediate commit", timestamp: 0, speaker: .me)
        let out = await stabilizer.ingest(seg)
        // With window=1, should commit during ingest (no need to wait for flush)
        XCTAssertEqual(out.committedSegments.count, 1, "R006: agreementWindow=1 must commit segment immediately on ingest")
        XCTAssertEqual(out.committedSegments.first?.text, "immediate commit")
    }

    // MARK: - R007: Large agreement window defers commits until flush

    func testR007_LargeAgreementWindowDefersCommit() async {
        let stabilizer = LiveStabilizer(agreementWindow: 10, draftEmitIntervalMs: 0)
        let seg = TranscriptionService.TranscriptSegment(text: "deferred segment", timestamp: 0, speaker: .me)
        let out = await stabilizer.ingest(seg)
        XCTAssertTrue(out.committedSegments.isEmpty, "R007: large agreementWindow should defer commit on first ingest")

        let flush = await stabilizer.flushAll()
        XCTAssertEqual(flush.committedSegments.count, 1, "R007: flush should release deferred segment")
    }

    // MARK: - R008: Flush output is sorted by timestamp

    func testR008_FlushOutputSortedByTimestamp() async {
        let stabilizer = LiveStabilizer(agreementWindow: 10, draftEmitIntervalMs: 0)
        let speakers: [TranscriptionService.TranscriptSegment.Speaker] = [.me, .them, .me, .them]
        let timestamps: [TimeInterval] = [3.0, 1.0, 4.0, 2.0]
        for (speaker, ts) in zip(speakers, timestamps) {
            let seg = TranscriptionService.TranscriptSegment(text: "word \(ts)", timestamp: ts, speaker: speaker)
            _ = await stabilizer.ingest(seg)
        }

        let flush = await stabilizer.flushAll()
        let flushedTimestamps = flush.committedSegments.map(\.timestamp)
        XCTAssertEqual(flushedTimestamps, flushedTimestamps.sorted(), "R008: flush output must be sorted by timestamp")
    }

    // MARK: - R009: Draft throttle prevents rapid-fire draft emissions

    func testR009_DraftThrottlePreventsBurstEmissions() async {
        // Set a 1-second throttle so consecutive rapid ingests should not emit on every call
        let stabilizer = LiveStabilizer(
            agreementWindow: 10,
            draftEmitIntervalMs: 1000
        )
        var draftCount = 0
        // Ingest 5 distinct drafts in rapid succession
        for i in 0..<5 {
            let seg = TranscriptionService.TranscriptSegment(text: "draft word \(i)", timestamp: TimeInterval(i), speaker: .me)
            let out = await stabilizer.ingest(seg)
            if out.draftUpdate != nil { draftCount += 1 }
        }
        // With a 1-second throttle and near-zero elapsed time, at most 1 draft should be emitted
        XCTAssertLessThanOrEqual(draftCount, 1, "R009: draft throttle must prevent burst emissions")
    }

    // MARK: - R010: Completely identical repeated segments suppressed

    func testR010_IdenticalRepeatedSegmentsSuppressed() async {
        let stabilizer = LiveStabilizer(
            agreementWindow: 1,
            similarityThreshold: 0.9,
            draftEmitIntervalMs: 0
        )
        let text = "the quick brown fox"
        let seg = TranscriptionService.TranscriptSegment(text: text, timestamp: 0, speaker: .me)
        _ = await stabilizer.ingest(seg)

        // Inject same text again — overlap dedup should suppress it entirely
        let seg2 = TranscriptionService.TranscriptSegment(text: text, timestamp: 1, speaker: .me)
        let out2 = await stabilizer.ingest(seg2)
        let flush = await stabilizer.flushAll()

        let allText = (out2.committedSegments + flush.committedSegments).map(\.text).joined(separator: " ")
        XCTAssertFalse(
            allText.lowercased().contains("the quick brown fox the quick brown fox"),
            "R010: identical repeated segment should not produce doubled output"
        )
    }
}
