import Foundation

/// Centralized UserDefaults keys for the entire app
/// Using this enum ensures consistency and prevents typos in key names
enum AppStorageKeys {
    // MARK: - Onboarding Mode
    
    /// Mode for onboarding window - first-time setup vs permission recovery
    enum OnboardingMode: Equatable {
        case firstTime
        case permissionRecovery(missingScreen: Bool, missingMic: Bool)
        
        var isRecoveryMode: Bool {
            if case .permissionRecovery = self { return true }
            return false
        }
        
        var skipWelcome: Bool {
            isRecoveryMode
        }
        
        var skipModelSetup: Bool {
            isRecoveryMode
        }
        
        var windowTitle: String {
            switch self {
            case .firstTime: return "Welcome to Muesli"
            case .permissionRecovery: return "Permissions Required"
            }
        }
    }
    
    // MARK: - Onboarding
    
    /// Whether onboarding has been completed
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    
    /// Current step in onboarding (for resuming)
    static let onboardingCurrentStep = "onboardingCurrentStep"
    
    // MARK: - Preferences
    
    /// Custom output directory for recordings (if not using default)
    static let outputDirectory = "outputDirectory"
    
    /// Whether to launch at login
    static let launchAtLogin = "launchAtLogin"
    
    /// Transcription mode: "live" or "postProcessing"
    static let transcriptionMode = "transcriptionMode"
    
    /// Whether echo cancellation is enabled
    static let echoCancellationEnabled = "echoCancellationEnabled"
    
    /// One-time migration marker: AEC forced to always-on in Release
    static let aecAlwaysOnMigrationDone = "aecAlwaysOnMigrationDone"
    
    #if DEBUG
    /// Debug-only: force AEC off for testing (ignored in Release builds)
    static let aecDebugForceOff = "aecDebugForceOff"
    #endif
    
    /// AEC delay mode: how stream delay is computed for echo cancellation
    static let aecDelayMode = "aecDelayMode"
    
    /// Audio chunk duration for transcription (2-30 seconds)
    static let audioChunkDuration = "audioChunkDuration"
    
    // MARK: - Export
    
    /// Whether automatic export is enabled
    static let exportEnabled = "exportEnabled"
    
    /// Custom export directory (if not using default)
    static let exportDirectory = "exportDirectory"
    
    // MARK: - WhisperKit Models
    
    /// Active WhisperKit model identifier
    static let activeWhisperModel = "activeWhisperModel"
    
    /// Set of downloaded WhisperKit model identifiers (stored as JSON array)
    static let downloadedWhisperModels = "downloadedWhisperModels"
    
    /// Dictionary of model paths (stored as [String: String] - model rawValue to path)
    static let whisperModelPaths = "whisperModelPaths"

    /// Dictionary of compile stamps (stored as [String: String] - model rawValue to stamp string)
    /// Stamp format: "\(modelRawValue)|\(folderPath)|\(folderModTime)|\(appVersion)"
    /// Used to skip redundant CoreML compilation probes on subsequent launches.
    static let whisperModelCompileStamps = "whisperModelCompileStamps"
    
    // MARK: - LLM Models
    
    /// Active LLM model identifier
    static let activeLLMModel = "activeLLMModel"
    
    /// Set of downloaded LLM model identifiers (stored as JSON array)
    static let downloadedLLMModels = "downloadedLLMModels"
    
    // MARK: - Update Checking
    
    /// Timestamp of last update check (ISO8601 date string)
    static let lastUpdateCheckDate = "lastUpdateCheckDate"
    
    /// Array of version strings the user chose to skip (stored as JSON array)
    static let skippedVersions = "skippedVersions"
}
