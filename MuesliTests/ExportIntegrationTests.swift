import Foundation
@testable import Muesli
import XCTest

/// Integration tests for export functionality in RecordingController and MuesliViewModel
@MainActor
final class ExportIntegrationTests: XCTestCase {
    override func tearDown() {
        // Clean up UserDefaults
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.exportEnabled)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.exportDirectory)
        super.tearDown()
    }
    
    // MARK: - MuesliViewModel Export Tests
    
    func testViewModelExportEnabled() {
        let prefs = PreferencesManager()
        prefs.exportEnabled = true
        
        let mockExport = MockExportService()
        let viewModel = MuesliViewModel(
            preferencesManager: prefs,
            exportService: mockExport,
            skipInitialLoad: true
        )
        
        XCTAssertTrue(viewModel.exportEnabled)
        
        viewModel.exportEnabled = false
        XCTAssertFalse(viewModel.exportEnabled)
        XCTAssertFalse(prefs.exportEnabled)
    }
    
    func testViewModelExportDirectory() {
        let prefs = PreferencesManager()
        let customDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-export")
        prefs.exportDirectory = customDir
        
        let mockExport = MockExportService()
        let viewModel = MuesliViewModel(
            preferencesManager: prefs,
            exportService: mockExport,
            skipInitialLoad: true
        )
        
        XCTAssertEqual(viewModel.exportDirectory, customDir)
        
        // Test setter
        let newDir = FileManager.default.temporaryDirectory.appendingPathComponent("new-export")
        viewModel.exportDirectory = newDir
        
        XCTAssertEqual(viewModel.exportDirectory, newDir)
        XCTAssertEqual(prefs.exportDirectory, newDir)
        XCTAssertEqual(mockExport.setExportDirectoryCalls.count, 1)
        XCTAssertEqual(mockExport.setExportDirectoryCalls[0], newDir)
    }
    
    func testViewModelResetExportDirectory() {
        let prefs = PreferencesManager()
        let customDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-export")
        prefs.exportDirectory = customDir
        
        let mockExport = MockExportService()
        let viewModel = MuesliViewModel(
            preferencesManager: prefs,
            exportService: mockExport,
            skipInitialLoad: true
        )
        
        viewModel.resetExportDirectory()
        
        XCTAssertEqual(prefs.exportDirectory, PreferencesManager.defaultExportDirectory)
        XCTAssertEqual(mockExport.resetToDefaultExportDirectoryCalls, 1)
    }
    
    func testViewModelExportAllMeetings() async {
        let prefs = PreferencesManager()
        let mockExport = MockExportService()
        mockExport.exportAllMeetingsReturnValue = 5
        
        let viewModel = MuesliViewModel(
            preferencesManager: prefs,
            exportService: mockExport,
            skipInitialLoad: true
        )
        
        let count = await viewModel.exportAllMeetings()
        
        XCTAssertEqual(count, 5)
        XCTAssertEqual(mockExport.exportAllMeetingsCalls.count, 1)
    }
    
    func testViewModelExportAllMeetingsErrorHandling() async {
        let prefs = PreferencesManager()
        let mockExport = MockExportService()
        mockExport.shouldThrowOnExport = true
        
        let viewModel = MuesliViewModel(
            preferencesManager: prefs,
            exportService: mockExport,
            skipInitialLoad: true
        )
        
        // Should not crash, should return 0
        let count = await viewModel.exportAllMeetings()
        
        XCTAssertEqual(count, 0)
    }
    
    // MARK: - MockExportService Tests
    
    func testMockExportServiceTracking() async throws {
        let mockExport = MockExportService()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mock-test")
        
        mockExport.setExportDirectory(tempDir)
        XCTAssertEqual(mockExport.setExportDirectoryCalls.count, 1)
        XCTAssertEqual(mockExport.setExportDirectoryCalls[0], tempDir)
        
        mockExport.resetToDefaultExportDirectory()
        XCTAssertEqual(mockExport.resetToDefaultExportDirectoryCalls, 1)
        
        try mockExport.createVersionMarker()
        XCTAssertEqual(mockExport.createVersionMarkerCalls, 1)
        
        let meeting = createTestMeeting()
        try await mockExport.exportMeeting(meeting)
        XCTAssertEqual(mockExport.exportMeetingCalls.count, 1)
        XCTAssertEqual(mockExport.exportMeetingCalls[0].id, meeting.id)
        
        mockExport.exportAllMeetingsReturnValue = 3
        let count = try await mockExport.exportAllMeetings([meeting])
        XCTAssertEqual(count, 3)
        XCTAssertEqual(mockExport.exportAllMeetingsCalls.count, 1)
        
        try mockExport.generateManifest(for: [meeting])
        XCTAssertEqual(mockExport.generateManifestCalls.count, 1)
    }
    
    func testMockExportServiceErrorSimulation() async {
        let mockExport = MockExportService()
        mockExport.shouldThrowOnExport = true
        
        let meeting = createTestMeeting()
        
        do {
            try await mockExport.exportMeeting(meeting)
            XCTFail("Should have thrown an error")
        } catch {
            // Expected
            XCTAssertTrue(true)
        }
        
        do {
            try await mockExport.exportAllMeetings([meeting])
            XCTFail("Should have thrown an error")
        } catch {
            // Expected
            XCTAssertTrue(true)
        }
        
        do {
            try mockExport.generateManifest(for: [meeting])
            XCTFail("Should have thrown an error")
        } catch {
            // Expected
            XCTAssertTrue(true)
        }
    }
    
    func testMockExportServiceReset() async throws {
        let mockExport = MockExportService()
        let meeting = createTestMeeting()
        
        // Add some calls
        try await mockExport.exportMeeting(meeting)
        mockExport.setExportDirectory(FileManager.default.temporaryDirectory)
        try mockExport.createVersionMarker()
        
        XCTAssertFalse(mockExport.exportMeetingCalls.isEmpty)
        XCTAssertFalse(mockExport.setExportDirectoryCalls.isEmpty)
        XCTAssertGreaterThan(mockExport.createVersionMarkerCalls, 0)
        
        // Reset
        mockExport.reset()
        
        XCTAssertTrue(mockExport.exportMeetingCalls.isEmpty)
        XCTAssertTrue(mockExport.setExportDirectoryCalls.isEmpty)
        XCTAssertEqual(mockExport.createVersionMarkerCalls, 0)
        XCTAssertFalse(mockExport.shouldThrowOnExport)
    }
    
    // MARK: - Helper Methods
    
    private func createTestMeeting(title: String = "Test Meeting") -> MeetingHistoryItem {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return MeetingHistoryItem(
            id: UUID(),
            title: title,
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
    }
}

