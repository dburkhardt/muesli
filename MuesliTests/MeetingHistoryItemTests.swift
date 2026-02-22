@testable import Muesli
import XCTest

/// Tests for MeetingHistoryItem and related types
@MainActor
final class MeetingHistoryItemTests: XCTestCase {

    // MARK: - Initialization Tests

    func testDefaultInitialization() {
        let dir = URL(fileURLWithPath: "/tmp/test")
        let item = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: dir,
            hasAudio: true,
            hasMicrophone: true
        )

        XCTAssertEqual(item.title, "Test Meeting")
        XCTAssertTrue(item.hasAudio)
        XCTAssertTrue(item.hasMicrophone)
        XCTAssertNil(item.transcript)
        XCTAssertNil(item.transcriptBlocks)
        XCTAssertFalse(item.isLoadingTranscript)
        XCTAssertFalse(item.isReprocessing)
        XCTAssertFalse(item.isRefined)
        XCTAssertEqual(item.segmentCount, 1)
    }

    // MARK: - canResume Tests

    func testCanResumeWithAudio() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false
        )
        XCTAssertTrue(item.canResume)
    }

    func testCanResumeWithMicrophone() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: false, hasMicrophone: true
        )
        XCTAssertTrue(item.canResume)
    }

    func testCannotResumeWithoutAudio() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: false, hasMicrophone: false
        )
        XCTAssertFalse(item.canResume)
    }

    // MARK: - Formatted Duration Tests

    func testFormattedDurationNil() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false, duration: nil
        )
        XCTAssertNil(item.formattedDuration)
    }

    func testFormattedDurationZero() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false, duration: 0
        )
        XCTAssertNil(item.formattedDuration)
    }

    func testFormattedDurationMinutes() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false, duration: 47 * 60
        )
        XCTAssertEqual(item.formattedDuration, "47 min")
    }

    func testFormattedDurationHoursAndMinutes() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false, duration: 83 * 60
        )
        XCTAssertEqual(item.formattedDuration, "1h 23 min")
    }

    // MARK: - Formatted Word Count Tests

    func testFormattedWordCountNil() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false, wordCount: nil
        )
        XCTAssertNil(item.formattedWordCount)
    }

    func testFormattedWordCountZero() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false, wordCount: 0
        )
        XCTAssertNil(item.formattedWordCount)
    }

    func testFormattedWordCountSmall() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false, wordCount: 42
        )
        XCTAssertEqual(item.formattedWordCount, "42 words")
    }

    func testFormattedWordCountLarge() {
        let item = MeetingHistoryItem(
            title: "T", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false, wordCount: 1240
        )
        XCTAssertEqual(item.formattedWordCount, "1,240 words")
    }

    // MARK: - Hashable / Equatable Tests

    func testEqualityByID() {
        let id = UUID()
        let item1 = MeetingHistoryItem(
            id: id, title: "A", date: Date(), directory: URL(fileURLWithPath: "/tmp/a"),
            hasAudio: true, hasMicrophone: false
        )
        let item2 = MeetingHistoryItem(
            id: id, title: "B", date: Date(), directory: URL(fileURLWithPath: "/tmp/b"),
            hasAudio: false, hasMicrophone: true
        )
        XCTAssertEqual(item1, item2)
    }

    func testInequalityByID() {
        let item1 = MeetingHistoryItem(
            title: "A", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false
        )
        let item2 = MeetingHistoryItem(
            title: "A", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false
        )
        XCTAssertNotEqual(item1, item2)
    }

    func testHashConsistentWithEquality() {
        let id = UUID()
        let item1 = MeetingHistoryItem(
            id: id, title: "A", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false
        )
        let item2 = MeetingHistoryItem(
            id: id, title: "B", date: Date(), directory: URL(fileURLWithPath: "/tmp"),
            hasAudio: true, hasMicrophone: false
        )
        XCTAssertEqual(item1.hashValue, item2.hashValue)
    }

    // MARK: - TranscriptSegment Tests

    func testTranscriptSegmentInitialization() {
        let segment = TranscriptSegment(
            segmentNumber: 1,
            originalBlocks: [],
            startTime: Date()
        )

        XCTAssertEqual(segment.segmentNumber, 1)
        XCTAssertTrue(segment.originalBlocks.isEmpty)
        XCTAssertNil(segment.refinedBlocks)
        XCTAssertFalse(segment.isRefined)
    }

    // MARK: - MeetingHistoryGroup Tests

    func testMeetingHistoryGroupInitialization() {
        let group = MeetingHistoryGroup(
            date: Date(),
            label: "Today",
            meetings: []
        )

        XCTAssertEqual(group.label, "Today")
        XCTAssertTrue(group.meetings.isEmpty)
    }
}
