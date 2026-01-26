import CoreMedia
import Foundation

// MARK: - AudioCaptureServiceProtocol

/// Protocol for AudioCaptureService to enable mocking in tests
protocol AudioCaptureServiceProtocol: Sendable {
    var isRecording: Bool { get async }
    
    func setBufferHandler(_ handler: @escaping AudioBufferHandler) async
    func setInterruptedHandler(_ handler: @escaping StreamInterruptedHandler) async
    func setLevelHandler(_ handler: @escaping AudioLevelHandler) async
    func setMicrophoneDevice(_ deviceID: String?) async
    func startCapture() async throws
    func startCapture(forBundleIdentifier bundleIdentifier: String) async throws
    func stopCapture() async throws
}

// MARK: - TranscriptionServiceProtocol

/// Protocol for TranscriptionService to enable mocking in tests
protocol TranscriptionServiceProtocol: Sendable {
    var transcriptionMode: TranscriptionService.TranscriptionMode { get }
    
    func initialize(modelPath: URL) async throws
    func setTranscriptionMode(_ mode: TranscriptionService.TranscriptionMode)
    func setTranscriptHandler(_ handler: @escaping TranscriptionService.TranscriptHandler)
    func startTranscription(recordingStartTime: Date)
    func stopTranscription() async
    func appendSystemAudio(_ samples: [Float])
    func appendMicrophoneAudio(_ samples: [Float])
    func transcribePostProcessing(systemAudioURL: URL?, micAudioURL: URL?, startTime: Date) async throws
}

// MARK: - FileOutputServiceProtocol

/// Protocol for FileOutputService to enable mocking in tests
protocol FileOutputServiceProtocol: Sendable {
    var isWriting: Bool { get }
    
    func setOutputDirectory(_ url: URL)
    func getOutputDirectory() -> URL
    func startWriting(segmentNumber: Int) throws -> URL
    func appendAudioBuffer(_ buffer: CMSampleBuffer, type: AudioCaptureService.AudioType)
    func stopWriting() async throws -> URL
    func resumeWriting(to directory: URL, segmentNumber: Int) throws -> URL
    func saveTranscript(_ transcript: String, title: String, date: Date, to directory: URL) throws
    func saveTranscriptBlocks(
        _ blocks: [TranscriptBlock],
        title: String,
        date: Date,
        to directory: URL,
        filename: String?
    ) throws
}

// MARK: - MeetingHistoryServiceProtocol

/// Protocol for MeetingHistoryService to enable mocking in tests
@MainActor
protocol MeetingHistoryServiceProtocol {
    func discoverMeetings() -> [MeetingHistoryItem]
    func loadTranscript(for meeting: MeetingHistoryItem) -> String?
    func loadTranscriptBlocks(for meeting: MeetingHistoryItem) -> [TranscriptBlock]?
    func loadOriginalTranscriptBlocks(for meeting: MeetingHistoryItem) -> [TranscriptBlock]?
    func loadOriginalTranscript(for meeting: MeetingHistoryItem) -> String?
}

// MARK: - MeetingAppDetectorProtocol

/// Protocol for MeetingAppDetector to enable mocking in tests
@MainActor
protocol MeetingAppDetectorProtocol {
    func detectMeetingApps() async -> [MeetingAppDetector.DetectedApp]
    func refreshApps() async -> [MeetingAppDetector.DetectedApp]
}

// MARK: - PermissionManagerProtocol

/// Protocol for PermissionManager to enable mocking in tests
@MainActor
protocol PermissionManagerProtocol {
    var hasScreenRecordingPermission: Bool { get }
    var hasMicrophonePermission: Bool { get }
    var isMicrophonePermissionDenied: Bool { get }
    var hasAllPermissions: Bool { get }
    
    func checkScreenRecordingPermissionAsync() async -> Bool
    func requestScreenRecordingPermission()
    func openScreenRecordingSettings()
    func requestMicrophonePermission() async -> Bool
    func openMicrophoneSettings()
    func refreshPermissions() -> (screenRecording: Bool, microphone: Bool)
    
    // Event-driven permission detection methods
    func markAwaitingScreenRecordingFromSettings()
    func markAwaitingMicrophoneFromSettings()
    func verifyScreenRecordingAfterRequest() async -> Bool
}