// MARK: - AppStorageKeys Tests

final class AppStorageKeysExportTests: XCTestCase {
    func testExportKeysAreDefined() {
        XCTAssertEqual(AppStorageKeys.exportEnabled, "exportEnabled")
        XCTAssertEqual(AppStorageKeys.exportDirectory, "exportDirectory")
    }
    
    func testExportKeysAreUnique() {
        let allKeys = [
            AppStorageKeys.hasCompletedOnboarding,
            AppStorageKeys.onboardingCurrentStep,
            AppStorageKeys.outputDirectory,
            AppStorageKeys.launchAtLogin,
            AppStorageKeys.transcriptionMode,
            AppStorageKeys.echoCancellationEnabled,
            AppStorageKeys.audioChunkDuration,
            AppStorageKeys.exportEnabled,
            AppStorageKeys.exportDirectory,
            AppStorageKeys.activeWhisperModel,
            AppStorageKeys.downloadedWhisperModels,
            AppStorageKeys.activeLLMModel,
            AppStorageKeys.downloadedLLMModels,
            AppStorageKeys.lastUpdateCheckDate,
            AppStorageKeys.skippedVersions
        ]
        
        // Check for uniqueness
        let uniqueKeys = Set(allKeys)
        XCTAssertEqual(uniqueKeys.count, allKeys.count, "All AppStorageKeys should be unique")
    }
}
