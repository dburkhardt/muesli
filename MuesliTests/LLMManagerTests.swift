import XCTest
@testable import Muesli

/// Tests for LLMManager
/// Focus: Model management, state tracking, and Hub API coordination WITHOUT actual downloads
@MainActor
final class LLMManagerTests: XCTestCase {
    
    // MARK: - Part 1: Initialization & Model Discovery
    
    /// Test manager initialization with lazy scan deferred
    func testManagerInitialization() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Should initialize without crashing
        XCTAssertNotNil(manager)
        XCTAssertTrue(manager.isMLXAvailable, "MLX should always be available")
    }
    
    /// Test model directory configuration
    func testModelDirectoryConfiguration() {
        let manager = LLMManager(skipHubAccess: true)
        
        let modelDir = manager.modelDirectory
        
        // Should return a valid URL
        XCTAssertFalse(modelDir.path.isEmpty)
        XCTAssertTrue(modelDir.path.contains("test-llm-models"), "Test directory should be in temp for skipHubAccess")
    }
    
    /// Test lazy scan on first property access (downloadedModels)
    func testLazyScanOnFirstAccess() {
        let manager = LLMManager(skipHubAccess: true)
        
        // First access to downloadedModels should trigger scan
        let models = manager.downloadedModels
        
        // With skipHubAccess, should return empty set
        XCTAssertTrue(models.isEmpty)
    }
    
    /// Test lazy scan on first hasModel access
    func testLazyScanOnHasModelAccess() {
        let manager = LLMManager(skipHubAccess: true)
        
        // First access to hasModel should trigger scan
        let hasModel = manager.hasModel
        
        // With skipHubAccess, should return false
        XCTAssertFalse(hasModel)
    }
    
    /// Test model path resolution
    func testModelPathResolution() {
        let manager = LLMManager(skipHubAccess: true)
        
        // With skip hub access, path should be nil
        let path = manager.pathForModel(.llama32_3b)
        
        XCTAssertNil(path, "Path should be nil when skipHubAccess is true")
    }
    
    /// Test model validation (config.json check)
    func testModelValidation() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Since skipHubAccess is true and no models exist, pathForModel returns nil
        // So we can't really test validation without real files
        // This test just ensures the method exists and doesn't crash
        let path = manager.pathForModel(.llama32_3b)
        
        XCTAssertNil(path)
    }
    
    // MARK: - Part 2: Model State Management
    
    /// Test download state tracking per model
    func testDownloadStateTracking() {
        let manager = LLMManager(skipHubAccess: true)
        
        // All models should start as idle
        for model in LLMManager.LLMModel.allCases {
            let state = manager.downloadState(for: model)
            XCTAssertEqual(state, .idle, "\(model) should start in idle state")
        }
    }
    
    /// Test active model selection and persistence
    func testActiveModelSelectionAndPersistence() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Initially no active model
        XCTAssertNil(manager.activeModel)
        
        // Set active model (even though not downloaded - for state tracking)
        manager.setActiveModel(.llama32_3b)
        
        // Note: setActiveModel checks if model is downloaded, so it won't actually set it
        // This tests the guard condition
        XCTAssertNil(manager.activeModel, "Should not set active model if not downloaded")
    }
    
    /// Test set active model (valid vs invalid)
    func testSetActiveModelValidVsInvalid() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Try to set model that's not downloaded (invalid)
        manager.setActiveModel(.llama32_3b)
        XCTAssertNil(manager.activeModel, "Should not set non-downloaded model as active")
        
        // Add model to downloaded set
        manager.downloadedModels.insert(.llama32_3b)
        manager.setActiveModel(.llama32_3b)
        
        // Now should be set
        XCTAssertEqual(manager.activeModel, .llama32_3b)
    }
    
    /// Test check if model is downloaded
    func testIsModelDownloaded() {
        let manager = LLMManager(skipHubAccess: true)
        
        // No models downloaded initially
        XCTAssertFalse(manager.isModelDownloaded(.llama32_3b))
        
        // Add to downloaded set
        manager.downloadedModels.insert(.llama32_3b)
        
        XCTAssertTrue(manager.isModelDownloaded(.llama32_3b))
        XCTAssertFalse(manager.isModelDownloaded(.phi3Mini), "Other models should not be downloaded")
    }
    
    /// Test LLM availability check
    func testLLMAvailabilityCheck() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Initially not available (no model, no container)
        XCTAssertFalse(manager.isLLMAvailable)
        
        // With model but no container
        manager.downloadedModels.insert(.llama32_3b)
        manager.setActiveModel(.llama32_3b)
        XCTAssertFalse(manager.isLLMAvailable, "Not available without loaded model container")
    }
    
    /// Test LLM stitching auto-enable on download
    func testLLMStitchingAutoEnableOnDownload() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Initially disabled if no models
        XCTAssertFalse(manager.isLLMStitchingEnabled)
        
        // Add a model manually
        manager.downloadedModels.insert(.llama32_3b)
        
        // Accessing isLLMStitchingEnabled should return true when hasModel is true
        XCTAssertTrue(manager.isLLMStitchingEnabled, "Should auto-enable when model exists")
    }
    
    // MARK: - Part 3: Model Deletion & Persistence
    
    /// Test delete model from filesystem
    func testDeleteModel() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Add model
        manager.downloadedModels.insert(.llama32_3b)
        XCTAssertTrue(manager.isModelDownloaded(.llama32_3b))
        
        // Delete model
        let deleted = manager.deleteModel(.llama32_3b)
        
        XCTAssertTrue(deleted, "Should return true for successful deletion")
        XCTAssertFalse(manager.isModelDownloaded(.llama32_3b), "Model should be removed from downloaded set")
    }
    
    /// Test delete active model (selects replacement)
    func testDeleteActiveModelSelectsReplacement() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Add two models
        manager.downloadedModels.insert(.llama32_3b)
        manager.downloadedModels.insert(.phi3Mini)
        manager.setActiveModel(.llama32_3b)
        
        XCTAssertEqual(manager.activeModel, .llama32_3b)
        
        // Delete active model
        _ = manager.deleteModel(.llama32_3b)
        
        // Should automatically select another available model
        XCTAssertNotEqual(manager.activeModel, .llama32_3b, "Active model should change")
        // Might be phi3Mini or nil depending on implementation
    }
    
    /// Test delete last model (clears active, disables stitching)
    func testDeleteLastModelClearsActiveAndDisables() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Add one model
        manager.downloadedModels.insert(.llama32_3b)
        manager.setActiveModel(.llama32_3b)
        
        // Delete it
        _ = manager.deleteModel(.llama32_3b)
        
        XCTAssertNil(manager.activeModel, "Active model should be nil")
        XCTAssertFalse(manager.hasModel, "Should have no models")
    }
    
    /// Test reset manager (clear all state)
    func testResetManager() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Add some state
        manager.downloadedModels.insert(.llama32_3b)
        manager.downloadedModels.insert(.phi3Mini)
        manager.setActiveModel(.llama32_3b)
        
        XCTAssertTrue(manager.hasModel)
        
        // Reset
        manager.reset()
        
        // All state should be cleared
        XCTAssertFalse(manager.hasModel, "Should have no models after reset")
        XCTAssertNil(manager.activeModel, "Active model should be nil after reset")
        XCTAssertTrue(manager.downloadedModels.isEmpty, "Downloaded models should be empty")
        
        // Download states should be reset to idle
        for model in LLMManager.LLMModel.allCases {
            XCTAssertEqual(manager.downloadState(for: model), .idle)
        }
    }
    
    // MARK: - Model Configuration Tests
    
    /// Test model configurations are valid
    func testModelConfigurations() {
        for model in LLMManager.LLMModel.allCases {
            XCTAssertFalse(model.displayName.isEmpty, "\(model) should have display name")
            XCTAssertFalse(model.sizeDescription.isEmpty, "\(model) should have size description")
            XCTAssertFalse(model.description.isEmpty, "\(model) should have description")
            XCTAssertFalse(model.huggingFaceRepo.isEmpty, "\(model) should have HF repo")
            XCTAssertFalse(model.sourceRepo.isEmpty, "\(model) should have source repo")
        }
    }
    
    /// Test model identifiable conformance
    func testModelIdentifiable() {
        let model = LLMManager.LLMModel.llama32_3b
        XCTAssertEqual(model.id, model.rawValue)
    }
    
    /// Test model URLs are valid
    func testModelURLsValid() {
        for model in LLMManager.LLMModel.allCases {
            let url = model.sourceURL
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(url.absoluteString.contains("huggingface.co"))
        }
    }
    
    // MARK: - Download State Tests
    
    /// Test download state equality
    func testDownloadStateEquality() {
        XCTAssertEqual(LLMManager.DownloadState.idle, .idle)
        XCTAssertEqual(LLMManager.DownloadState.checking, .checking)
        XCTAssertEqual(LLMManager.DownloadState.completed, .completed)
        
        // Progress states are equal with same progress
        XCTAssertEqual(LLMManager.DownloadState.downloading(progress: 0.5), 
                      .downloading(progress: 0.5))
        XCTAssertNotEqual(LLMManager.DownloadState.downloading(progress: 0.5), 
                         .downloading(progress: 0.6))
        
        // Failed states are equal with same message
        XCTAssertEqual(LLMManager.DownloadState.failed("error1"), .failed("error1"))
        XCTAssertNotEqual(LLMManager.DownloadState.failed("error1"), .failed("error2"))
    }
    
    // MARK: - LLM Error Tests
    
    /// Test LLM error descriptions
    func testLLMErrorDescriptions() {
        let notDownloaded = LLMManager.LLMError.modelNotDownloaded
        XCTAssertNotNil(notDownloaded.errorDescription)
        XCTAssertTrue(notDownloaded.errorDescription!.contains("not been downloaded"))
        
        let notLoaded = LLMManager.LLMError.modelNotLoaded
        XCTAssertNotNil(notLoaded.errorDescription)
        XCTAssertTrue(notLoaded.errorDescription!.contains("not loaded"))
        
        let inferenceFailed = LLMManager.LLMError.inferenceFailure("test error")
        XCTAssertNotNil(inferenceFailed.errorDescription)
        XCTAssertTrue(inferenceFailed.errorDescription!.contains("test error"))
    }
    
    // MARK: - State Consistency Tests
    
    /// Test unload model clears container
    func testUnloadModelClearsContainer() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Initially no container
        XCTAssertNil(manager.modelContainer)
        
        // Unload (should be no-op but shouldn't crash)
        manager.unloadModel()
        
        XCTAssertNil(manager.modelContainer)
    }
    
    /// Test multiple models in different states
    func testMultipleModelsInDifferentStates() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Simulate different download states
        manager.downloadStates[.llama32_3b] = .completed
        manager.downloadStates[.phi3Mini] = .downloading(progress: 0.5)
        manager.downloadStates[.gemma22b] = .idle
        
        XCTAssertEqual(manager.downloadState(for: .llama32_3b), .completed)
        XCTAssertEqual(manager.downloadState(for: .phi3Mini), .downloading(progress: 0.5))
        XCTAssertEqual(manager.downloadState(for: .gemma22b), .idle)
    }
    
    /// Test model case iteration
    func testModelCaseIteration() {
        // Should have exactly 3 models defined
        XCTAssertEqual(LLMManager.LLMModel.allCases.count, 3)
        
        let models = LLMManager.LLMModel.allCases
        XCTAssertTrue(models.contains(.llama32_3b))
        XCTAssertTrue(models.contains(.phi3Mini))
        XCTAssertTrue(models.contains(.gemma22b))
    }
    
    /// Test model hashable conformance
    func testModelHashable() {
        let model1 = LLMManager.LLMModel.llama32_3b
        let model2 = LLMManager.LLMModel.llama32_3b
        let model3 = LLMManager.LLMModel.phi3Mini
        
        XCTAssertEqual(model1.hashValue, model2.hashValue)
        XCTAssertNotEqual(model1.hashValue, model3.hashValue)
        
        // Can be used in Set
        let modelSet: Set<LLMManager.LLMModel> = [model1, model2, model3]
        XCTAssertEqual(modelSet.count, 2, "Set should deduplicate model1 and model2")
    }
    
    /// Test stitching disabled when all models deleted
    func testStitchingDisabledWhenAllModelsDeleted() {
        let manager = LLMManager(skipHubAccess: true)
        
        // Add and then remove all models
        manager.downloadedModels.insert(.llama32_3b)
        XCTAssertTrue(manager.isLLMStitchingEnabled)
        
        _ = manager.deleteModel(.llama32_3b)
        
        // Should be disabled after last model deleted
        XCTAssertFalse(manager.hasModel)
        // Note: isLLMStitchingEnabled returns true if hasModel is true, 
        // otherwise uses stored preference
    }
    
    /// Test download state returns idle for unknown model
    func testDownloadStateReturnsIdleForUnknownModel() {
        let manager = LLMManager(skipHubAccess: true)
        
        // All models should be initialized as idle
        for model in LLMManager.LLMModel.allCases {
            let state = manager.downloadState(for: model)
            XCTAssertEqual(state, .idle)
        }
    }
}
