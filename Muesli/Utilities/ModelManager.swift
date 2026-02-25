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
        case small = "small"
        case medium = "medium"
        case large = "large-v3-v20240930"
        case largeTurbo = "large-v3-v20240930_turbo"
        
        var id: String { rawValue }
        
        /// Display name for menus and general UI (just the name)
        var displayName: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large v3"
            case .largeTurbo: return "Large v3 Turbo"
            }
        }
        
        /// Detailed display name with recommendation for preferences/onboarding
        /// Size is shown separately below, so not included here
        var displayNameDetailed: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large v3 — Best Quality"
            case .largeTurbo: return "Large v3 Turbo — Recommended"
            }
        }
        
        var sizeDescription: String {
            switch self {
            case .small: return "465 MB"
            case .medium: return "1.5 GB"
            case .large: return "3 GB"
            case .largeTurbo: return "1.6 GB"
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
        case compiling   // CoreML optimization in progress
        case completed   // Downloaded AND compiled — ready for use
        case failed(String)
    }
    
    // MARK: - State
    
    /// Download state for each model
    var downloadStates: [ModelSize: DownloadState] = [:]
    
    /// Set of downloaded models
    var downloadedModels: Set<ModelSize> = []
    
    /// Active download tasks (for cancellation support)
    private var downloadTasks: [ModelSize: Task<Void, Never>] = [:]

    /// Active compilation tasks (for lifecycle management)
    private var compilationTasks: [ModelSize: Task<Void, Never>] = [:]
    
    /// Stored paths for downloaded models (persisted to UserDefaults)
    /// Key: model rawValue, Value: actual path returned by WhisperKit.download()
    var modelPaths: [ModelSize: URL] = [:]
    
    /// Downloaded models sorted in canonical order (matching allCases)
    var downloadedModelsOrdered: [ModelSize] {
        ModelSize.allCases.filter { downloadedModels.contains($0) }
    }
    
    /// Currently active model for transcription
    var activeModel: ModelSize? {
        didSet {
            if let activeModel {
                UserDefaults.standard.set(activeModel.rawValue, forKey: AppStorageKeys.activeWhisperModel)
            } else {
                UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeWhisperModel)
            }
        }
    }
    
    /// Legacy single model path (for backwards compatibility)
    var modelPath: URL? {
        guard let active = activeModel else { return nil }
        return pathForModel(active)
    }
    
    /// Check if at least one model is downloaded and active
    var hasModel: Bool {
        activeModel != nil && downloadedModels.contains(activeModel!)
    }

    /// Whether the active model is fully ready (downloaded AND compiled)
    var isActiveModelReady: Bool {
        guard let active = activeModel else { return false }
        return downloadStates[active] == .completed
    }

    /// Whether any downloaded model is fully ready (downloaded AND compiled)
    var hasAnyReadyModel: Bool {
        downloadStates.values.contains { $0 == .completed }
    }

    /// First model in `.completed` state, preferring the active model
    var firstReadyModel: ModelManager.ModelSize? {
        if let active = activeModel, downloadStates[active] == .completed { return active }
        return ModelManager.ModelSize.allCases.first { downloadStates[$0] == .completed }
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
        
        // Migration: Handle removed models (tiny, base) - clear preference to trigger fallback
        if let savedModel = UserDefaults.standard.string(forKey: AppStorageKeys.activeWhisperModel),
           savedModel == "tiny" || savedModel == "base" {
            Self.logger.info("Migrating from removed model '\(savedModel)' - will select first valid model")
            UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeWhisperModel)
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

            // Trigger background compilation probe for the active model
            // Fast (~1-2s) if CoreML cache is warm; full compilation if cache was evicted
            probeActiveModelCompilation()
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
            
            // Check if this folder matches our model without ambiguous substring matches.
            if folderNameMatchesModel(folderName, model: model) {
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

    /// Match a folder name to a model without ambiguous substring checks.
    /// Example: "large-v3-v20240930" must NOT match "..._turbo".
    private func folderNameMatchesModel(_ folderName: String, model: ModelSize) -> Bool {
        folderName == "openai_whisper-\(model.whisperKitName)" || folderName.hasSuffix(model.rawValue)
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
            activeModel = nil
            if let valid = getFirstValidModel() {
                setActiveModel(valid)
            } else {
                activeModel = nil
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
                    // Match by checking if the folder ENDS WITH the model's rawValue
                    // (Using hasSuffix prevents "large-v3-v20240930" from matching "...turbo" folder)
                    if folderName.hasSuffix(model.rawValue) {
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
            let isValid = validateModel(model)
            let hasPath = pathForModel(model) != nil
            if isValid {
                downloadedModels.insert(model)
                // Non-active models get .completed; active model gets compiled below
                downloadStates[model] = .completed
            } else if hasPath {
                // Model directory exists but is incomplete/corrupted
                downloadStates[model] = .failed("Model is incomplete or corrupted")
            }
        }
    }

    /// Trigger compilation probe for the active model on app launch.
    /// Call this after init has set activeModel.
    /// Skips compilation if the compile stamp matches (model folder unchanged, same app version).
    /// Fast (~1-2s) if CoreML cache is warm; full compilation if cache was evicted.
    func probeActiveModelCompilation() {
        guard let active = activeModel, downloadedModels.contains(active) else { return }

        if compileStampIsValid(for: active) {
            // Stamp matches — CoreML cache should be warm, skip probe.
            Self.logger.info("MODEL_COMPILE_PROBE_SKIPPED: \(active.displayName) — compile stamp is current")
            // Model remains .completed; no state change needed.
            return
        }

        Self.logger.info("MODEL_COMPILE_PROBE_START: \(active.displayName) — compile stamp missing or stale")
        downloadStates[active] = .compiling
        startCompilation(for: active)
    }

    // MARK: - Compile Stamp Helpers

    /// Build the compile stamp string for a model.
    /// Format: "<modelRawValue>|<folderPath>|<folderModTime>"
    /// Note: app version is intentionally excluded — model files on disk are the
    /// only thing that determines whether recompilation is needed. Including the
    /// app version caused unnecessary multi-minute recompilations on every update.
    private func buildCompileStamp(for model: ModelSize) -> String? {
        guard let folderURL = pathForModel(model) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: folderURL.path)
        let modTime = (attrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(model.rawValue)|\(folderURL.path)|\(modTime)"
    }

    /// Returns true if the persisted compile stamp for `model` matches the current stamp.
    private func compileStampIsValid(for model: ModelSize) -> Bool {
        guard let current = buildCompileStamp(for: model) else { return false }
        let stamps = UserDefaults.standard.dictionary(forKey: AppStorageKeys.whisperModelCompileStamps) as? [String: String] ?? [:]
        return stamps[model.rawValue] == current
    }

    /// Persist the compile stamp for `model` after successful compilation.
    func saveCompileStamp(for model: ModelSize) {
        guard let stamp = buildCompileStamp(for: model) else { return }
        var stamps = UserDefaults.standard.dictionary(forKey: AppStorageKeys.whisperModelCompileStamps) as? [String: String] ?? [:]
        stamps[model.rawValue] = stamp
        UserDefaults.standard.set(stamps, forKey: AppStorageKeys.whisperModelCompileStamps)
        Self.logger.debug("Saved compile stamp for \(model.displayName)")
    }
    
    // MARK: - Download
    
    /// Download a specific model
    @MainActor
    func downloadModel(_ model: ModelSize) async {
        Self.logger.info("Starting download for model: \(model.displayName) (\(model.whisperKitName))")
        downloadStates[model] = .checking
        
        let targetDir = modelDirectory
        Self.logger.info("Target directory: \(targetDir.path)")
        
        // Create and store the download task for cancellation support
        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            do {
                self.downloadStates[model] = .downloading(progress: 0)
                
                Self.logger.info("Calling WhisperKit.download with variant=\(model.whisperKitName), downloadBase=\(targetDir.path)")
                
                // Use WhisperKit's built-in download functionality with progress tracking
                let folder = try await WhisperKit.download(
                    variant: model.whisperKitName,
                    downloadBase: targetDir,
                    useBackgroundSession: false,
                    progressCallback: { @Sendable progress in
                        // Update progress on main thread
                        Task { @MainActor [weak self] in
                            // Check if cancelled before updating
                            guard self?.downloadTasks[model] != nil else { return }
                            self?.downloadStates[model] = .downloading(progress: progress.fractionCompleted)
                            Self.logger.debug("Download progress for \(model.displayName): \(progress.fractionCompleted * 100, format: .fixed(precision: 1))%")
                        }
                    }
                )
                
                // Check for cancellation before completing
                if Task.isCancelled {
                    Self.logger.info("Download was cancelled for \(model.displayName)")
                    return
                }
                
                Self.logger.info("Download completed successfully for \(model.displayName). Folder: \(folder)")

                // Store the actual path returned by WhisperKit (it's already a URL)
                self.modelPaths[model] = folder
                Self.logger.info("Stored model path: \(folder.path)")

                // Mark as downloaded
                self.downloadedModels.insert(model)

                // If no active model, set this as active
                if self.activeModel == nil {
                    self.setActiveModel(model)
                }

                // Persist both downloaded models and paths
                self.saveDownloadedModels()
                self.saveModelPaths()

                // Transition to compiling and start compilation
                self.downloadStates[model] = .compiling
                self.startCompilation(for: model)
            } catch {
                // Check if this was a cancellation
                if Task.isCancelled {
                    Self.logger.info("Download was cancelled for \(model.displayName)")
                    return
                }
                
                Self.logger.error("Download failed for \(model.displayName): \(error.localizedDescription)")
                Self.logger.error("Error details: \(String(describing: error))")
                
                // Log NSError details if available
                if let nsError = error as NSError? {
                    Self.logger.error("NSError domain: \(nsError.domain), code: \(nsError.code)")
                    Self.logger.error("NSError userInfo: \(nsError.userInfo)")
                }
                
                self.downloadStates[model] = .failed(error.localizedDescription)
            }
            
            // Remove task reference after completion
            self.downloadTasks.removeValue(forKey: model)
        }
        
        downloadTasks[model] = task
        await task.value
    }
    
    /// Cancel an in-progress download and clean up partial files
    @MainActor
    func cancelDownload(_ model: ModelSize) {
        guard let task = downloadTasks[model] else {
            Self.logger.info("No active download to cancel for \(model.displayName)")
            return
        }
        
        Self.logger.info("Cancelling download for \(model.displayName)")
        
        // Cancel the task
        task.cancel()
        downloadTasks.removeValue(forKey: model)
        
        // Reset state
        downloadStates[model] = .idle
        
        // Clean up partial download files
        cleanupPartialDownload(model)
    }
    
    /// Clean up partial download files from disk
    private func cleanupPartialDownload(_ model: ModelSize) {
        let whisperKitDir = modelDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        
        // Look for partial model directory
        guard FileManager.default.fileExists(atPath: whisperKitDir.path),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: whisperKitDir,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return
        }
        
        // Find and remove the partial model folder
        for folderURL in contents {
            let folderName = folderURL.lastPathComponent
            if folderNameMatchesModel(folderName, model: model) {
                do {
                    try FileManager.default.removeItem(at: folderURL)
                    Self.logger.info("Cleaned up partial download at: \(folderURL.path)")
                    
                    // Remove stored path if any
                    modelPaths.removeValue(forKey: model)
                    saveModelPaths()
                } catch {
                    Self.logger.error("Failed to clean up partial download: \(error.localizedDescription)")
                }
                break
            }
        }
    }
    
    /// Check if a model is currently downloading
    func isDownloading(_ model: ModelSize) -> Bool {
        if case .downloading = downloadStates[model] {
            return true
        }
        return false
    }
    
    /// Check if any model is currently downloading
    var isAnyModelDownloading: Bool {
        downloadStates.values.contains { state in
            if case .downloading = state { return true }
            return false
        }
    }

    /// Check if any model is currently downloading or compiling
    var isAnyModelBusy: Bool {
        downloadStates.values.contains { state in
            switch state {
            case .downloading, .compiling: return true
            default: return false
            }
        }
    }
    
    /// Set the active model for transcription
    func setActiveModel(_ model: ModelSize) {
        guard downloadedModels.contains(model) else { return }
        activeModel = model
        UserDefaults.standard.set(model.rawValue, forKey: AppStorageKeys.activeWhisperModel)
    }
    
    // MARK: - Model Compilation

    /// Compile model for device (triggers CoreML optimization on first use)
    /// - Parameters:
    ///   - model: The model size to compile
    /// - Note: WhisperKit.init() triggers CoreML compilation; instance can be discarded after.
    ///         Cancellation is "best effort" - WhisperKit may continue compiling in background
    ///         if task is cancelled, but UI will proceed.
    func compileModel(_ model: ModelSize) async throws {
        guard let modelPath = pathForModel(model) else {
            throw MuesliError.modelNotFound
        }

        // Use the same config as TranscriptionService.initialize() to ensure path parity
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let muesliDir = appSupport.appendingPathComponent("Muesli", isDirectory: true)

        Self.logger.info("Compiling model \(model.displayName) at path: \(modelPath.path)")

        let config = WhisperKitConfig(
            downloadBase: muesliDir,
            modelFolder: modelPath.path,
            tokenizerFolder: muesliDir.appendingPathComponent("Tokenizers"),
            verbose: false,
            download: false
        )

        // Initialize WhisperKit - this triggers CoreML compilation on first use
        // The instance is discarded after; we only care about the compilation side effect
        _ = try await WhisperKit(config)

        Self.logger.info("Model compilation completed for \(model.displayName)")
    }

    /// Start background compilation for a model.
    /// Transitions .compiling → .completed or .failed.
    private func startCompilation(for model: ModelSize) {
        // Guard against duplicate compilations
        guard compilationTasks[model] == nil else {
            Self.logger.info("Skipping compilation for \(model.displayName) - already in progress")
            return
        }

        Task {
            await DiagnosticLogger.shared.log(.transcription, "Compilation started for \(model.displayName)")
        }

        let task = Task { [weak self] in
            guard let self = self else { return }
            let startTime = Date()

            do {
                try await self.compileModel(model)

                // Check cancellation before updating state
                guard !Task.isCancelled else { return }

                let duration = Date().timeIntervalSince(startTime)
                self.downloadStates[model] = .completed
                self.saveCompileStamp(for: model)

                Task {
                    await DiagnosticLogger.shared.log(
                        .transcription,
                        "Compilation completed for \(model.displayName) in \(String(format: "%.1f", duration))s"
                    )
                }
            } catch {
                // Check cancellation before updating state
                guard !Task.isCancelled else { return }

                self.downloadStates[model] = .failed("Optimization failed: \(error.localizedDescription)")

                Task {
                    await DiagnosticLogger.shared.log(
                        .transcription,
                        "Compilation failed for \(model.displayName): \(error.localizedDescription)"
                    )
                }
            }

            // Remove task reference after completion
            self.compilationTasks.removeValue(forKey: model)
        }

        compilationTasks[model] = task
    }

    /// Retry compilation after a failure (no re-download needed).
    func retryCompilation(_ model: ModelSize) {
        // Only retry from failed state
        guard case .failed = downloadStates[model] else { return }
        // Must be a downloaded model
        guard downloadedModels.contains(model) else { return }
        // Guard against duplicate compilations
        guard compilationTasks[model] == nil else { return }

        downloadStates[model] = .compiling
        startCompilation(for: model)
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
        
        // If we can't determine the model size, we can't safely use it
        // (tiny/base are removed, and guessing could assign wrong model)
        Self.logger.warning("Could not determine model size for folder: \(url.lastPathComponent)")
        return false
    }
    
    // MARK: - Delete Model
    
    /// Delete a model from disk and update state
    /// - Parameter model: The model to delete
    /// - Returns: True if deletion was successful, false otherwise
    @MainActor
    func deleteModel(_ model: ModelSize) -> Bool {
        guard downloadedModels.contains(model) else { return false }

        // Cancel any active compilation task
        if let task = compilationTasks[model] {
            task.cancel()
            compilationTasks.removeValue(forKey: model)
        }
        
        // Get the model directory path
        guard let modelPath = pathForModel(model) else {
            // Model path doesn't exist, but it's in our set - clean up state
            downloadedModels.remove(model)
            modelPaths.removeValue(forKey: model)
            downloadStates[model] = .idle
            if activeModel == model {
                activeModel = nil
                UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeWhisperModel)
            }
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
        // Cancel all compilation tasks
        for (_, task) in compilationTasks {
            task.cancel()
        }
        compilationTasks.removeAll()

        for model in ModelSize.allCases {
            downloadStates[model] = .idle
        }
        downloadedModels.removeAll()
        modelPaths.removeAll()
        activeModel = nil
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.activeWhisperModel)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.downloadedWhisperModels)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.whisperModelPaths)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.whisperModelCompileStamps)
    }
}
