import AppKit
import Foundation
import os.log
import WhisperKit

/// Manages WhisperKit model downloading and storage
@Observable
final class ModelManager: @unchecked Sendable, ModelManagerProtocol {
    private static let logger = Logger(subsystem: "com.muesli.app", category: "ModelManager")
    // MARK: - Model Options
    
    enum ModelSize: String, CaseIterable, Identifiable, Hashable {
        case tiny = "tiny"
        case base = "base"
        case small = "small"
        case medium = "medium"
        case large = "large-v3-v20240930"
        case largeTurbo = "large-v3-v20240930_turbo"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .tiny: return "Tiny"
            case .base: return "Base"
            case .small: return "Small (Recommended)"
            case .medium: return "Medium"
            case .large: return "Large v3"
            case .largeTurbo: return "Large v3 Turbo (Best Performance)"
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
        /// Note: WhisperKit automatically prepends "openai_whisper-" so we just use the suffix
        /// Model names from: https://huggingface.co/argmaxinc/whisperkit-coreml
        var whisperKitName: String {
            // All models now use rawValue directly since enum values match WhisperKit naming
            return rawValue
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
    
    /// Stored paths for downloaded models (persisted to UserDefaults)
    /// Key: model rawValue, Value: actual path returned by WhisperKit.download()
    var modelPaths: [ModelSize: URL] = [:]
    
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
        
        // Load stored model paths from UserDefaults
        loadModelPaths()
        
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
    
    /// Load stored model paths from UserDefaults
    private func loadModelPaths() {
        guard let pathsDict = UserDefaults.standard.dictionary(forKey: AppStorageKeys.whisperModelPaths) as? [String: String] else {
            return
        }
        
        for (rawValue, pathString) in pathsDict {
            if let model = ModelSize(rawValue: rawValue) {
                modelPaths[model] = URL(fileURLWithPath: pathString)
            }
        }
    }
    
    /// Save model paths to UserDefaults
    private func saveModelPaths() {
        var pathsDict: [String: String] = [:]
        for (model, url) in modelPaths {
            pathsDict[model.rawValue] = url.path
        }
        UserDefaults.standard.set(pathsDict, forKey: AppStorageKeys.whisperModelPaths)
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
    /// First checks stored paths, then falls back to filesystem scan
    func pathForModel(_ model: ModelSize) -> URL? {
        // First, check stored paths (most reliable - comes from actual download)
        if let storedPath = modelPaths[model] {
            if FileManager.default.fileExists(atPath: storedPath.path) {
                return storedPath
            } else {
                // Path was stored but no longer exists - clean up
                Self.logger.warning("Stored path for \(model.displayName) no longer exists: \(storedPath.path)")
                modelPaths.removeValue(forKey: model)
                saveModelPaths()
            }
        }
        
        // Fall back to scanning the filesystem for this model
        return scanForModelPath(model)
    }
    
    /// Scan filesystem to find a model's path
    /// Searches the whisperkit-coreml directory for folders that match the model
    private func scanForModelPath(_ model: ModelSize) -> URL? {
        let whisperKitDir = modelDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        
        guard FileManager.default.fileExists(atPath: whisperKitDir.path) else {
            return nil
        }
        
        // Get all directories in the whisperkit-coreml folder
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: whisperKitDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        
        // Look for a folder that matches this model
        // WhisperKit creates folders like "openai_whisper-base", "openai_whisper-large-v3-v20240930_turbo"
        for folderURL in contents {
            let folderName = folderURL.lastPathComponent
            
            // Check if this folder matches our model
            // Match by rawValue (e.g., "base" matches "openai_whisper-base")
            // or by the full expected pattern
            if folderName.contains(model.rawValue) || 
               folderName == "openai_whisper-\(model.whisperKitName)" {
                // Verify it's actually a valid model directory
                if FileManager.default.fileExists(atPath: folderURL.path) {
                    // Store this path for future use
                    modelPaths[model] = folderURL
                    saveModelPaths()
                    Self.logger.info("Found model \(model.displayName) at: \(folderURL.path)")
                    return folderURL
                }
            }
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
        
        // First, scan the whisperkit-coreml directory to discover all model folders
        let whisperKitDir = modelDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        
        if FileManager.default.fileExists(atPath: whisperKitDir.path),
           let contents = try? FileManager.default.contentsOfDirectory(
               at: whisperKitDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            // Match discovered folders to ModelSize cases
            for folderURL in contents {
                let folderName = folderURL.lastPathComponent
                
                // Skip non-model directories (like .cache)
                guard folderName.hasPrefix("openai_whisper-") else { continue }
                
                // Try to match this folder to a ModelSize
                for model in ModelSize.allCases {
                    // Match by checking if the folder contains the model's rawValue
                    if folderName.contains(model.rawValue) {
                        // Store the discovered path
                        modelPaths[model] = folderURL
                        Self.logger.debug("Discovered model folder: \(folderName) -> \(model.displayName)")
                        break
                    }
                }
            }
            
            // Persist discovered paths
            saveModelPaths()
        }
        
        // Now validate each known model (stored paths + any remaining cases)
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
        Self.logger.info("Starting download for model: \(model.displayName) (\(model.whisperKitName))")
        downloadStates[model] = .checking
        
        let targetDir = modelDirectory
        Self.logger.info("Target directory: \(targetDir.path)")
        
        do {
            downloadStates[model] = .downloading(progress: 0)
            
            Self.logger.info("Calling WhisperKit.download with variant=\(model.whisperKitName), downloadBase=\(targetDir.path)")
            
            // Use WhisperKit's built-in download functionality with progress tracking
            let folder = try await WhisperKit.download(
                variant: model.whisperKitName,
                downloadBase: targetDir,
                useBackgroundSession: false,
                progressCallback: { @Sendable progress in
                    // Update progress on main thread
                    Task { @MainActor [weak self] in
                        self?.downloadStates[model] = .downloading(progress: progress.fractionCompleted)
                        Self.logger.debug("Download progress for \(model.displayName): \(progress.fractionCompleted * 100, format: .fixed(precision: 1))%")
                    }
                }
            )
            
            Self.logger.info("Download completed successfully for \(model.displayName). Folder: \(folder)")
            
            // Store the actual path returned by WhisperKit (it's already a URL)
            modelPaths[model] = folder
            Self.logger.info("Stored model path: \(folder.path)")
            
            // Mark as downloaded
            downloadedModels.insert(model)
            downloadStates[model] = .completed
            
            // If no active model, set this as active
            if activeModel == nil {
                setActiveModel(model)
            }
            
            // Persist both downloaded models and paths
            saveDownloadedModels()
            saveModelPaths()
        } catch {
            Self.logger.error("Download failed for \(model.displayName): \(error.localizedDescription)")
            Self.logger.error("Error details: \(String(describing: error))")
            
            // Log NSError details if available
            if let nsError = error as NSError? {
                Self.logger.error("NSError domain: \(nsError.domain), code: \(nsError.code)")
                Self.logger.error("NSError userInfo: \(nsError.userInfo)")
            }
            
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
            modelPaths.removeValue(forKey: model)
            downloadStates[model] = .idle
            saveDownloadedModels()
            saveModelPaths()
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
        modelPaths.removeValue(forKey: model)
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
        saveModelPaths()
        
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
        modelPaths.removeAll()
        activeModel = nil
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeWhisperModel)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.downloadedWhisperModels)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.whisperModelPaths)
    }
}
