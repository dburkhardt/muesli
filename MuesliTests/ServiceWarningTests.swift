@testable import Muesli
import XCTest

/// Tests for ServiceWarning model
final class ServiceWarningTests: XCTestCase {
    // MARK: - Initialization Tests

    func testDefaultInitialization() {
        let warning = ServiceWarning(
            category: .microphone,
            message: "Mic disconnected",
            details: "USB microphone was removed"
        )

        XCTAssertEqual(warning.category, .microphone)
        XCTAssertEqual(warning.message, "Mic disconnected")
        XCTAssertEqual(warning.details, "USB microphone was removed")
        XCTAssertFalse(warning.canRetry)
        XCTAssertFalse(warning.isDismissed)
    }

    func testCustomInitialization() {
        let id = UUID()
        let date = Date.distantPast
        let warning = ServiceWarning(
            id: id,
            category: .transcription,
            message: "Transcription failed",
            details: "Model timeout",
            timestamp: date,
            canRetry: true,
            isDismissed: true
        )

        XCTAssertEqual(warning.id, id)
        XCTAssertEqual(warning.category, .transcription)
        XCTAssertTrue(warning.canRetry)
        XCTAssertTrue(warning.isDismissed)
        XCTAssertEqual(warning.timestamp, date)
    }

    // MARK: - Category Tests

    func testAllCategoriesExist() {
        let expected: [ServiceWarning.WarningCategory] = [
            .microphone, .systemAudio, .transcription,
            .fileOutput, .export, .llmRefinement, .modelLoading
        ]
        XCTAssertEqual(ServiceWarning.WarningCategory.allCases.count, expected.count)
        for category in expected {
            XCTAssertTrue(ServiceWarning.WarningCategory.allCases.contains(category))
        }
    }

    func testCategoryIconNames() {
        XCTAssertEqual(ServiceWarning.WarningCategory.microphone.iconName, "mic.slash")
        XCTAssertEqual(ServiceWarning.WarningCategory.systemAudio.iconName, "speaker.slash")
        XCTAssertEqual(ServiceWarning.WarningCategory.transcription.iconName, "text.bubble")
        XCTAssertEqual(ServiceWarning.WarningCategory.fileOutput.iconName, "doc.badge.ellipsis")
        XCTAssertEqual(ServiceWarning.WarningCategory.modelLoading.iconName, "cpu")
    }

    func testCategoryRawValues() {
        XCTAssertEqual(ServiceWarning.WarningCategory.microphone.rawValue, "Microphone")
        XCTAssertEqual(ServiceWarning.WarningCategory.systemAudio.rawValue, "System Audio")
        XCTAssertEqual(ServiceWarning.WarningCategory.export.rawValue, "Export")
    }

    // MARK: - Equality Tests

    func testEqualityByID() {
        let id = UUID()
        let warning1 = ServiceWarning(id: id, category: .microphone, message: "a", details: "b")
        let warning2 = ServiceWarning(id: id, category: .transcription, message: "c", details: "d")

        XCTAssertEqual(warning1, warning2)
    }

    func testInequalityByID() {
        let warning1 = ServiceWarning(category: .microphone, message: "a", details: "b")
        let warning2 = ServiceWarning(category: .microphone, message: "a", details: "b")

        XCTAssertNotEqual(warning1, warning2)
    }

    // MARK: - Formatted Details Tests

    func testFormattedDetailsContainsMessage() {
        let warning = ServiceWarning(
            category: .systemAudio,
            message: "Audio capture failed",
            details: "Core Audio error -10863"
        )

        let formatted = warning.formattedDetailsForCopy()

        XCTAssertTrue(formatted.contains("Audio capture failed"))
        XCTAssertTrue(formatted.contains("Core Audio error -10863"))
        XCTAssertTrue(formatted.contains("System Audio"))
        XCTAssertTrue(formatted.contains("[Muesli Warning]"))
    }

    func testFormattedDetailsContainsSystemInfo() {
        let warning = ServiceWarning(category: .transcription, message: "x", details: "y")
        let formatted = warning.formattedDetailsForCopy()

        XCTAssertTrue(formatted.contains("App Version:"))
        XCTAssertTrue(formatted.contains("macOS:"))
    }
}
