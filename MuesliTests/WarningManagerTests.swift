@testable import Muesli
import XCTest

/// Tests for WarningManager
@MainActor
final class WarningManagerTests: XCTestCase {

    var manager: WarningManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = WarningManager()
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Initial State

    func testInitialStateIsEmpty() {
        XCTAssertFalse(manager.hasActiveWarnings)
        XCTAssertEqual(manager.activeWarningCount, 0)
        XCTAssertTrue(manager.activeWarnings.isEmpty)
    }

    // MARK: - Add Warning

    func testAddWarningAppearsInActive() {
        manager.addWarning(.microphone, message: "Mic error", details: "Detail")

        XCTAssertTrue(manager.hasActiveWarnings)
        XCTAssertEqual(manager.activeWarningCount, 1)
        XCTAssertEqual(manager.activeWarnings.first?.category, .microphone)
        XCTAssertEqual(manager.activeWarnings.first?.message, "Mic error")
    }

    func testAddMultipleWarnings() {
        manager.addWarning(.microphone, message: "Mic", details: "d1")
        manager.addWarning(.transcription, message: "Trans", details: "d2")
        manager.addWarning(.systemAudio, message: "Audio", details: "d3")

        XCTAssertEqual(manager.activeWarningCount, 3)
    }

    func testAddDuplicateCategoryUpdatesExisting() {
        manager.addWarning(.microphone, message: "First", details: "d1")
        let firstID = manager.activeWarnings.first?.id

        manager.addWarning(.microphone, message: "Second", details: "d2")

        XCTAssertEqual(manager.activeWarningCount, 1)
        XCTAssertEqual(manager.activeWarnings.first?.message, "Second")
        XCTAssertEqual(manager.activeWarnings.first?.id, firstID, "Should keep same ID for animation continuity")
    }

    func testAddWarningWithRetry() {
        manager.addWarning(.transcription, message: "Failed", details: "d", canRetry: true)

        XCTAssertTrue(manager.activeWarnings.first!.canRetry)
    }

    // MARK: - Dismiss Warning

    func testDismissWarningByID() {
        manager.addWarning(.microphone, message: "Mic", details: "d")
        let id = manager.activeWarnings.first!.id

        manager.dismissWarning(id)

        XCTAssertFalse(manager.hasActiveWarnings)
        XCTAssertEqual(manager.activeWarningCount, 0)
    }

    func testDismissWarningByCategory() {
        manager.addWarning(.microphone, message: "Mic", details: "d")
        manager.addWarning(.transcription, message: "Trans", details: "d")

        manager.dismissWarnings(for: .microphone)

        XCTAssertEqual(manager.activeWarningCount, 1)
        XCTAssertEqual(manager.activeWarnings.first?.category, .transcription)
    }

    func testDismissedWarningResurfacesOnNewAdd() {
        manager.addWarning(.microphone, message: "First", details: "d")
        let id = manager.activeWarnings.first!.id
        manager.dismissWarning(id)

        XCTAssertFalse(manager.hasActiveWarnings)

        manager.addWarning(.microphone, message: "Resurfaced", details: "d2")

        XCTAssertTrue(manager.hasActiveWarnings)
        XCTAssertEqual(manager.activeWarnings.first?.message, "Resurfaced")
    }

    // MARK: - Clear

    func testClearAll() {
        manager.addWarning(.microphone, message: "Mic", details: "d")
        manager.addWarning(.transcription, message: "Trans", details: "d")

        manager.clearAll()

        XCTAssertFalse(manager.hasActiveWarnings)
        XCTAssertEqual(manager.activeWarningCount, 0)
    }

    func testClearDismissedKeepsActive() {
        manager.addWarning(.microphone, message: "Mic", details: "d")
        manager.addWarning(.transcription, message: "Trans", details: "d")

        let micID = manager.activeWarnings.first { $0.category == .microphone }!.id
        manager.dismissWarning(micID)

        manager.clearDismissed()

        XCTAssertEqual(manager.activeWarningCount, 1)
        XCTAssertEqual(manager.activeWarnings.first?.category, .transcription)
    }

    // MARK: - Get Warning

    func testGetWarningByID() {
        manager.addWarning(.microphone, message: "Mic", details: "d")
        let id = manager.activeWarnings.first!.id

        let warning = manager.getWarning(id)
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.message, "Mic")
    }

    func testGetWarningWithInvalidID() {
        let warning = manager.getWarning(UUID())
        XCTAssertNil(warning)
    }

    // MARK: - Has Active Warning

    func testHasActiveWarningForCategory() {
        manager.addWarning(.microphone, message: "Mic", details: "d")

        XCTAssertTrue(manager.hasActiveWarning(for: .microphone))
        XCTAssertFalse(manager.hasActiveWarning(for: .transcription))
    }

    func testHasActiveWarningFalseAfterDismiss() {
        manager.addWarning(.microphone, message: "Mic", details: "d")
        manager.dismissWarnings(for: .microphone)

        XCTAssertFalse(manager.hasActiveWarning(for: .microphone))
    }
}
