import AppKit
import Foundation
import Hub
import MLXLLM
import MLXLMCommon

/// Manages local LLM model downloading and inference for transcript stitching
/// Models are stored in Hugging Face cache directory
///
/// Uses MLX-Swift for on-device LLM inference
@Observable
@MainActor
final class LLMManager: LLMManagerProtocol {
    // MARK: - Model Options
    
    enum LLMModel: String, CaseIterable, Identifiable, Hashable {
        case llama323B = "Llama-3.2-3B-Instruct-4bit"
        case phi3Mini = "Phi-3-mini-4k-instruct-4bit"
        case gemma22b = "gemma-2-2b-it-4bit"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .llama323B: return "Llama 3.2 3B (Recommended)"
            case .phi3Mini: return "Phi-3 Mini"
            case .gemma22b: return "Gemma 2 2B"
            }
        }
        
        var sizeDescription: String {
            switch self {
            case .llama323B: return "~2GB"
            case .phi3Mini: return "~2.3GB"
            case .gemma22b: return "~1.5GB"
            }
        }
        
        var description: String {
            switch self {
            case .llama323B: return "Best balance of quality and speed"
            case .phi3Mini: return "Good for longer context"
            case .gemma22b: return "Smaller, faster"
            }
        }
        
        /// Hugging Face model identifier
        var huggingFaceRepo: String {
            switch self {
            case .llama323B: return "mlx-community/Llama-3.2-3B-Instruct-4bit"
            case .phi3Mini: return "mlx-community/Phi-3-mini-4k-instruct-4bit"
            case .gemma22b: return "mlx-community/gemma-2-2b-it-4bit"
            }
        }
        
        /// Source repository display name
        var sourceRepo: String {
            "mlx-community"
        }
        
        /// URL to the source repository
        var sourceURL: URL {
            URL(string: "https://huggingface.co/\(huggingFaceRepo)")!
        }
        
        /// ModelConfiguration for MLXLMCommon
        var modelConfiguration: ModelConfiguration {
            ModelConfiguration(id: huggingFaceRepo)
        }
    }
    
    // MARK: - Download State
    
    enum DownloadState: Equatable {
        case idle
        case checking
        case downloading(progress: Double)
        case loading
        case completed
        case failed(String)
    }
    
    // MARK: - State
    
    /// Download state for each model
    var downloadStates: [LLMModel: DownloadState] = [:]
    
    /// Set of downloaded models (internal storage)
    private var _downloadedModels: Set<LLMModel> = []
    
    /// Set of downloaded models (triggers lazy scan on first access)
    var downloadedModels: Set<LLMModel> {
        get {
            ensureScanned()
            return _downloadedModels
        }
        set {
            _downloadedModels = newValue
        }
    }
    
    /// Currently active model for stitching
    var activeModel: LLMModel?
    
    /// Whether at least one model is downloaded
    var hasModel: Bool {
        ensureScanned()
        return !_downloadedModels.isEmpty
    }
    
    /// Loaded model container for inference
    private(set) var modelContainer: ModelContainer?
    
    /// Whether LLM stitching is available (model downloaded and loaded)
    var isLLMAvailable: Bool {
        modelContainer != nil && activeModel != nil
    }
    
    /// MLX-Swift is always available now that we've added the dependency
    let isMLXAvailable: Bool = true
    
    // MARK: - Storage Keys (use centralized AppStorageKeys)
    
    private static let llmEnabledKey = "llmStitchingEnabled"
    
    /// User preference: enable LLM stitching
    /// Automatically enabled when a model is downloaded
    var isLLMStitchingEnabled: Bool {
        get { 
            // Always enabled if a model is downloaded
            if hasModel {
                return true
            }
            // Otherwise use stored preference (for when models are deleted)
            return UserDefaults.standard.bool(forKey: Self.llmEnabledKey)
        }
        set { 
            UserDefaults.standard.set(newValue, forKey: Self.llmEnabledKey)
        }
    }
    
    /// Hub API for downloading models (configured to use Application Support)
    private var _hubApi: HubApi?
    private var hubApi: HubApi {
        if _hubApi == nil {
            // Use Application Support instead of default Documents folder
            // This avoids triggering macOS Documents permission prompts
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let hubCacheDir = appSupport.appendingPathComponent("Muesli/HubCache", isDirectory: true)
            
            // Create directory if it doesn't exist
            try? FileManager.default.createDirectory(at: hubCacheDir, withIntermediateDirectories: true)
            
            _hubApi = HubApi(downloadBase: hubCacheDir)
        }
        return _hubApi!
    }
    
    /// Whether to skip Hub API access (for testing)
    private let skipHubAccess: Bool
    
    // MARK: - Initialization
    
    init(skipHubAccess: Bool = false) {
        self.skipHubAccess = skipHubAccess
        
        // Initialize all models as idle
        for model in LLMModel.allCases {
            downloadStates[model] = .idle
        }
        
        // DEFERRED: Don't scan during init to avoid triggering Documents prompt
        // scanForDownloadedModels() will be called lazily when needed
        // The hasScanned flag ensures we only scan once
        if !skipHubAccess {
            // Just load the saved active model preference (doesn't access Hub)
            if let savedModel = UserDefaults.standard.string(forKey: AppStorageKeys.activeLLMModel),
               let model = LLMModel(rawValue: savedModel) {
                activeModel = model
            }
        }
    }
    
    /// Whether models have been scanned yet
    private var hasScanned = false
    
    /// Ensure models are scanned (called lazily)
    private func ensureScanned() {
        guard !hasScanned && !skipHubAccess else { return }
        hasScanned = true
        scanForDownloadedModels()
    }
    
    // MARK: - Model Directory
    
    /// Returns the Hub cache directory for models
    var modelDirectory: URL {
        guard !skipHubAccess else {
            // Return a dummy path for tests (won't be accessed)
            return FileManager.default.temporaryDirectory.appendingPathComponent("test-llm-models")
        }
        // Use a dummy config to get the base cache location
        let dummyConfig = ModelConfiguration(id: "mlx-community/test")
        return dummyConfig.modelDirectory(hub: hubApi).deletingLastPathComponent().deletingLastPathComponent()
    }
    
    /// Get the path for a specific model (from Hub cache)
    func pathForModel(_ model: LLMModel) -> URL? {
        guard !skipHubAccess else { return nil }
        
        let modelDir = model.modelConfiguration.modelDirectory(hub: hubApi)
        
        // Check for model files (config.json indicates a valid model)
        let configPath = modelDir.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: configPath.path) {
            return modelDir
        }
        return nil
    }
    
    // MARK: - Model Status
    
    func isModelDownloaded(_ model: LLMModel) -> Bool {
        downloadedModels.contains(model)
    }
    
    func downloadState(for model: LLMModel) -> DownloadState {
        ensureScanned()
        return downloadStates[model] ?? .idle
    }
    
    /// Scan the models directory to detect previously downloaded models
    func scanForDownloadedModels() {
        _downloadedModels.removeAll()
        
        for model in LLMModel.allCases where pathForModel(model) != nil {
                _downloadedModels.insert(model)
                downloadStates[model] = .completed
        }
        
        // Automatically enable LLM stitching if models are found
        if !_downloadedModels.isEmpty {
            isLLMStitchingEnabled = true
        }
    }
    
    // MARK: - Download
    
    /// Download a specific model from Hugging Face
    func downloadModel(_ model: LLMModel) async {
        downloadStates[model] = .checking
        
        do {
            downloadStates[model] = .downloading(progress: 0)
            
            // Download from Hugging Face using MLXLMCommon
            _ = try await MLXLMCommon.downloadModel(
                hub: hubApi,
                configuration: model.modelConfiguration
            ) { progress in
                Task { @MainActor in
                    let fraction = progress.fractionCompleted
                    self.downloadStates[model] = .downloading(progress: fraction)
                }
            }
            
            downloadedModels.insert(model)
            downloadStates[model] = .completed
            
            // Automatically enable LLM stitching when a model is downloaded
            isLLMStitchingEnabled = true
            
            if activeModel == nil {
                setActiveModel(model)
            }
            
            saveDownloadedModels()
        } catch {
            downloadStates[model] = .failed(error.localizedDescription)
        }
    }
    
    /// Load a model into memory for inference
    func loadModel(_ model: LLMModel) async throws {
        guard downloadedModels.contains(model) else {
            throw LLMError.modelNotDownloaded
        }
        
        downloadStates[model] = .loading
        
        do {
            // Load the model using LLMModelFactory
            let container = try await LLMModelFactory.shared.loadContainer(
                hub: hubApi,
                configuration: model.modelConfiguration
            ) { progress in
                Task { @MainActor in
                    // Progress callback during loading (weights loading)
                    let fraction = progress.fractionCompleted
                    if fraction < 1.0 {
                        self.downloadStates[model] = .loading
                    }
                }
            }
            
            modelContainer = container
            activeModel = model
            downloadStates[model] = .completed
            UserDefaults.standard.set(model.rawValue, forKey: AppStorageKeys.activeLLMModel)
        } catch {
            downloadStates[model] = .failed("Failed to load model: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Unload the current model from memory
    func unloadModel() {
        modelContainer = nil
    }
    
    /// Set the active model for stitching
    func setActiveModel(_ model: LLMModel) {
        guard downloadedModels.contains(model) else { return }
        activeModel = model
        UserDefaults.standard.set(model.rawValue, forKey: AppStorageKeys.activeLLMModel)
    }
    
    // MARK: - Persistence
    
    private func saveDownloadedModels() {
        let modelStrings = downloadedModels.map { $0.rawValue }
        UserDefaults.standard.set(modelStrings, forKey: AppStorageKeys.downloadedLLMModels)
    }
    
    // MARK: - Delete Model
    
    func deleteModel(_ model: LLMModel) -> Bool {
        guard downloadedModels.contains(model) else { return false }
        
        // Unload if this is the active model
        if activeModel == model {
            unloadModel()
        }
        
        guard let modelPath = pathForModel(model) else {
            downloadedModels.remove(model)
            downloadStates[model] = .idle
            saveDownloadedModels()
            return true
        }
        
        do {
            try FileManager.default.removeItem(at: modelPath)
        } catch {
            return false
        }
        
        downloadedModels.remove(model)
        downloadStates[model] = .idle
        
        if activeModel == model {
            if let replacement = LLMModel.allCases.first(where: { downloadedModels.contains($0) }) {
                setActiveModel(replacement)
            } else {
                activeModel = nil
                UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeLLMModel)
            }
        }
        
        saveDownloadedModels()
        return true
    }
    
    // MARK: - Show in Finder
    
    func showModelsInFinder() {
        NSWorkspace.shared.open(modelDirectory)
    }
    
    // MARK: - Reset
    
    func reset() {
        unloadModel()
        for model in LLMModel.allCases {
            downloadStates[model] = .idle
        }
        downloadedModels.removeAll()
        activeModel = nil
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeLLMModel)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.downloadedLLMModels)
        
        // Disable LLM stitching when all models are deleted
        isLLMStitchingEnabled = false
    }
    
    // MARK: - Errors
    
    enum LLMError: LocalizedError {
        case modelNotDownloaded
        case modelNotLoaded
        case inferenceFailure(String)
        
        var errorDescription: String? {
            switch self {
            case .modelNotDownloaded:
                return "Model has not been downloaded yet"
            case .modelNotLoaded:
                return "Model is not loaded into memory"
            case .inferenceFailure(let message):
                return "Inference failed: \(message)"
            }
        }
    }
}
