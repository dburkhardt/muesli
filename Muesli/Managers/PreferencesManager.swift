import Foundation
import ServiceManagement
import os.lock

/// Manages app preferences with UserDefaults persistence
/// Extracted from MuesliViewModel as part of the god object refactoring
@Observable
@MainActor
final class PreferencesManager {
    
    // MARK: - Output Directory
    
    /// Output directory for recordings
    var outputDirectory: URL {
        get {
            if let savedPath = UserDefaults.standard.string(forKey: AppStorageKeys.outputDirectory) {
                return URL(fileURLWithPath: savedPath)
            }
            return Self.defaultOutputDirectory
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: AppStorageKeys.outputDirectory)
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
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.outputDirectory)
        outputDirectoryDidChange?(Self.defaultOutputDirectory)
    }
    
    // MARK: - Launch at Login
    
    /// Whether to launch at login
    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return UserDefaults.standard.bool(forKey: AppStorageKeys.launchAtLogin)
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
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.launchAtLogin)
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
            let rawValue = UserDefaults.standard.string(forKey: AppStorageKeys.transcriptionMode) ?? "live"
            return TranscriptionMode(rawValue: rawValue) ?? .live
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppStorageKeys.transcriptionMode)
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
    
    /// Thread-safe storage for echo cancellation state (for synchronous access from audio callbacks)
    /// Uses OSAllocatedUnfairLock for proper synchronization
    /// Internal access for audio callback setup
    let echoCancellationLock = OSAllocatedUnfairLock(initialState: false)
    
    /// Whether echo cancellation is enabled
    /// Uses a cached value for thread-safe access from audio callbacks
    var isEchoCancellationEnabled: Bool {
        get {
            echoCancellationLock.withLock { $0 }
        }
        set {
            echoCancellationLock.withLock { $0 = newValue }
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.echoCancellationEnabled)
        }
    }
    
    /// Thread-safe getter for audio callbacks (nonisolated)
    nonisolated var echoCancellationEnabledForAudioCallback: Bool {
        echoCancellationLock.withLock { $0 }
    }
    
    // MARK: - Audio Chunk Duration
    
    /// Audio chunk duration for transcription (2-10 seconds)
    var audioChunkDuration: TimeInterval {
        get {
            // Check if key exists to distinguish "not set" from "invalid value"
            guard let savedObject = UserDefaults.standard.object(forKey: AppStorageKeys.audioChunkDuration) as? Double else {
                // Key not set, return default
                return 5.0
            }
            
            // Key exists, validate range
            if savedObject < 2.0 || savedObject > 10.0 {
                // Invalid value, return default
                return 5.0
            }
            return savedObject
        }
        set {
            // Clamp to valid range
            let clamped = min(max(newValue, 2.0), 10.0)
            UserDefaults.standard.set(clamped, forKey: AppStorageKeys.audioChunkDuration)
            audioChunkDurationDidChange?(clamped)
        }
    }
    
    /// Callback when audio chunk duration changes
    var audioChunkDurationDidChange: ((TimeInterval) -> Void)?
    
    // MARK: - Initialization

    init() {
        // Load persisted echo cancellation state into the lock
        let savedValue = UserDefaults.standard.bool(forKey: AppStorageKeys.echoCancellationEnabled)
        echoCancellationLock.withLock { $0 = savedValue }

        // Perform storage migration if needed
        migrateStorageLocationIfNeeded()
    }

    deinit {
        print("[PreferencesManager] Deallocating")
    }

    // MARK: - Storage Migration

    /// Key to track if migration has been checked this app installation
    private static let migrationCheckedKey = "com.muesli.migrationChecked"
    
    /// Migrate from old default location (~/Documents/Meeting Transcripts) to new location
    /// (~/Library/Application Support/Muesli/Recordings) while preserving existing recordings
    private func migrateStorageLocationIfNeeded() {
        // Skip if migration was already checked (prevents Documents prompt on SwiftUI App recreation)
        guard !UserDefaults.standard.bool(forKey: Self.migrationCheckedKey) else {
            print("[PreferencesManager] Migration already checked, skipping")
            return
        }
        
        // Mark migration as checked BEFORE accessing Documents to avoid repeated prompts
        UserDefaults.standard.set(true, forKey: Self.migrationCheckedKey)
        
        // Only migrate if user hasn't set a custom output directory
        guard UserDefaults.standard.string(forKey: AppStorageKeys.outputDirectory) == nil else {
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
        UserDefaults.standard.set(oldDefaultDirectory.path, forKey: AppStorageKeys.outputDirectory)

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
