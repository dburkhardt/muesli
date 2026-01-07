import Foundation
import AppKit
import Hub
import MLXLLM
import MLXLMCommon

/// Manages local LLM model downloading and inference for transcript stitching
/// Models are stored in Hugging Face cache directory
///
/// Uses MLX-Swift for on-device LLM inference
@Observable
@MainActor
final class LLMManager {
    
    // MARK: - Model Options
    
    enum LLMModel: String, CaseIterable, Identifiable, Hashable {
        case llama3_2_3b = "Llama-3.2-3B-Instruct-4bit"
        case phi3_mini = "Phi-3-mini-4k-instruct-4bit"
        case gemma2_2b = "gemma-2-2b-it-4bit"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .llama3_2_3b: return "Llama 3.2 3B (Recommended)"
            case .phi3_mini: return "Phi-3 Mini"
            case .gemma2_2b: return "Gemma 2 2B"
            }
        }
        
        var sizeDescription: String {
            switch self {
            case .llama3_2_3b: return "~2GB"
            case .phi3_mini: return "~2.3GB"
            case .gemma2_2b: return "~1.5GB"
            }
        }
        
        var description: String {
            switch self {
            case .llama3_2_3b: return "Best balance of quality and speed"
            case .phi3_mini: return "Good for longer context"
            case .gemma2_2b: return "Smaller, faster"
            }
        }
        
        /// Hugging Face model identifier
        var huggingFaceRepo: String {
            switch self {
            case .llama3_2_3b: return "mlx-community/Llama-3.2-3B-Instruct-4bit"
            case .phi3_mini: return "mlx-community/Phi-3-mini-4k-instruct-4bit"
            case .gemma2_2b: return "mlx-community/gemma-2-2b-it-4bit"
            }
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
    
    /// Set of downloaded models
    var downloadedModels: Set<LLMModel> = []
    
    /// Currently active model for stitching
    var activeModel: LLMModel?
    
    /// Whether at least one model is downloaded
    var hasModel: Bool {
        !downloadedModels.isEmpty
    }
    
    /// Loaded model container for inference
    private(set) var modelContainer: ModelContainer?
    
    /// Whether LLM stitching is available (model downloaded and loaded)
    var isLLMAvailable: Bool {
        modelContainer != nil && activeModel != nil
    }
    
    /// MLX-Swift is always available now that we've added the dependency
    let isMLXAvailable: Bool = true
    
    // MARK: - Storage Keys
    
    private static let activeModelKey = "activeLLMModel"
    private static let downloadedModelsKey = "downloadedLLMModels"
    private static let llmEnabledKey = "llmStitchingEnabled"
    
    /// User preference: enable LLM stitching (can be disabled even if model exists)
    var isLLMStitchingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.llmEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.llmEnabledKey) }
    }
    
    /// Hub API for downloading models
    private let hubApi = HubApi()
    
    // MARK: - Initialization
    
    init() {
        // Initialize all models as idle
        for model in LLMModel.allCases {
            downloadStates[model] = .idle
        }
        
        // Scan for existing downloaded models
        scanForDownloadedModels()
        
        // Load saved active model preference
        if let savedModel = UserDefaults.standard.string(forKey: Self.activeModelKey),
           let model = LLMModel(rawValue: savedModel),
           downloadedModels.contains(model) {
            activeModel = model
        } else if let firstDownloaded = downloadedModels.first {
            activeModel = firstDownloaded
        }
    }
    
    // MARK: - Model Directory
    
    /// Returns the Hub cache directory for models
    var modelDirectory: URL {
        // Use a dummy config to get the base cache location
        let dummyConfig = ModelConfiguration(id: "mlx-community/test")
        return dummyConfig.modelDirectory(hub: hubApi).deletingLastPathComponent().deletingLastPathComponent()
    }
    
    /// Get the path for a specific model (from Hub cache)
    func pathForModel(_ model: LLMModel) -> URL? {
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
        downloadStates[model] ?? .idle
    }
    
    /// Scan the models directory to detect previously downloaded models
    func scanForDownloadedModels() {
        downloadedModels.removeAll()
        
        for model in LLMModel.allCases {
            if pathForModel(model) != nil {
                downloadedModels.insert(model)
                downloadStates[model] = .completed
            }
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
            UserDefaults.standard.set(model.rawValue, forKey: Self.activeModelKey)
            
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
        UserDefaults.standard.set(model.rawValue, forKey: Self.activeModelKey)
    }
    
    // MARK: - Persistence
    
    private func saveDownloadedModels() {
        let modelStrings = downloadedModels.map { $0.rawValue }
        UserDefaults.standard.set(modelStrings, forKey: Self.downloadedModelsKey)
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
                UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
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
        UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
        UserDefaults.standard.removeObject(forKey: Self.downloadedModelsKey)
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