// MARK: - MicrophoneManagerProtocol

/// Protocol for MicrophoneManager to enable mocking in tests
@MainActor
protocol MicrophoneManagerProtocol {
    var availableDevices: [MicrophoneManager.MicrophoneDevice] { get }
    var selectedDeviceID: String? { get }
    var currentDefaultDevice: MicrophoneManager.MicrophoneDevice? { get }
    
    func setSelectedDeviceID(_ deviceID: String?)
    func refreshDevices()
    func device(withID deviceID: String) -> MicrophoneManager.MicrophoneDevice?
}

// MARK: - ModelManagerProtocol

/// Protocol for ModelManager to enable mocking in tests
@MainActor
protocol ModelManagerProtocol: AnyObject {
    var downloadStates: [ModelManager.ModelSize: ModelManager.DownloadState] { get }
    var downloadedModels: Set<ModelManager.ModelSize> { get }
    var activeModel: ModelManager.ModelSize? { get }
    var modelPath: URL? { get }
    var hasModel: Bool { get }
    var modelDirectory: URL { get }
    
    func pathForModel(_ model: ModelManager.ModelSize) -> URL?
    func isModelDownloaded(_ model: ModelManager.ModelSize) -> Bool
    func validateModel(_ model: ModelManager.ModelSize) -> Bool
    func getFirstValidModel() -> ModelManager.ModelSize?
    func markModelCorrupted(_ model: ModelManager.ModelSize)
    func downloadState(for model: ModelManager.ModelSize) -> ModelManager.DownloadState
    func scanForDownloadedModels()
    func downloadModel(_ model: ModelManager.ModelSize) async
    func setActiveModel(_ model: ModelManager.ModelSize)
    func deleteModel(_ model: ModelManager.ModelSize) -> Bool
    func showModelsInFinder()
    func reset()
}

// MARK: - LLMManagerProtocol

/// Protocol for LLMManager to enable mocking in tests
@MainActor
protocol LLMManagerProtocol: AnyObject {
    var downloadStates: [LLMManager.LLMModel: LLMManager.DownloadState] { get }
    var downloadedModels: Set<LLMManager.LLMModel> { get }
    var activeModel: LLMManager.LLMModel? { get }
    var hasModel: Bool { get }
    var isLLMAvailable: Bool { get }
    var isMLXAvailable: Bool { get }
    var isLLMStitchingEnabled: Bool { get set }
    // Note: modelContainer is not in protocol as it's an implementation detail (type-specific)
    
    func pathForModel(_ model: LLMManager.LLMModel) -> URL?
    func isModelDownloaded(_ model: LLMManager.LLMModel) -> Bool
    func downloadState(for model: LLMManager.LLMModel) -> LLMManager.DownloadState
    func scanForDownloadedModels()
    func downloadModel(_ model: LLMManager.LLMModel) async
    func loadModel(_ model: LLMManager.LLMModel) async throws
    func unloadModel()
    func setActiveModel(_ model: LLMManager.LLMModel)
    func deleteModel(_ model: LLMManager.LLMModel) -> Bool
    func showModelsInFinder()
    func reset()
}

// MARK: - EchoCancellationServiceProtocol

/// Protocol for EchoCancellationService to enable mocking in tests
/// Uses sample-count synchronization instead of timestamps to avoid clock domain mismatch
protocol EchoCancellationServiceProtocol: Sendable {
    func storeSystemAudio(samples: [Float])
    func processMicrophoneAudio(microphoneSamples: [Float]) -> [Float]
    func reset()
    func startDriftMonitoring()
}

extension EchoCancellationServiceProtocol {
    /// Default no-op implementation for drift monitoring
    func startDriftMonitoring() { /* default no-op */ }
}

// MARK: - ExportServiceProtocol

/// Protocol for ExportService to enable mocking in tests
@MainActor
protocol ExportServiceProtocol {
    var exportDirectory: URL { get }
    
    func setExportDirectory(_ url: URL)
    func resetToDefaultExportDirectory()
    func exportMeeting(_ meeting: MeetingHistoryItem) async throws
    func exportAllMeetings(_ meetings: [MeetingHistoryItem]) async throws -> Int
    func generateManifest(for meetings: [MeetingHistoryItem]) throws
    func createVersionMarker() throws
}
