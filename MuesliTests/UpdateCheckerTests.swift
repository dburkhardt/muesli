@testable import Muesli
import XCTest

/// Tests for UpdateChecker logic (version comparison, skip versions, check intervals)
/// Network-dependent tests are not included.
@MainActor
final class UpdateCheckerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.lastUpdateCheckDate)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.skippedVersions)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.lastUpdateCheckDate)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.skippedVersions)
        try await super.tearDown()
    }

    // MARK: - shouldCheckForUpdates Tests

    func testShouldCheckWhenNeverChecked() {
        XCTAssertTrue(UpdateChecker.shared.shouldCheckForUpdates())
    }

    func testShouldNotCheckIfRecentlyChecked() {
        UpdateChecker.shared.lastCheckDate = Date()
        XCTAssertFalse(UpdateChecker.shared.shouldCheckForUpdates())
    }

    func testShouldCheckAfter24Hours() {
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        UpdateChecker.shared.lastCheckDate = twoDaysAgo
        XCTAssertTrue(UpdateChecker.shared.shouldCheckForUpdates())
    }

    // MARK: - Skip Version Tests

    func testSkipVersion() {
        UpdateChecker.shared.skipVersion("1.2.3")
        XCTAssertTrue(UpdateChecker.shared.shouldSkipVersion("1.2.3"))
        XCTAssertFalse(UpdateChecker.shared.shouldSkipVersion("1.2.4"))
    }

    func testClearSkippedVersions() {
        UpdateChecker.shared.skipVersion("1.0.0")
        UpdateChecker.shared.skipVersion("2.0.0")

        UpdateChecker.shared.clearSkippedVersions()

        XCTAssertFalse(UpdateChecker.shared.shouldSkipVersion("1.0.0"))
        XCTAssertFalse(UpdateChecker.shared.shouldSkipVersion("2.0.0"))
    }

    func testSkipMultipleVersions() {
        UpdateChecker.shared.skipVersion("1.0.0")
        UpdateChecker.shared.skipVersion("1.1.0")
        UpdateChecker.shared.skipVersion("1.2.0")

        XCTAssertTrue(UpdateChecker.shared.shouldSkipVersion("1.0.0"))
        XCTAssertTrue(UpdateChecker.shared.shouldSkipVersion("1.1.0"))
        XCTAssertTrue(UpdateChecker.shared.shouldSkipVersion("1.2.0"))
        XCTAssertFalse(UpdateChecker.shared.shouldSkipVersion("1.3.0"))
    }

    // MARK: - UpdateStatus Equality Tests

    func testUpdateStatusUpToDateEquality() {
        XCTAssertEqual(UpdateChecker.UpdateStatus.upToDate, UpdateChecker.UpdateStatus.upToDate)
    }

    func testUpdateStatusErrorEquality() {
        XCTAssertEqual(
            UpdateChecker.UpdateStatus.error("timeout"),
            UpdateChecker.UpdateStatus.error("timeout")
        )
        XCTAssertNotEqual(
            UpdateChecker.UpdateStatus.error("timeout"),
            UpdateChecker.UpdateStatus.error("network")
        )
    }

    func testUpdateStatusUpdateAvailableEquality() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(
            UpdateChecker.UpdateStatus.updateAvailable(version: "1.0", releaseNotes: "notes", downloadURL: url),
            UpdateChecker.UpdateStatus.updateAvailable(version: "1.0", releaseNotes: "notes", downloadURL: url)
        )
    }

    func testUpdateStatusMixedInequality() {
        XCTAssertNotEqual(
            UpdateChecker.UpdateStatus.upToDate,
            UpdateChecker.UpdateStatus.error("x")
        )
    }

    // MARK: - Last Check Date Persistence

    func testLastCheckDatePersists() {
        let date = Date()
        UpdateChecker.shared.lastCheckDate = date

        let retrieved = UpdateChecker.shared.lastCheckDate
        XCTAssertNotNil(retrieved)

        // Allow 1 second tolerance for ISO8601 round-trip
        XCTAssertEqual(retrieved!.timeIntervalSinceReferenceDate, date.timeIntervalSinceReferenceDate, accuracy: 1.0)
    }

    func testLastCheckDateNilWhenCleared() {
        UpdateChecker.shared.lastCheckDate = Date()
        UpdateChecker.shared.lastCheckDate = nil

        XCTAssertNil(UpdateChecker.shared.lastCheckDate)
    }
}
