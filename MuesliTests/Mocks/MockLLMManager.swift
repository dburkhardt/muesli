import Foundation
@testable import Muesli

/// Mock implementation of LLMManager for testing
@MainActor
final class MockLLMManager: LLMManagerProtocol {
    // MARK: - State
    
    var downloadStates: [LLMManager.LLMModel: LLMManager.DownloadState] = [:]
    var downloadedModels: Set<LLMManager.LLMModel> = []
    var activeModel: LLMManager.LLMModel?
    
    var hasModel: Bool {
        !downloadedModels.isEmpty
    }
    
    var isLLMAvailable: Bool {
        _modelContainer != nil && activeModel != nil
    }
    
    let isMLXAvailable: Bool = true
    
    var isLLMStitchingEnabled: Bool = false
    
    private var _modelContainer: Any?
    var modelContainer: Any? {
        _modelContainer
    }
    
    // MARK: - Test Control Properties
    
    var shouldFailLoadModel: Bool = false
    var loadModelError: Error = LLMManager.LLMError.modelNotDownloaded
    var mockModelPaths: [LLMManager.LLMModel: URL] = [:]
    
    // MARK: - Call Tracking
    
    var pathForModelCallCount: Int = 0
    var isModelDownloadedCallCount: Int = 0
    var downloadStateCallCount: Int = 0
    var scanForDownloadedModelsCallCount: Int = 0
    var downloadModelCallCount: Int = 0
    var loadModelCallCount: Int = 0
    var unloadModelCallCount: Int = 0
    var setActiveModelCallCount: Int = 0
    var deleteModelCallCount: Int = 0
    var showModelsInFinderCallCount: Int = 0
    var resetCallCount: Int = 0
    
    var lastDownloadedModel: LLMManager.LLMModel?
    var lastLoadedModel: LLMManager.LLMModel?
    var lastSetActiveModel: LLMManager.LLMModel?
    var lastDeletedModel: LLMManager.LLMModel?
    
    // MARK: - Initialization
    
    init() {
        // Initialize all models as idle
        for model in LLMManager.LLMModel.allCases {
            downloadStates[model] = .idle
        }
    }
    
    // MARK: - LLMManagerProtocol
    
    func pathForModel(_ model: LLMManager.LLMModel) -> URL? {
        pathForModelCallCount += 1
        if let mockPath = mockModelPaths[model] {
            return mockPath
        }
        guard downloadedModels.contains(model) else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent(model.rawValue)
    }
    
    func isModelDownloaded(_ model: LLMManager.LLMModel) -> Bool {
        isModelDownloadedCallCount += 1
        return downloadedModels.contains(model)
    }
    
    func downloadState(for model: LLMManager.LLMModel) -> LLMManager.DownloadState {
        downloadStateCallCount += 1
        return downloadStates[model] ?? .idle
    }
    
    func scanForDownloadedModels() {
        scanForDownloadedModelsCallCount += 1
    }
    
    func downloadModel(_ model: LLMManager.LLMModel) async {
        downloadModelCallCount += 1
        lastDownloadedModel = model
        
        downloadStates[model] = .downloading(progress: 0.5)
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
        
        downloadedModels.insert(model)
        downloadStates[model] = .completed
        isLLMStitchingEnabled = true
        
        if activeModel == nil {
            activeModel = model
        }
    }
    
    func loadModel(_ model: LLMManager.LLMModel) async throws {
        loadModelCallCount += 1
        lastLoadedModel = model
        
        if shouldFailLoadModel {
            throw loadModelError
        }
        
        guard downloadedModels.contains(model) else {
            throw LLMManager.LLMError.modelNotDownloaded
        }
        
        downloadStates[model] = .loading
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
        
        _modelContainer = "MockModelContainer"  // Placeholder object
        activeModel = model
        downloadStates[model] = .completed
    }
    
    func unloadModel() {
        unloadModelCallCount += 1
        _modelContainer = nil
    }
    
    func setActiveModel(_ model: LLMManager.LLMModel) {
        setActiveModelCallCount += 1
        lastSetActiveModel = model
        guard downloadedModels.contains(model) else { return }
        activeModel = model
    }
    
    func deleteModel(_ model: LLMManager.LLMModel) -> Bool {
        deleteModelCallCount += 1
        lastDeletedModel = model
        
        if activeModel == model {
            unloadModel()
        }
        
        downloadedModels.remove(model)
        downloadStates[model] = .idle
        
        if activeModel == model {
            activeModel = downloadedModels.first
        }
        
        if downloadedModels.isEmpty {
            isLLMStitchingEnabled = false
        }
        
        return true
    }
    
    func showModelsInFinder() {
        showModelsInFinderCallCount += 1
    }
    
    func reset() {
        resetCallCount += 1
        unloadModel()
        downloadedModels.removeAll()
        activeModel = nil
        isLLMStitchingEnabled = false
        for model in LLMManager.LLMModel.allCases {
            downloadStates[model] = .idle
        }
    }
    
    // MARK: - Test Helpers
    
    /// Add a downloaded model (simulates model being available)
    func addDownloadedModel(_ model: LLMManager.LLMModel, setActive: Bool = true, loaded: Bool = false) {
        downloadedModels.insert(model)
        downloadStates[model] = .completed
        isLLMStitchingEnabled = true
        
        if setActive || activeModel == nil {
            activeModel = model
        }
        
        if loaded {
            _modelContainer = "MockModelContainer"
        }
    }
    
    /// Reset all tracking state for next test
    func resetTracking() {
        pathForModelCallCount = 0
        isModelDownloadedCallCount = 0
        downloadStateCallCount = 0
        scanForDownloadedModelsCallCount = 0
        downloadModelCallCount = 0
        loadModelCallCount = 0
        unloadModelCallCount = 0
        setActiveModelCallCount = 0
        deleteModelCallCount = 0
        showModelsInFinderCallCount = 0
        resetCallCount = 0
        lastDownloadedModel = nil
        lastLoadedModel = nil
        lastSetActiveModel = nil
        lastDeletedModel = nil
    }
}
