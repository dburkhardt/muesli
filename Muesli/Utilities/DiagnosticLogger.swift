import AVFoundation
import Foundation

/// Thread-safe actor for file-based diagnostic logging
/// Writes structured logs to `~/Library/Application Support/Muesli/Logs/`
///
/// PRIVACY POLICY: Only log build/permission metadata. NO user content.
/// - Allowed: Bundle ID, version, permission states, step numbers, button taps, timestamps
/// - NEVER: Transcript content, meeting titles, user file paths, audio data, PII
actor DiagnosticLogger {
    static let shared = DiagnosticLogger()
    
    /// Log categories for filtering and searching
    enum Category: String {
        case permission = "PERMISSION"
        case onboarding = "ONBOARDING"
        case build = "BUILD"
        case app = "APP"
        case transcription = "TRANSCRIPTION"  // Debug category for transcription issues
        case aec = "AEC"  // Echo cancellation diagnostics
        case stabilizer = "STABILIZER"  // Live stabilizer and second-pass metrics
    }
    
    /// Maximum log file size (10MB)
    private let maxFileSize: UInt64 = 10 * 1024 * 1024
    
    /// Number of days to retain logs
    private let retentionDays: Int = 7
    
    /// Logs directory URL
    private var logsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Muesli/Logs", isDirectory: true)
    }
    
    /// Current log file path (based on today's date)
    private var currentLogFile: URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        return logsDirectory.appendingPathComponent("muesli-\(dateString).log")
    }
    
    /// Date formatter for timestamps
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    // MARK: - Public API
    
    /// Log a message with category
    /// Format: [TIMESTAMP] [CATEGORY] MESSAGE
    func log(_ category: Category, _ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let logLine = "[\(timestamp)] [\(category.rawValue)] \(message)\n"
        
        writeToFile(logLine)
    }
    
    /// Log build information on app launch
    /// Should be called once during applicationDidFinishLaunching
    func logBuildInfo() {
        // Ensure logs directory exists
        ensureLogsDirectoryExists()
        
        // Clean up old logs
        cleanupOldLogs()
        
        // Log separator for new session
        writeToFile("\n" + String(repeating: "=", count: 60) + "\n")
        
        log(.build, "=== App Launch ===")
        
        // Bundle info
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        log(.build, "Bundle ID: \(bundleID)")
        
        // Version info
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        log(.build, "Version: \(version) (\(buildNumber))")
        
        // Build configuration
        #if DEBUG
        log(.build, "Configuration: DEBUG")
        #else
        log(.build, "Configuration: RELEASE")
        #endif
        
        // Git build info (from auto-generated BuildInfo.swift)
        let dirtyFlag = BuildInfo.isDirty ? " (dirty)" : ""
        log(.build, "Git Commit: \(BuildInfo.gitCommit)\(dirtyFlag)")
        log(.build, "Git Branch: \(BuildInfo.gitBranch)")
        log(.build, "Build Type: \(BuildInfo.buildType)")
        log(.build, "Build Timestamp: \(BuildInfo.buildTimestamp)")
        if BuildInfo.isCIBuild {
            log(.build, "CI Build: \(BuildInfo.ciRunInfo)")
        }
        
        // Info.plist permission descriptions
        let micDesc = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        log(.build, "NSMicrophoneUsageDescription: \(micDesc ?? "MISSING")")
        
        let screenDesc = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String
        log(.build, "NSScreenCaptureUsageDescription: \(screenDesc ?? "MISSING")")
        
        // Current permission states (using AVCaptureDevice for microphone - safe to check)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log(.build, "Initial microphone status: \(micStatus.rawValue) (\(statusName(micStatus)))")
        
        // Note: Screen recording status not checked here to avoid triggering prompt
        log(.build, "Screen recording: will be checked on permission screen")
        
        // Team ID from code signing (if available)
        if let teamID = Bundle.main.infoDictionary?["TeamIdentifierPrefix"] as? String {
            log(.build, "Team ID: \(teamID)")
        }
        
        log(.build, "Log file: \(currentLogFile.path)")
    }
    
    /// Get the current log file path (for Debug Info view)
    func getLogFilePath() -> String {
        return currentLogFile.path
    }
    
    /// Get the logs directory path (for Debug Info view)
    func getLogsDirectoryPath() -> String {
        return logsDirectory.path
    }
    
    // MARK: - Private Methods
    
    private func ensureLogsDirectoryExists() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logsDirectory.path) {
            try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        }
    }
    
    private func writeToFile(_ content: String) {
        ensureLogsDirectoryExists()
        
        let fileManager = FileManager.default
        let filePath = currentLogFile.path
        
        // Check file size before writing
        if let attrs = try? fileManager.attributesOfItem(atPath: filePath),
           let fileSize = attrs[.size] as? UInt64,
           fileSize > maxFileSize {
            // File too large - skip writing to this file
            // A new file will be created tomorrow
            return
        }
        
        // Create file if it doesn't exist
        if !fileManager.fileExists(atPath: filePath) {
            fileManager.createFile(atPath: filePath, contents: nil)
        }
        
        // Append to file
        if let fileHandle = FileHandle(forWritingAtPath: filePath) {
            defer { try? fileHandle.close() }
            fileHandle.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                fileHandle.write(data)
            }
        }
    }
    
    private func cleanupOldLogs() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }
        
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        
        for file in files {
            guard file.pathExtension == "log" else { continue }
            
            if let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
               let creationDate = attrs.creationDate,
               creationDate < cutoffDate {
                try? fileManager.removeItem(at: file)
            }
        }
    }
    
    private func statusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }
}
