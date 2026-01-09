import Foundation
import SwiftUI

/// Represents a single recording session with its own state
/// Each window gets its own RecordingSession instance
@Observable
@MainActor
final class RecordingSession: Identifiable {
    
    // MARK: - Identity
    
    let id: UUID
    
    // MARK: - Session State
    
    enum SessionState: Equatable {
        case idle
        case recording
        case stopping
        case completed
    }
    
    var state: SessionState = .idle
    
    var isRecording: Bool {
        state == .recording
    }
    
    var isCompleted: Bool {
        state == .completed
    }
    
    // MARK: - Recording Data
    
    var meetingTitle: String = ""
    var transcriptText: String = ""
    var recordingStartTime: Date?
    var outputDirectory: URL?
    var selectedApp: MeetingAppDetector.DetectedApp?
    
    /// Description of the audio source for UI display
    var audioSourceDescription: String {
        selectedApp?.name ?? "All System Audio"
    }
    
    // MARK: - Transcript Blocks (for new block-based display)
    
    /// Merged transcript blocks for display (speaker-grouped, filtered)
    var transcriptBlocks: [TranscriptBlock] = []
    
    /// Processor for converting raw segments into blocks
    private let transcriptProcessor = TranscriptProcessor()
    
    // MARK: - Timer
    
    private var timerTick: Int = 0
    private var displayTimer: Timer?
    
    /// Formatted elapsed time since recording started
    var elapsedTimeString: String {
        // Access timerTick to create dependency for @Observable
        _ = timerTick
        guard let start = recordingStartTime else { return "00:00" }
        let elapsed = Date().timeIntervalSince(start)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    // MARK: - Error Handling
    
    var errorMessage: String?
    var showError: Bool = false
    
    // MARK: - Re-transcription State
    
    var isRetranscribing: Bool = false
    
    // MARK: - Microphone Mute State
    
    var isMicrophoneMuted: Bool = false
    
    // MARK: - Interruption State
    
    /// True if the recording was interrupted unexpectedly (e.g., captured app quit)
    var wasInterrupted: Bool = false
    
    /// Reason for interruption (for user display)
    var interruptionReason: String?
    
    // MARK: - Resume State
    
    /// Whether this session can be resumed after stopping
    var canResume: Bool = false
    
    /// Number of times recording has been resumed (0 = original recording, 1+ = resumed)
    var resumeCount: Int = 0
    
    /// Current segment number (1 = first segment, 2+ = resumed segments)
    var segmentNumber: Int = 1
    
    /// Reference to the MeetingHistoryItem this session belongs to (for resumed recordings)
    var parentMeeting: MeetingHistoryItem?
    
    // MARK: - Audio Level State
    
    /// Current microphone audio level (0.0 to 1.0)
    var microphoneLevel: Float = 0.0
    
    /// Current system audio level (0.0 to 1.0)
    var systemAudioLevel: Float = 0.0
    
    /// Check if re-transcription is available (audio files exist)
    var canRetranscribe: Bool {
        guard let directory = outputDirectory else { return false }
        let fileManager = FileManager.default
        let systemAudioPath = directory.appendingPathComponent("audio.caf").path
        let micAudioPath = directory.appendingPathComponent("microphone.caf").path
        return fileManager.fileExists(atPath: systemAudioPath) || fileManager.fileExists(atPath: micAudioPath)
    }
    
    // MARK: - Initialization
    
    init(id: UUID = UUID()) {
        self.id = id
    }
    
    // MARK: - Timer Management
    
    func startDisplayTimer() {
        stopDisplayTimer() // Ensure no duplicate timers
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.timerTick += 1
            }
        }
    }
    
    func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        timerTick = 0
    }
    
    // MARK: - Error Handling
    
    func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
    
    func dismissError() {
        showError = false
        errorMessage = nil
    }
    
    // MARK: - Output
    
    func openOutputFolder() {
        guard let directory = outputDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }
    
    // MARK: - Transcript
    
    /// Append a new transcript segment with speaker label and timestamp
    /// Also processes the segment into merged blocks for the new display
    func appendTranscriptSegment(_ segment: TranscriptionService.TranscriptSegment) {
        // Append to raw text (for file saving - keeps original format)
        let timestamp = formatTimestamp(segment.timestamp)
        let line = "[\(timestamp)] **\(segment.speaker.rawValue)**: \(segment.text)\n"
        transcriptText += line
        
        // Process into blocks (for new block-based display)
        transcriptProcessor.processSegment(segment)
        transcriptBlocks = transcriptProcessor.blocks
    }
    
    /// Finalize transcript processing (call when recording ends)
    func finalizeTranscript() {
        transcriptProcessor.finalize()
        transcriptBlocks = transcriptProcessor.blocks
    }
    
    /// Get formatted transcript text for file output (merged block format)
    func formattedTranscriptForFile() -> String {
        let title = meetingTitle.isEmpty ? "Meeting" : meetingTitle
        let date = recordingStartTime ?? Date()
        return transcriptProcessor.formattedTranscript(title: title, date: date)
    }
    
    /// Reset transcript state
    func resetTranscript() {
        transcriptText = ""
        transcriptBlocks = []
        transcriptProcessor.reset()
    }
    
    /// Format a timestamp as MM:SS
    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
