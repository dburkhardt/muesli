import Foundation
import os.log

/// Service responsible for exporting meeting transcripts and metadata to a structured folder
/// that external tools (MCP servers, IDE extensions) can access as a read-only knowledge source
@MainActor
final class ExportService: ExportServiceProtocol {
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "ExportService")
    
    // MARK: - Properties
    
    private let fileManager = FileManager.default
    private var customExportPath: URL?
    
    /// Default export path (Application Support - no special permissions required)
    private static let defaultExportPath: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Muesli/Exports", isDirectory: true)
    }()
    
    /// Current export directory (custom or default)
    var exportDirectory: URL {
        customExportPath ?? Self.defaultExportPath
    }
    
    // MARK: - Initialization
    
    init() {
        // Load saved export directory from UserDefaults
        if let savedPath = UserDefaults.standard.string(forKey: AppStorageKeys.exportDirectory) {
            customExportPath = URL(fileURLWithPath: savedPath)
        }
    }
    
    // MARK: - Configuration
    
    /// Set a custom export directory
    func setExportDirectory(_ url: URL) {
        customExportPath = url
        UserDefaults.standard.set(url.path, forKey: AppStorageKeys.exportDirectory)
    }
    
    /// Reset to default export directory
    func resetToDefaultExportDirectory() {
        customExportPath = nil
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.exportDirectory)
    }
    
    // MARK: - Export Operations
    
    /// Export a single meeting to the export directory
    /// - Parameter meeting: The meeting to export
    /// - Throws: ExportError if export fails
    func exportMeeting(_ meeting: MeetingHistoryItem) async throws {
        logger.info("Exporting meeting: \(meeting.title)")
        
        // Ensure export directory exists
        try ensureExportDirectoryExists()
        
        // Create meeting export directory
        let meetingExportDir = try createMeetingExportDirectory(for: meeting)
        
        // Copy transcript.md
        try copyTranscript(from: meeting.directory, to: meetingExportDir)
        
        // Generate metadata.json
        try generateMetadataFile(for: meeting, at: meetingExportDir)
        
        logger.info("Successfully exported meeting: \(meeting.title)")
    }
    
    /// Export all meetings to the export directory
    /// - Parameter meetings: Array of meetings to export
    /// - Returns: Number of successfully exported meetings
    func exportAllMeetings(_ meetings: [MeetingHistoryItem]) async throws -> Int {
        logger.info("Exporting \(meetings.count) meetings")
        
        var successCount = 0
        var errors: [String] = []
        
        for meeting in meetings {
            do {
                try await exportMeeting(meeting)
                successCount += 1
            } catch {
                let errorMsg = "Failed to export '\(meeting.title)': \(error.localizedDescription)"
                logger.error("\(errorMsg)")
                errors.append(errorMsg)
            }
        }
        
        // Generate manifest after all exports
        try generateManifest(for: meetings)
        
        if !errors.isEmpty {
            logger.warning("Exported \(successCount)/\(meetings.count) meetings with \(errors.count) errors")
        } else {
            logger.info("Successfully exported all \(successCount) meetings")
        }
        
        return successCount
    }
    
    /// Generate the global manifest.json file
    /// - Parameter meetings: All meetings to include in the manifest
    func generateManifest(for meetings: [MeetingHistoryItem]) throws {
        logger.info("Generating manifest for \(meetings.count) meetings")
        
        let manifestPath = exportDirectory.appendingPathComponent("manifest.json")
        
        let manifest = ExportManifest(
            version: "1.0",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            totalMeetings: meetings.count,
            meetings: meetings.map { meeting in
                ExportManifest.MeetingEntry(
                    id: meeting.id.uuidString,
                    title: meeting.title,
                    date: ISO8601DateFormatter().string(from: meeting.date),
                    directory: "meetings/\(meeting.directory.lastPathComponent)",
                    hasAudio: meeting.hasAudio,
                    hasMicrophone: meeting.hasMicrophone,
                    duration: meeting.duration,
                    wordCount: meeting.wordCount,
                    isRefined: meeting.isRefined,
                    segmentCount: meeting.segmentCount
                )
            }
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestPath)
        
        logger.info("Manifest generated at \(manifestPath.path)")
    }
    
    /// Create or update the version marker file
    func createVersionMarker() throws {
        let markerPath = exportDirectory.appendingPathComponent(".muesli-export")
        let versionInfo = "version=1.0\nformat=markdown+json\n"
        try versionInfo.write(to: markerPath, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Private Helpers
    
    /// Ensure the export directory structure exists
    private func ensureExportDirectoryExists() throws {
        let baseDir = exportDirectory
        let meetingsDir = baseDir.appendingPathComponent("meetings", isDirectory: true)
        
        // Create base export directory
        if !fileManager.fileExists(atPath: baseDir.path) {
            try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
            logger.info("Created export directory: \(baseDir.path)")
        }
        
        // Create meetings subdirectory
        if !fileManager.fileExists(atPath: meetingsDir.path) {
            try fileManager.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
            logger.info("Created meetings directory: \(meetingsDir.path)")
        }
        
        // Create version marker
        try createVersionMarker()
    }
    
    /// Create export directory for a specific meeting
    private func createMeetingExportDirectory(for meeting: MeetingHistoryItem) throws -> URL {
        let meetingsDir = exportDirectory.appendingPathComponent("meetings", isDirectory: true)
        let meetingDir = meetingsDir.appendingPathComponent(meeting.directory.lastPathComponent, isDirectory: true)
        
        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: meetingDir.path) {
            try fileManager.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        }
        
        return meetingDir
    }
    
    /// Copy transcript.md from recording directory to export directory
    private func copyTranscript(from sourceDir: URL, to destDir: URL) throws {
        let sourceTranscript = sourceDir.appendingPathComponent("transcript.md")
        let destTranscript = destDir.appendingPathComponent("transcript.md")
        
        // Remove existing file if present
        if fileManager.fileExists(atPath: destTranscript.path) {
            try fileManager.removeItem(at: destTranscript)
        }
        
        // Copy transcript
        try fileManager.copyItem(at: sourceTranscript, to: destTranscript)
    }
    
    /// Generate metadata.json for a meeting
    private func generateMetadataFile(for meeting: MeetingHistoryItem, at exportDir: URL) throws {
        let metadataPath = exportDir.appendingPathComponent("metadata.json")
        
        // Get relative path to recordings directory for audio file references
        let audioPath = meeting.hasAudio ?
            "../../Recordings/\(meeting.directory.lastPathComponent)/audio.caf" : nil
        let micPath = meeting.hasMicrophone ?
            "../../Recordings/\(meeting.directory.lastPathComponent)/microphone.caf" : nil
        
        let metadata = MeetingMetadata(
            id: meeting.id.uuidString,
            title: meeting.title,
            date: ISO8601DateFormatter().string(from: meeting.date),
            duration: meeting.duration,
            wordCount: meeting.wordCount,
            hasAudio: meeting.hasAudio,
            hasMicrophone: meeting.hasMicrophone,
            isRefined: meeting.isRefined,
            segmentCount: meeting.segmentCount,
            segments: meeting.transcriptSegments.map { segment in
                MeetingMetadata.SegmentInfo(
                    segmentNumber: segment.segmentNumber,
                    startTime: ISO8601DateFormatter().string(from: segment.startTime),
                    isRefined: segment.isRefined
                )
            },
            files: MeetingMetadata.FileReferences(
                transcript: "transcript.md",
                audio: audioPath,
                microphone: micPath
            )
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataPath)
    }
}

