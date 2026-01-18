import AppKit
import Foundation
import WhisperKit

/// Manages WhisperKit model downloading and storage
@Observable
final class ModelManager: @unchecked Sendable, ModelManagerProtocol {
    // MARK: - Model Options
    
    enum ModelSize: String, CaseIterable, Identifiable, Hashable {
        case tiny = "tiny"
        case base = "base"
        case small = "small"
        case medium = "medium"
        case large = "large-v3"
        case largeTurbo = "large-v3-turbo"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .tiny: return "Tiny"
            case .base: return "Base"
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large v3"
            case .largeTurbo: return "Large v3 Turbo"
            }
        }
        
        var sizeDescription: String {
            switch self {
            case .tiny: return "~75MB"
            case .base: return "~145MB"
            case .small: return "~465MB"
            case .medium: return "~1.5GB"
            case .large: return "~3GB"
            case .largeTurbo: return "~1.6GB"
            }
        }
        
        /// WhisperKit model name format
        var whisperKitName: String {
            switch self {
            case .large:
                return "openai_whisper-large-v3"
            case .largeTurbo:
                return "openai_whisper-large-v3-turbo"
            default:
                return "openai_whisper-\(rawValue)"
            }
        }
        
        /// Source repository for model downloads
        var sourceRepo: String {
            "argmaxinc/whisperkit-coreml"
        }
        
        /// URL to the source repository
        var sourceURL: URL {
            URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml")!
        }
    }
    
    // MARK: - Download State (per model)
    
    enum DownloadState: Equatable {
        case idle
        case checking
        case downloading(progress: Double)
        case completed
        case failed(String)
    }
    
    // MARK: - State
    
    /// Download state for each model
    var downloadStates: [ModelSize: DownloadState] = [:]
    
    /// Set of downloaded models
    var downloadedModels: Set<ModelSize> = []
    
    /// Downloaded models sorted in canonical order (matching allCases)
    var downloadedModelsOrdered: [ModelSize] {
        ModelSize.allCases.filter { downloadedModels.contains($0) }
    }
    
    /// Currently active model for transcription
    var activeModel: ModelSize?
    
    /// Legacy single model path (for backwards compatibility)
    var modelPath: URL? {
        guard let active = activeModel else { return nil }
        return pathForModel(active)
    }
    
    /// Check if at least one model is downloaded and active
    var hasModel: Bool {
        activeModel != nil && downloadedModels.contains(activeModel!)
    }
    
    // MARK: - Storage Keys (use centralized AppStorageKeys)
    
    // MARK: - Initialization
    
    /// Whether to skip file system scanning (for testing)
    private let skipScan: Bool
    
    init(skipScan: Bool = false) {
        self.skipScan = skipScan
        
        // Initialize all models as idle
        for model in ModelSize.allCases {
            downloadStates[model] = .idle
        }
        
        // Scan for existing downloaded models (skip during tests)
        if !skipScan {
            scanForDownloadedModels()
            
            // Load saved active model preference with validation
            if let savedModel = UserDefaults.standard.string(forKey: AppStorageKeys.activeWhisperModel),
               let model = ModelSize(rawValue: savedModel),
               validateModel(model) {
                // Saved model is valid - use it
                activeModel = model
                // Ensure it's in downloadedModels (should be after scan, but be safe)
                downloadedModels.insert(model)
            } else if let firstValid = getFirstValidModel() {
                // Saved model was invalid or missing - fall back to first valid model
                activeModel = firstValid
                UserDefaults.standard.set(firstValid.rawValue, forKey: AppStorageKeys.activeWhisperModel)
            }
            // If no valid models found, activeModel remains nil
        }
    }
    
    // MARK: - Model Directory
    
    /// Returns the Application Support directory for storing models
    var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let muesliDir = appSupport.appendingPathComponent("Muesli/Models", isDirectory: true)
        
        // Create directory if it doesn't exist (skip during tests)
        if !skipScan {
            try? FileManager.default.createDirectory(at: muesliDir, withIntermediateDirectories: true)
        }
        
        return muesliDir
    }
    
    /// Get the path for a specific model
    func pathForModel(_ model: ModelSize) -> URL? {
        // WhisperKit downloads to: modelDirectory/models/argmaxinc/whisperkit-coreml/openai_whisper-{size}/
        let modelDir = modelDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitName)
        
        if FileManager.default.fileExists(atPath: modelDir.path) {
            return modelDir
        }
        return nil
    }
    
    // MARK: - Model Status
    
    /// Check if a specific model is downloaded
    func isModelDownloaded(_ model: ModelSize) -> Bool {
        downloadedModels.contains(model)
    }
    
    /// Validate that a model has all required files (not just config.json)
    /// Returns true if the model is complete and usable
    func validateModel(_ model: ModelSize) -> Bool {
        guard let modelPath = pathForModel(model) else {
            return false
        }
        
        let fm = FileManager.default
        
        // Check for required CoreML model files
        let audioEncoderPath = modelPath.appendingPathComponent("AudioEncoder.mlmodelc")
        let textDecoderPath = modelPath.appendingPathComponent("TextDecoder.mlmodelc")
        
        // AudioEncoder must exist with weights
        let audioEncoderExists = fm.fileExists(atPath: audioEncoderPath.path)
        let audioWeightsPath = audioEncoderPath.appendingPathComponent("weights/weight.bin")
        let audioWeightsExists = fm.fileExists(atPath: audioWeightsPath.path)
        
        // TextDecoder must exist with weights
        let textDecoderExists = fm.fileExists(atPath: textDecoderPath.path)
        let textWeightsPath = textDecoderPath.appendingPathComponent("weights/weight.bin")
        let textWeightsExists = fm.fileExists(atPath: textWeightsPath.path)
        
        guard audioEncoderExists else { return false }
        guard audioWeightsExists else { return false }
        guard textDecoderExists else { return false }
        guard textWeightsExists else { return false }
        
        return true
    }
    
    /// Get the first valid (complete) model from downloaded models
    /// Prefers the currently active model, then falls back to others
    func getFirstValidModel() -> ModelSize? {
        // Try active model first
        if let active = activeModel, validateModel(active) {
            return active
        }
        
        // Try other downloaded models (prefer larger models)
        for model in ModelSize.allCases.reversed() {
            if downloadedModels.contains(model) && validateModel(model) {
                return model
            }
        }
        
        return nil
    }
    
    /// Mark a model as corrupted and remove from downloaded set
    func markModelCorrupted(_ model: ModelSize) {
        downloadedModels.remove(model)
        downloadStates[model] = .failed("Model is corrupted or incomplete")
        
        // If this was active, try to switch
        if activeModel == model {
            if let valid = getFirstValidModel() {
                setActiveModel(valid)
            } else {
                activeModel = nil
                UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeWhisperModel)
            }
        }
        
        saveDownloadedModels()
    }
    
    /// Get download state for a specific model
    func downloadState(for model: ModelSize) -> DownloadState {
        downloadStates[model] ?? .idle
    }
    
    /// Scan the models directory to detect previously downloaded models
    /// Uses full validation to ensure only complete, usable models are marked as downloaded
    func scanForDownloadedModels() {
        downloadedModels.removeAll()
        
        for model in ModelSize.allCases {
            // Use validateModel() to ensure the model is actually complete and usable
            // This checks for AudioEncoder.mlmodelc and TextDecoder.mlmodelc with weights
            if validateModel(model) {
                downloadedModels.insert(model)
                downloadStates[model] = .completed
            } else if pathForModel(model) != nil {
                // Model directory exists but is incomplete/corrupted
                downloadStates[model] = .failed("Model is incomplete or corrupted")
            }
        }
    }
    
    // MARK: - Download
    
    /// Download a specific model
    @MainActor
    func downloadModel(_ model: ModelSize) async {
        downloadStates[model] = .checking
        
        let targetDir = modelDirectory
        
        do {
            downloadStates[model] = .downloading(progress: 0)
            
            // Use WhisperKit's built-in download functionality with progress tracking
            let folder = try await WhisperKit.download(
                variant: model.whisperKitName,
                downloadBase: targetDir,
                useBackgroundSession: false,
                progressCallback: { @Sendable progress in
                    // Update progress on main thread
                    Task { @MainActor [weak self] in
                        self?.downloadStates[model] = .downloading(progress: progress.fractionCompleted)
                    }
                }
            )
            
            // Mark as downloaded
            downloadedModels.insert(model)
            downloadStates[model] = .completed
            
            // If no active model, set this as active
            if activeModel == nil {
                setActiveModel(model)
            }
            
            // Persist
            saveDownloadedModels()
        } catch {
            downloadStates[model] = .failed(error.localizedDescription)
        }
    }
    
    /// Set the active model for transcription
    func setActiveModel(_ model: ModelSize) {
        guard downloadedModels.contains(model) else { return }
        activeModel = model
        UserDefaults.standard.set(model.rawValue, forKey: AppStorageKeys.activeWhisperModel)
    }
    
    // MARK: - Persistence
    
    private func saveDownloadedModels() {
        let modelStrings = downloadedModels.map { $0.rawValue }
        UserDefaults.standard.set(modelStrings, forKey: AppStorageKeys.downloadedWhisperModels)
    }
    
    /// Use an existing model from a user-selected folder
    func useExistingModel(at url: URL) -> Bool {
        // Validate that it looks like a WhisperKit model folder
        let configPath = url.appendingPathComponent("config.json")
        
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return false
        }
        
        // Try to determine which model size this is based on the folder name
        for model in ModelSize.allCases {
            if url.lastPathComponent.contains(model.whisperKitName) || 
               url.lastPathComponent.contains(model.rawValue) {
                downloadedModels.insert(model)
                downloadStates[model] = .completed
                setActiveModel(model)
                saveDownloadedModels()
                return true
            }
        }
        
        // If we can't determine the model size, still accept it as "base" 
        downloadedModels.insert(.base)
        downloadStates[.base] = .completed
        setActiveModel(.base)
        saveDownloadedModels()
        return true
    }
    
    // MARK: - Delete Model
    
    /// Delete a model from disk and update state
    /// - Parameter model: The model to delete
    /// - Returns: True if deletion was successful, false otherwise
    @MainActor
    func deleteModel(_ model: ModelSize) -> Bool {
        guard downloadedModels.contains(model) else { return false }
        
        // Get the model directory path
        guard let modelPath = pathForModel(model) else {
            // Model path doesn't exist, but it's in our set - clean up state
            downloadedModels.remove(model)
            downloadStates[model] = .idle
            saveDownloadedModels()
            return true
        }
        
        // Delete the directory
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: modelPath)
        } catch {
            return false
        }
        
        // Update state
        downloadedModels.remove(model)
        downloadStates[model] = .idle
        
        // If this was the active model, switch to another one
        if activeModel == model {
            // Prefer keeping the largest model available
            let sortedModels = ModelSize.allCases.reversed()
            if let replacement = sortedModels.first(where: { downloadedModels.contains($0) }) {
                setActiveModel(replacement)
            } else {
                // No other models available
                activeModel = nil
                UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeWhisperModel)
            }
        }
        
        // Persist changes
        saveDownloadedModels()
        
        return true
    }
    
    // MARK: - Show in Finder
    
    /// Open the models directory in Finder
    func showModelsInFinder() {
        NSWorkspace.shared.open(modelDirectory)
    }
    
    // MARK: - Reset
    
    func reset() {
        for model in ModelSize.allCases {
            downloadStates[model] = .idle
        }
        downloadedModels.removeAll()
        activeModel = nil
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeWhisperModel)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.downloadedWhisperModels)
    }
}
