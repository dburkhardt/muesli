import Foundation
import ServiceManagement

/// Manages app preferences with UserDefaults persistence
/// Extracted from MuesliViewModel as part of the god object refactoring
@Observable
@MainActor
final class PreferencesManager {
    
    // MARK: - UserDefaults Keys
    
    private static let outputDirectoryKey = "outputDirectory"
    private static let launchAtLoginKey = "launchAtLogin"
    private static let transcriptionModeKey = "transcriptionMode"
    private static let echoCancellationEnabledKey = "echoCancellationEnabled"
    
    // MARK: - Output Directory
    
    /// Output directory for recordings
    var outputDirectory: URL {
        get {
            if let savedPath = UserDefaults.standard.string(forKey: Self.outputDirectoryKey) {
                return URL(fileURLWithPath: savedPath)
            }
            return Self.defaultOutputDirectory
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: Self.outputDirectoryKey)
            outputDirectoryDidChange?(newValue)
        }
    }
    
    /// Default output directory: ~/Library/Application Support/Muesli/Recordings
    static var defaultOutputDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Muesli/Recordings")
    }
    
    /// Callback when output directory changes (for FileOutputService integration)
    var outputDirectoryDidChange: ((URL) -> Void)?
    
    /// Set the output directory
    func setOutputDirectory(_ url: URL) {
        outputDirectory = url
    }
    
    /// Reset output directory to default
    func resetOutputDirectory() {
        UserDefaults.standard.removeObject(forKey: Self.outputDirectoryKey)
        outputDirectoryDidChange?(Self.defaultOutputDirectory)
    }
    
    // MARK: - Launch at Login
    
    /// Whether to launch at login
    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return UserDefaults.standard.bool(forKey: Self.launchAtLoginKey)
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("[PreferencesManager] Failed to set launch at login: \(error)")
                }
            }
            UserDefaults.standard.set(newValue, forKey: Self.launchAtLoginKey)
        }
    }
    
    /// Set launch at login
    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
    }
    
    // MARK: - Transcription Mode
    
    /// Transcription mode: live (real-time) or post-processing (after recording)
    var transcriptionMode: TranscriptionMode {
        get {
            let rawValue = UserDefaults.standard.string(forKey: Self.transcriptionModeKey) ?? "live"
            return TranscriptionMode(rawValue: rawValue) ?? .live
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.transcriptionModeKey)
            transcriptionModeDidChange?(newValue)
        }
    }
    
    /// Callback when transcription mode changes (for TranscriptionService integration)
    var transcriptionModeDidChange: ((TranscriptionMode) -> Void)?
    
    /// Transcription mode enum (mirrors TranscriptionService.TranscriptionMode)
    enum TranscriptionMode: String, CaseIterable {
        case live
        case postProcessing
    }
    
    // MARK: - Echo Cancellation
    
    /// Whether echo cancellation is enabled
    /// Uses a cached value for thread-safe access from audio callbacks
    var isEchoCancellationEnabled: Bool {
        get {
            _isEchoCancellationEnabled
        }
        set {
            _isEchoCancellationEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Self.echoCancellationEnabledKey)
        }
    }
    
    /// Cached value for thread-safe access from audio callbacks
    /// Uses nonisolated(unsafe) for synchronous access from audio callback
    nonisolated(unsafe) private var _isEchoCancellationEnabled: Bool = false
    
    /// Thread-safe getter for audio callbacks (nonisolated)
    nonisolated var echoCancellationEnabledForAudioCallback: Bool {
        _isEchoCancellationEnabled
    }
    
    // MARK: - Initialization

    init(skipMigration: Bool = false) {
        // Load persisted echo cancellation state
        _isEchoCancellationEnabled = UserDefaults.standard.bool(forKey: Self.echoCancellationEnabledKey)

        // Perform storage migration if needed (skip in tests)
        if !skipMigration {
            migrateStorageLocationIfNeeded()
        }
    }

    // MARK: - Storage Migration

    /// Migrate from old default location (~/Documents/Meeting Transcripts) to new location
    /// (~/Library/Application Support/Muesli/Recordings) while preserving existing recordings
    private func migrateStorageLocationIfNeeded() {
        // Only migrate if user hasn't set a custom output directory
        guard UserDefaults.standard.string(forKey: Self.outputDirectoryKey) == nil else {
            print("[PreferencesManager] Custom output directory set, skipping migration")
            return
        }

        // Check if old location exists and has content
        let oldDefaultDirectory: URL = {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            return documentsPath.appendingPathComponent("Meeting Transcripts")
        }()

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: oldDefaultDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            print("[PreferencesManager] Old directory doesn't exist, no migration needed")
            return
        }

        // Check if old directory has any meeting folders
        guard let contents = try? fileManager.contentsOfDirectory(atPath: oldDefaultDirectory.path),
              !contents.isEmpty else {
            print("[PreferencesManager] Old directory is empty, no migration needed")
            return
        }

        print("[PreferencesManager] Found existing recordings in old location (\(contents.count) items)")
        print("[PreferencesManager] Setting output directory to old location to preserve access")

        // Set user preference to old location to preserve existing recordings
        // This is safer than moving files and respects user's existing data
        UserDefaults.standard.set(oldDefaultDirectory.path, forKey: Self.outputDirectoryKey)

        // Trigger callback so services update
        outputDirectoryDidChange?(oldDefaultDirectory)
    }
}

// MARK: - TranscriptionMode Conversion Extension

extension PreferencesManager.TranscriptionMode {
    /// Convert to TranscriptionService.TranscriptionMode
    var serviceMode: TranscriptionService.TranscriptionMode {
        switch self {
        case .live:
            return .live
        case .postProcessing:
            return .postProcessing
        }
    }
    
    /// Create from TranscriptionService.TranscriptionMode
    init(from serviceMode: TranscriptionService.TranscriptionMode) {
        switch serviceMode {
        case .live:
            self = .live
        case .postProcessing:
            self = .postProcessing
        }
    }
}
