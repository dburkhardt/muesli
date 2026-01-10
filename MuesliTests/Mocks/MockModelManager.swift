import Foundation
@testable import Muesli_vmr

/// Mock implementation of ModelManager for testing
final class MockModelManager: ModelManagerProtocol, @unchecked Sendable {
    
    // MARK: - State
    
    var downloadStates: [ModelManager.ModelSize: ModelManager.DownloadState] = [:]
    var downloadedModels: Set<ModelManager.ModelSize> = []
    var activeModel: ModelManager.ModelSize?
    
    var modelPath: URL? {
        guard let active = activeModel else { return nil }
        return pathForModel(active)
    }
    
    var hasModel: Bool {
        activeModel != nil && downloadedModels.contains(activeModel!)
    }
    
    var modelDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MockMuesliModels")
    }
    
    // MARK: - Test Control Properties
    
    var shouldFailValidation: Bool = false
    var mockModelPaths: [ModelManager.ModelSize: URL] = [:]
    
    // MARK: - Call Tracking
    
    var pathForModelCallCount: Int = 0
    var isModelDownloadedCallCount: Int = 0
    var validateModelCallCount: Int = 0
    var getFirstValidModelCallCount: Int = 0
    var markModelCorruptedCallCount: Int = 0
    var downloadStateCallCount: Int = 0
    var scanForDownloadedModelsCallCount: Int = 0
    var downloadModelCallCount: Int = 0
    var setActiveModelCallCount: Int = 0
    var deleteModelCallCount: Int = 0
    var showModelsInFinderCallCount: Int = 0
    var resetCallCount: Int = 0
    
    var lastDownloadedModel: ModelManager.ModelSize?
    var lastSetActiveModel: ModelManager.ModelSize?
    var lastDeletedModel: ModelManager.ModelSize?
    var lastCorruptedModel: ModelManager.ModelSize?
    
    // MARK: - Initialization
    
    init() {
        // Initialize all models as idle
        for model in ModelManager.ModelSize.allCases {
            downloadStates[model] = .idle
        }
    }
    
    // MARK: - ModelManagerProtocol
    
    func pathForModel(_ model: ModelManager.ModelSize) -> URL? {
        pathForModelCallCount += 1
        if let mockPath = mockModelPaths[model] {
            return mockPath
        }
        guard downloadedModels.contains(model) else { return nil }
        return modelDirectory.appendingPathComponent(model.whisperKitName)
    }
    
    func isModelDownloaded(_ model: ModelManager.ModelSize) -> Bool {
        isModelDownloadedCallCount += 1
        return downloadedModels.contains(model)
    }
    
    func validateModel(_ model: ModelManager.ModelSize) -> Bool {
        validateModelCallCount += 1
        if shouldFailValidation { return false }
        return downloadedModels.contains(model)
    }
    
    func getFirstValidModel() -> ModelManager.ModelSize? {
        getFirstValidModelCallCount += 1
        if shouldFailValidation { return nil }
        if let active = activeModel, downloadedModels.contains(active) {
            return active
        }
        return downloadedModels.first
    }
    
    func markModelCorrupted(_ model: ModelManager.ModelSize) {
        markModelCorruptedCallCount += 1
        lastCorruptedModel = model
        downloadedModels.remove(model)
        downloadStates[model] = .failed("Model is corrupted")
        
        if activeModel == model {
            activeModel = downloadedModels.first
        }
    }
    
    func downloadState(for model: ModelManager.ModelSize) -> ModelManager.DownloadState {
        downloadStateCallCount += 1
        return downloadStates[model] ?? .idle
    }
    
    func scanForDownloadedModels() {
        scanForDownloadedModelsCallCount += 1
    }
    
    func downloadModel(_ model: ModelManager.ModelSize) async {
        downloadModelCallCount += 1
        lastDownloadedModel = model
        
        downloadStates[model] = .downloading(progress: 0.5)
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
        
        downloadedModels.insert(model)
        downloadStates[model] = .completed
        
        if activeModel == nil {
            activeModel = model
        }
    }
    
    func setActiveModel(_ model: ModelManager.ModelSize) {
        setActiveModelCallCount += 1
        lastSetActiveModel = model
        guard downloadedModels.contains(model) else { return }
        activeModel = model
    }
    
    func deleteModel(_ model: ModelManager.ModelSize) -> Bool {
        deleteModelCallCount += 1
        lastDeletedModel = model
        
        downloadedModels.remove(model)
        downloadStates[model] = .idle
        
        if activeModel == model {
            activeModel = downloadedModels.first
        }
        
        return true
    }
    
    func showModelsInFinder() {
        showModelsInFinderCallCount += 1
    }
    
    func reset() {
        resetCallCount += 1
        downloadedModels.removeAll()
        activeModel = nil
        for model in ModelManager.ModelSize.allCases {
            downloadStates[model] = .idle
        }
    }
    
    // MARK: - Test Helpers
    
    /// Add a downloaded model (simulates model being available)
    func addDownloadedModel(_ model: ModelManager.ModelSize, setActive: Bool = true) {
        downloadedModels.insert(model)
        downloadStates[model] = .completed
        
        // Create mock model path
        let modelPath = modelDirectory.appendingPathComponent(model.whisperKitName)
        mockModelPaths[model] = modelPath
        
        if setActive || activeModel == nil {
            activeModel = model
        }
    }
    
    /// Reset all tracking state for next test
    func resetTracking() {
        pathForModelCallCount = 0
        isModelDownloadedCallCount = 0
        validateModelCallCount = 0
        getFirstValidModelCallCount = 0
        markModelCorruptedCallCount = 0
        downloadStateCallCount = 0
        scanForDownloadedModelsCallCount = 0
        downloadModelCallCount = 0
        setActiveModelCallCount = 0
        deleteModelCallCount = 0
        showModelsInFinderCallCount = 0
        resetCallCount = 0
        lastDownloadedModel = nil
        lastSetActiveModel = nil
        lastDeletedModel = nil
        lastCorruptedModel = nil
    }
}
