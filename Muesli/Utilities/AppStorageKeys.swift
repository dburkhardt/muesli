import Foundation

/// Centralized UserDefaults keys for the entire app
/// Using this enum ensures consistency and prevents typos in key names
enum AppStorageKeys {
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
    
    // MARK: - WhisperKit Models
    
    /// Active WhisperKit model identifier
    static let activeWhisperModel = "activeWhisperModel"
    
    /// Set of downloaded WhisperKit model identifiers (stored as JSON array)
    static let downloadedWhisperModels = "downloadedWhisperModels"
    
    // MARK: - LLM Models
    
    /// Active LLM model identifier
    static let activeLLMModel = "activeLLMModel"
    
    /// Set of downloaded LLM model identifiers (stored as JSON array)
    static let downloadedLLMModels = "downloadedLLMModels"
}
