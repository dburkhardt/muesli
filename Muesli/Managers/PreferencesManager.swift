import Foundation
import os.lock
import os.log
import ServiceManagement

/// Manages app preferences with UserDefaults persistence
/// Extracted from MuesliViewModel as part of the god object refactoring
@Observable
@MainActor
final class PreferencesManager {
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "PreferencesManager")
    
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
                    logger.error("Failed to set launch at login: \(error)")
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
    
    // MARK: - Transcription Quality Pipeline
    
    enum SecondPassModelPreference: String, CaseIterable {
        case bestAvailable
        case sameAsLive
        case bestAvailableNoDowngrade
        case specific
    }
    
    /// Toggle for deterministic live overlap deduplication.
    /// Default false for staged rollout safety.
    var isLiveStabilizerEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: AppStorageKeys.liveStabilizerEnabled) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: AppStorageKeys.liveStabilizerEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.liveStabilizerEnabled)
        }
    }
    
    /// Toggle for post-stop second-pass final transcription.
    /// Default false for staged rollout safety.
    var isSecondPassASREnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: AppStorageKeys.secondPassASREnabled) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: AppStorageKeys.secondPassASREnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.secondPassASREnabled)
        }
    }
    
    /// Toggle for optional automatic LLM cleanup after ASR finalization.
    var isAutoRefineEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: AppStorageKeys.autoRefineEnabled) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: AppStorageKeys.autoRefineEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.autoRefineEnabled)
        }
    }
    
    /// Strategy for picking the second-pass model.
    var secondPassModelPreference: SecondPassModelPreference {
        get {
            let raw = UserDefaults.standard.string(forKey: AppStorageKeys.secondPassModelPreference)
                ?? SecondPassModelPreference.bestAvailable.rawValue
            return SecondPassModelPreference(rawValue: raw) ?? .bestAvailable
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppStorageKeys.secondPassModelPreference)
        }
    }
    
    /// Explicit model raw value used when secondPassModelPreference == .specific.
    var secondPassSpecificModelRawValue: String? {
        get {
            UserDefaults.standard.string(forKey: AppStorageKeys.secondPassSpecificModel)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.secondPassSpecificModel)
        }
    }
    
    // MARK: - Echo Cancellation
    
    /// Thread-safe storage for echo cancellation state (for synchronous access from audio callbacks)
    /// Uses OSAllocatedUnfairLock for proper synchronization
    /// Internal access for audio callback setup
    let echoCancellationLock = OSAllocatedUnfairLock(initialState: true)
    
    /// Backing storage for @Observable tracking
    /// Note: The lock above is for thread-safe audio callback access; this property enables SwiftUI observation
    private var _isEchoCancellationEnabled: Bool = true
    
    /// Whether echo cancellation is enabled
    /// Uses a stored property for @Observable tracking, synced to lock for audio callbacks
    var isEchoCancellationEnabled: Bool {
        get { _isEchoCancellationEnabled }
        set {
            let oldValue = _isEchoCancellationEnabled
            _isEchoCancellationEnabled = newValue
            echoCancellationLock.withLock { $0 = newValue }
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.echoCancellationEnabled)
            if oldValue != newValue {
                logger.info("Echo cancellation toggled: \(oldValue) -> \(newValue)")
                Task {
                    await DiagnosticLogger.shared.log(.aec,
                        "AEC_TOGGLE: \(oldValue) -> \(newValue)")
                }
            }
        }
    }
    
    /// Thread-safe getter for audio callbacks (nonisolated)
    nonisolated var echoCancellationEnabledForAudioCallback: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: AppStorageKeys.aecDebugForceOff) {
            return false
        }
        #endif
        return echoCancellationLock.withLock { $0 }
    }
    
    // MARK: - AEC Delay Mode

    /// AEC delay mode determines how stream delay is computed for echo cancellation
    enum AECDelayMode: String, CaseIterable {
        case arrivalOnly
        case arrivalPlusStreamDelay
    }

    /// AEC delay mode (advanced setting)
    /// Default: .arrivalOnly — delay computed from render/capture arrival time difference only
    var aecDelayMode: String {
        get {
            UserDefaults.standard.string(forKey: AppStorageKeys.aecDelayMode) ?? AECDelayMode.arrivalOnly.rawValue
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.aecDelayMode)
        }
    }

    /// Get typed AEC delay mode
    var aecDelayModeType: AECDelayMode {
        AECDelayMode(rawValue: aecDelayMode) ?? .arrivalOnly
    }
    
    // MARK: - Audio Chunk Duration
    
    /// Audio chunk duration for transcription (2-30 seconds)
    var audioChunkDuration: TimeInterval {
        get {
            // Check if key exists to distinguish "not set" from "invalid value"
            guard let savedObject = UserDefaults.standard.object(forKey: AppStorageKeys.audioChunkDuration) as? Double
            else {
                // Key not set, return default
                return AudioConfiguration.transcriptionChunkDuration
            }
            
            // Key exists, validate range
            if savedObject < 2.0 || savedObject > 30.0 {
                // Invalid value, return default
                return AudioConfiguration.transcriptionChunkDuration
            }
            return savedObject
        }
        set {
            // Clamp to valid range
            let clamped = min(max(newValue, 2.0), 30.0)
            UserDefaults.standard.set(clamped, forKey: AppStorageKeys.audioChunkDuration)
            audioChunkDurationDidChange?(clamped)
        }
    }
    
    /// Callback when audio chunk duration changes
    var audioChunkDurationDidChange: ((TimeInterval) -> Void)?
    
    // MARK: - Export Settings
    
    /// Whether automatic export is enabled
    var exportEnabled: Bool {
        get {
            // Default to true if not explicitly set
            if UserDefaults.standard.object(forKey: AppStorageKeys.exportEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: AppStorageKeys.exportEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.exportEnabled)
        }
    }
    
    /// Export directory for external tool access
    var exportDirectory: URL {
        get {
            if let savedPath = UserDefaults.standard.string(forKey: AppStorageKeys.exportDirectory) {
                return URL(fileURLWithPath: savedPath)
            }
            return Self.defaultExportDirectory
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: AppStorageKeys.exportDirectory)
        }
    }
    
    /// Default export directory: ~/Library/Application Support/Muesli/Exports
    static var defaultExportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Muesli/Exports")
    }
    
    /// Reset export directory to default
    func resetExportDirectory() {
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.exportDirectory)
    }
    
    // MARK: - AEC Startup Policy

    /// Tri-state for a stored UserDefaults boolean: distinguishes "never set" from explicit false.
    enum StoredBool: Equatable, CustomStringConvertible {
        case unset
        case value(Bool)

        var description: String {
            switch self {
            case .unset: return "unset"
            case .value(let boolVal): return "\(boolVal)"
            }
        }

        init(forKey key: String, defaults: UserDefaults = .standard) {
            if defaults.object(forKey: key) != nil {
                self = .value(defaults.bool(forKey: key))
            } else {
                self = .unset
            }
        }
    }

    /// Decision object returned by the AEC startup policy function.
    struct AECStartupDecision: Equatable {
        let effectiveValue: Bool
        let shouldWriteEnabled: Bool
        let shouldSetMigrationDone: Bool
    }

    /// Pure function: given the stored preference, build mode, and migration state,
    /// returns what init() should do. Testable without UserDefaults side-effects.
    static func resolveAECStartupPolicy(
        storedPref: StoredBool,
        isRelease: Bool,
        migrationAlreadyDone: Bool
    ) -> AECStartupDecision {
        let savedValue: Bool
        switch storedPref {
        case .unset: savedValue = true
        case .value(let boolVal): savedValue = boolVal
        }

        if isRelease {
            let needsWrite = !savedValue
            let needsMigrationMark = needsWrite && !migrationAlreadyDone
            return AECStartupDecision(
                effectiveValue: true,
                shouldWriteEnabled: needsWrite,
                shouldSetMigrationDone: needsMigrationMark
            )
        } else {
            return AECStartupDecision(
                effectiveValue: savedValue,
                shouldWriteEnabled: false,
                shouldSetMigrationDone: false
            )
        }
    }

    /// Convenience wrapper for backward compatibility.
    static func effectiveAECEnabled(storedValue: Bool, isRelease: Bool) -> Bool {
        resolveAECStartupPolicy(
            storedPref: .value(storedValue),
            isRelease: isRelease,
            migrationAlreadyDone: false
        ).effectiveValue
    }

    // MARK: - Initialization

    init() {
        let storedPref = StoredBool(forKey: AppStorageKeys.echoCancellationEnabled)
        let migrationDone = UserDefaults.standard.object(forKey: AppStorageKeys.aecAlwaysOnMigrationDone) != nil
            && UserDefaults.standard.bool(forKey: AppStorageKeys.aecAlwaysOnMigrationDone)

        #if DEBUG
        let isRelease = false
        #else
        let isRelease = true
        #endif

        let decision = Self.resolveAECStartupPolicy(
            storedPref: storedPref,
            isRelease: isRelease,
            migrationAlreadyDone: migrationDone
        )

        if decision.shouldWriteEnabled {
            UserDefaults.standard.set(true, forKey: AppStorageKeys.echoCancellationEnabled)
        }
        if decision.shouldSetMigrationDone {
            UserDefaults.standard.set(true, forKey: AppStorageKeys.aecAlwaysOnMigrationDone)
            Task {
                await DiagnosticLogger.shared.log(.aec, "AEC_PREF_MIGRATED_FALSE_TO_TRUE")
            }
        }

        _isEchoCancellationEnabled = decision.effectiveValue
        echoCancellationLock.withLock { $0 = decision.effectiveValue }

        // Perform storage migration if needed
        migrateStorageLocationIfNeeded()
    }

    deinit {
        logger.debug("Deallocating")
    }

    // MARK: - Storage Migration

    /// Key to track if migration has been checked this app installation
    private static let migrationCheckedKey = "com.muesli.migrationChecked"
    
    /// Migrate from old default location (~/Documents/Meeting Transcripts) to new location
    /// (~/Library/Application Support/Muesli/Recordings) while preserving existing recordings
    private func migrateStorageLocationIfNeeded() {
        // Skip if migration was already checked (prevents Documents prompt on SwiftUI App recreation)
        guard !UserDefaults.standard.bool(forKey: Self.migrationCheckedKey) else {
            logger.info("Migration already checked, skipping")
            return
        }
        
        // Mark migration as checked BEFORE accessing Documents to avoid repeated prompts
        UserDefaults.standard.set(true, forKey: Self.migrationCheckedKey)
        
        // Only migrate if user hasn't set a custom output directory
        guard UserDefaults.standard.string(forKey: AppStorageKeys.outputDirectory) == nil else {
            logger.info("Custom output directory set, skipping migration")
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
            logger.info("Old directory doesn't exist, no migration needed")
            return
        }

        // Check if old directory has any meeting folders
        guard let contents = try? fileManager.contentsOfDirectory(atPath: oldDefaultDirectory.path),
              !contents.isEmpty else {
            logger.info("Old directory is empty, no migration needed")
            return
        }

        logger.info("Found existing recordings in old location (\(contents.count) items)")
        logger.info("Setting output directory to old location to preserve access")

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