// MARK: - Data Models

/// Global manifest structure
private struct ExportManifest: Codable {
    let version: String
    let generatedAt: String
    let totalMeetings: Int
    let meetings: [MeetingEntry]
    
    struct MeetingEntry: Codable {
        let id: String
        let title: String
        let date: String
        let directory: String
        let hasAudio: Bool
        let hasMicrophone: Bool
        let duration: TimeInterval?
        let wordCount: Int?
        let isRefined: Bool
        let segmentCount: Int
    }
}

/// Per-meeting metadata structure
private struct MeetingMetadata: Codable {
    let id: String
    let title: String
    let date: String
    let duration: TimeInterval?
    let wordCount: Int?
    let hasAudio: Bool
    let hasMicrophone: Bool
    let isRefined: Bool
    let segmentCount: Int
    let segments: [SegmentInfo]
    let files: FileReferences
    
    struct SegmentInfo: Codable {
        let segmentNumber: Int
        let startTime: String
        let isRefined: Bool
    }
    
    struct FileReferences: Codable {
        let transcript: String
        let audio: String?
        let microphone: String?
    }
}

// MARK: - Error Types

enum ExportError: LocalizedError {
    case directoryCreationFailed(Error)
    case fileCopyFailed(Error)
    case metadataGenerationFailed(Error)
    case manifestGenerationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let error):
            return "Failed to create export directory: \(error.localizedDescription)"
        case .fileCopyFailed(let error):
            return "Failed to copy transcript file: \(error.localizedDescription)"
        case .metadataGenerationFailed(let error):
            return "Failed to generate metadata: \(error.localizedDescription)"
        case .manifestGenerationFailed(let error):
            return "Failed to generate manifest: \(error.localizedDescription)"
        }
    }
}
