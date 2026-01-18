import Foundation
@testable import Muesli

/// Mock implementation of ExportService for testing
@MainActor
final class MockExportService: ExportServiceProtocol {
    // MARK: - Properties
    
    var exportDirectory: URL
    
    // MARK: - Call Tracking
    
    var exportMeetingCalls: [MeetingHistoryItem] = []
    var exportAllMeetingsCalls: [[MeetingHistoryItem]] = []
    var generateManifestCalls: [[MeetingHistoryItem]] = []
    var createVersionMarkerCalls: Int = 0
    var setExportDirectoryCalls: [URL] = []
    var resetToDefaultExportDirectoryCalls: Int = 0
    
    // MARK: - Configurable Behavior
    
    var shouldThrowOnExport: Bool = false
    var exportAllMeetingsReturnValue: Int = 0
    
    // MARK: - Initialization
    
    init(exportDirectory: URL = FileManager.default.temporaryDirectory) {
        self.exportDirectory = exportDirectory
    }
    
    // MARK: - ExportServiceProtocol
    
    func setExportDirectory(_ url: URL) {
        setExportDirectoryCalls.append(url)
        exportDirectory = url
    }
    
    func resetToDefaultExportDirectory() {
        resetToDefaultExportDirectoryCalls += 1
    }
    
    func exportMeeting(_ meeting: MeetingHistoryItem) async throws {
        exportMeetingCalls.append(meeting)
        
        if shouldThrowOnExport {
            throw NSError(
                domain: "MockExportService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mock export error"]
            )
        }
    }
    
    func exportAllMeetings(_ meetings: [MeetingHistoryItem]) async throws -> Int {
        exportAllMeetingsCalls.append(meetings)
        
        if shouldThrowOnExport {
            throw NSError(
                domain: "MockExportService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mock export error"]
            )
        }
        
        return exportAllMeetingsReturnValue
    }
    
    func generateManifest(for meetings: [MeetingHistoryItem]) throws {
        generateManifestCalls.append(meetings)
        
        if shouldThrowOnExport {
            throw NSError(
                domain: "MockExportService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mock manifest error"]
            )
        }
    }
    
    func createVersionMarker() throws {
        createVersionMarkerCalls += 1
        
        if shouldThrowOnExport {
            throw NSError(
                domain: "MockExportService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mock version marker error"]
            )
        
        if shouldThrowOnExport {
            throw NSError(
                domain: "MockExportService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mock version marker error"]
            )
        }
    }
    
    // MARK: - Test Helpers
    
    func reset() {
        exportMeetingCalls = []
        exportAllMeetingsCalls = []
        generateManifestCalls = []
        createVersionMarkerCalls = 0
        setExportDirectoryCalls = []
        resetToDefaultExportDirectoryCalls = 0
        shouldThrowOnExport = false
        exportAllMeetingsReturnValue = 0
    }
}
