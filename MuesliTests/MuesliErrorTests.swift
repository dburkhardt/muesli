@testable import Muesli
import XCTest

/// Tests for MuesliError, RecordingError, and ServiceWarning types
final class MuesliErrorTests: XCTestCase {

    // MARK: - Error Description Tests

    func testScreenRecordingDeniedDescription() {
        let error = MuesliError.screenRecordingDenied
        XCTAssertEqual(error.errorDescription, "Screen Recording permission is required")
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("System Settings"))
    }

    func testMicrophoneDeniedDescription() {
        let error = MuesliError.microphoneDenied
        XCTAssertEqual(error.errorDescription, "Microphone permission is required")
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testPermissionsMissingDescription() {
        let error = MuesliError.permissionsMissing
        XCTAssertEqual(error.errorDescription, "Required permissions are missing")
    }

    func testModelNotFoundDescription() {
        let error = MuesliError.modelNotFound
        XCTAssertEqual(error.errorDescription, "No transcription model available")
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("Preferences"))
    }

    func testModelCorruptedDescription() {
        let error = MuesliError.modelCorrupted(modelName: "whisper-large")
        XCTAssertEqual(error.errorDescription, "Model 'whisper-large' appears to be corrupted")
    }

    func testModelLoadFailedDescription() {
        let underlying = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "load error"])
        let error = MuesliError.modelLoadFailed(underlying: underlying)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("load error"))
    }

    func testAlreadyRecordingDescription() {
        let error = MuesliError.alreadyRecording
        XCTAssertEqual(error.errorDescription, "A recording is already in progress")
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testNotRecordingDescription() {
        let error = MuesliError.notRecording
        XCTAssertEqual(error.errorDescription, "No recording is currently in progress")
        XCTAssertNil(error.recoverySuggestion)
    }

    func testCapturedAppClosedDescription() {
        let error = MuesliError.capturedAppClosed(appName: "Zoom")
        XCTAssertEqual(error.errorDescription, "'Zoom' was closed")
    }

    func testTranscriptionFailedDescription() {
        let underlying = NSError(domain: "test", code: 2)
        let error = MuesliError.transcriptionFailed(underlying: underlying)
        XCTAssertNotNil(error.errorDescription)
    }

    func testWhisperKitNotInitializedDescription() {
        let error = MuesliError.whisperKitNotInitialized
        XCTAssertEqual(error.errorDescription, "Transcription engine not initialized")
    }

    func testMeetingDirectoryNotFoundDescription() {
        let error = MuesliError.meetingDirectoryNotFound
        XCTAssertEqual(error.errorDescription, "Meeting directory not found")
    }

    func testLlmModelNotAvailableDescription() {
        let error = MuesliError.llmModelNotAvailable
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("LLM"))
    }

    // MARK: - Failure Reason Groups

    func testPermissionErrorsShareFailureReason() {
        let errors: [MuesliError] = [.screenRecordingDenied, .microphoneDenied, .permissionsMissing]
        for error in errors {
            XCTAssertEqual(error.failureReason, "The app doesn't have the required permissions.")
        }
    }

    func testModelErrorsShareFailureReason() {
        let underlying = NSError(domain: "test", code: 0)
        let errors: [MuesliError] = [
            .modelNotFound,
            .modelCorrupted(modelName: "x"),
            .modelLoadFailed(underlying: underlying),
            .modelDownloadFailed(underlying: underlying)
        ]
        for error in errors {
            XCTAssertEqual(error.failureReason, "There was a problem with the transcription model.")
        }
    }

    func testRecordingStateErrorsHaveNilFailureReason() {
        XCTAssertNil(MuesliError.alreadyRecording.failureReason)
        XCTAssertNil(MuesliError.notRecording.failureReason)
    }

    // MARK: - RecordingError Tests

    func testRecordingErrorStartingContext() {
        let error = RecordingError(
            underlying: .screenRecordingDenied,
            context: .starting(app: "Zoom"),
            sessionID: UUID()
        )
        XCTAssertTrue(error.errorDescription!.contains("Zoom"))
        XCTAssertTrue(error.errorDescription!.contains("Failed to start recording"))
    }

    func testRecordingErrorStartingWithoutApp() {
        let error = RecordingError(
            underlying: .noAudioContent,
            context: .starting(app: nil)
        )
        XCTAssertTrue(error.errorDescription!.contains("Failed to start recording"))
        XCTAssertFalse(error.errorDescription!.contains("nil"))
    }

    func testRecordingErrorRecordingContext() {
        let error = RecordingError(
            underlying: .captureStartFailed(underlying: NSError(domain: "", code: 0)),
            context: .recording(duration: 120)
        )
        XCTAssertTrue(error.errorDescription!.contains("120s"))
    }

    func testRecordingErrorStoppingContext() {
        let error = RecordingError(
            underlying: .notRecording,
            context: .stopping
        )
        XCTAssertTrue(error.errorDescription!.contains("Failed to stop"))
    }

    func testRecordingErrorSavingContext() {
        let dir = URL(fileURLWithPath: "/tmp/test")
        let error = RecordingError(
            underlying: .transcriptSaveFailed(underlying: NSError(domain: "", code: 0)),
            context: .saving(directory: dir)
        )
        XCTAssertTrue(error.errorDescription!.contains("Failed to save"))
    }

    func testRecordingErrorTranscribingContext() {
        let error = RecordingError(
            underlying: .transcriptionFailed(underlying: NSError(domain: "", code: 0)),
            context: .transcribing(modelName: "large-v3")
        )
        XCTAssertTrue(error.errorDescription!.contains("large-v3"))
    }

    func testRecordingErrorHasTimestamp() {
        let before = Date()
        let error = RecordingError(underlying: .notRecording, context: .stopping)
        let after = Date()

        XCTAssertGreaterThanOrEqual(error.timestamp, before)
        XCTAssertLessThanOrEqual(error.timestamp, after)
    }

    func testRecordingErrorRecoverySuggestionDelegates() {
        let error = RecordingError(underlying: .modelNotFound, context: .stopping)
        XCTAssertEqual(error.recoverySuggestion, MuesliError.modelNotFound.recoverySuggestion)
    }
}
