@testable import Muesli
import XCTest

/// Tests for RecordingSession state machine, timer, and transcript management
@MainActor
final class RecordingSessionTests: XCTestCase {

    // MARK: - Initialization Tests

    func testDefaultState() {
        let session = RecordingSession()
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.isCompleted)
        XCTAssertEqual(session.meetingTitle, "")
        XCTAssertEqual(session.transcriptText, "")
        XCTAssertNil(session.recordingStartTime)
        XCTAssertNil(session.outputDirectory)
        XCTAssertFalse(session.isInitializing)
        XCTAssertFalse(session.isModelLoading)
        XCTAssertFalse(session.isMicrophoneMuted)
        XCTAssertEqual(session.resumeCount, 0)
        XCTAssertEqual(session.segmentNumber, 1)
    }

    func testUniqueIDs() {
        let session1 = RecordingSession()
        let session2 = RecordingSession()
        XCTAssertNotEqual(session1.id, session2.id)
    }

    func testCustomID() {
        let id = UUID()
        let session = RecordingSession(id: id)
        XCTAssertEqual(session.id, id)
    }

    // MARK: - State Machine Tests

    func testStartRecordingTransition() {
        let session = RecordingSession()
        let result = session.startRecording()
        if case .success = result {
            XCTAssertEqual(session.state, .recording)
            XCTAssertTrue(session.isRecording)
        } else {
            XCTFail("Should transition to recording")
        }
    }

    func testBeginStoppingTransition() {
        let session = RecordingSession()
        _ = session.startRecording()
        let result = session.beginStopping()
        if case .success = result {
            XCTAssertEqual(session.state, .stopping)
        } else {
            XCTFail("Should transition to stopping")
        }
    }

    func testCompleteRecordingTransition() {
        let session = RecordingSession()
        _ = session.startRecording()
        _ = session.beginStopping()
        let result = session.completeRecording()
        if case .success = result {
            XCTAssertEqual(session.state, .completed)
            XCTAssertTrue(session.isCompleted)
        } else {
            XCTFail("Should transition to completed")
        }
    }

    func testFailRecordingTransition() {
        let session = RecordingSession()
        _ = session.startRecording()
        let result = session.failRecording(reason: "Test failure")
        if case .success = result {
            XCTAssertEqual(session.state, .idle)
        } else {
            XCTFail("Should transition to failed/idle")
        }
    }

    // MARK: - Error Handling Tests

    func testShowErrorMessage() {
        let session = RecordingSession()
        session.showErrorMessage("Something went wrong")

        XCTAssertTrue(session.showError)
        XCTAssertEqual(session.errorMessage, "Something went wrong")
    }

    func testDismissError() {
        let session = RecordingSession()
        session.showErrorMessage("Error!")
        session.dismissError()

        XCTAssertFalse(session.showError)
        XCTAssertNil(session.errorMessage)
    }

    func testShowMuesliError() {
        let session = RecordingSession()
        session.showError(.modelNotFound)

        XCTAssertTrue(session.showError)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertTrue(session.errorMessage!.contains("No transcription model"))
    }

    // MARK: - Timer Tests

    func testElapsedTimeWithoutStart() {
        let session = RecordingSession()
        XCTAssertEqual(session.elapsedTimeString, "00:00")
    }

    func testElapsedTimeWithRecordingStart() {
        let session = RecordingSession()
        session.recordingStartTime = Date().addingTimeInterval(-125) // 2m 5s ago
        let elapsed = session.elapsedTimeString
        XCTAssertEqual(elapsed, "02:05")
    }

    // MARK: - Transcript Tests

    func testResetTranscript() {
        let session = RecordingSession()
        session.transcriptText = "Some text"
        session.resetTranscript()

        XCTAssertEqual(session.transcriptText, "")
        XCTAssertTrue(session.transcriptBlocks.isEmpty)
    }

    // MARK: - Audio Level Tests

    func testDefaultAudioLevels() {
        let session = RecordingSession()
        XCTAssertEqual(session.microphoneLevel, 0.0)
        XCTAssertEqual(session.systemAudioLevel, 0.0)
    }

    // MARK: - Retranscribe Tests

    func testCanRetranscribeWithoutDirectory() {
        let session = RecordingSession()
        XCTAssertFalse(session.canRetranscribe)
    }

    func testCanRetranscribeWithNonexistentDirectory() {
        let session = RecordingSession()
        session.outputDirectory = URL(fileURLWithPath: "/nonexistent/path/\(UUID())")
        XCTAssertFalse(session.canRetranscribe)
    }

    // MARK: - Resume State Tests

    func testResumeStateDefaults() {
        let session = RecordingSession()
        XCTAssertFalse(session.canResume)
        XCTAssertEqual(session.resumeCount, 0)
        XCTAssertEqual(session.segmentNumber, 1)
        XCTAssertNil(session.parentMeeting)
    }

    // MARK: - Interruption State Tests

    func testInterruptionStateDefaults() {
        let session = RecordingSession()
        XCTAssertFalse(session.wasInterrupted)
        XCTAssertNil(session.interruptionReason)
    }
}
