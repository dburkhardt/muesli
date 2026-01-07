import Foundation
import AVFoundation

/// Service responsible for discovering and loading meeting recordings from disk
final class MeetingHistoryService {
    
    // MARK: - Properties
    
    private let fileManager = FileManager.default
    
    private static var baseOutputPath: URL {
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("Meeting Transcripts", isDirectory: true)
    }
    
    // MARK: - Discovery
    
    /// Discover all meeting recordings from disk
    /// - Returns: Array of meeting history items, sorted newest first
    @MainActor
    func discoverMeetings() -> [MeetingHistoryItem] {
        let basePath = Self.baseOutputPath
        
        // Check if base directory exists
        guard fileManager.fileExists(atPath: basePath.path) else {
            return []
        }
        
        // Get all subdirectories
        guard let contents = try? fileManager.contentsOfDirectory(
            at: basePath,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var meetings: [MeetingHistoryItem] = []
        
        for directory in contents {
            // Skip if not a directory
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            
            // Parse meeting from directory
            if let meeting = parseMeeting(from: directory) {
                meetings.append(meeting)
            }
        }
        
        // Sort by date, newest first
        meetings.sort { $0.date > $1.date }
        
        return meetings
    }
    
    /// Parse a meeting from a directory URL
    /// - Parameter directory: The directory URL containing the meeting files
    /// - Returns: MeetingHistoryItem if valid, nil otherwise
    @MainActor
    private func parseMeeting(from directory: URL) -> MeetingHistoryItem? {
        // Check for transcript.md file
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        guard fileManager.fileExists(atPath: transcriptURL.path) else {
            return nil
        }
        
        // Parse date from folder name: YYYY-MM-DD_HH-MM_[UUID]
        let folderName = directory.lastPathComponent
        let date = parseDate(from: folderName) ?? getDirectoryCreationDate(directory)
        
        // Read transcript.md to extract title and date
        var title = "Meeting"
        var transcriptDate = date
        
        if let transcriptContent = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            let lines = transcriptContent.components(separatedBy: .newlines)
            
            // Extract title from first line (should be # Title)
            if let firstLine = lines.first, firstLine.hasPrefix("# ") {
                title = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if title.isEmpty {
                    title = "Meeting"
                }
            }
            
            // Extract date from second line if present (format: YYYY-MM-DD HH:mm)
            if lines.count > 1 {
                let secondLine = lines[1].trimmingCharacters(in: .whitespaces)
                if let parsedDate = parseTranscriptDate(secondLine) {
                    transcriptDate = parsedDate
                }
            }
        }
        
        // Check for audio files
        let audioURL = directory.appendingPathComponent("audio.caf")
        let micURL = directory.appendingPathComponent("microphone.caf")
        let hasAudio = fileManager.fileExists(atPath: audioURL.path)
        let hasMicrophone = fileManager.fileExists(atPath: micURL.path)
        
        // Compute duration from audio file
        let duration = getAudioDuration(audioURL: hasAudio ? audioURL : (hasMicrophone ? micURL : nil))
        
        // Compute word count from transcript
        let wordCount = getWordCount(transcriptURL: transcriptURL)
        
        // Generate ID from folder name (use UUID part if present, otherwise hash)
        let id = extractUUID(from: folderName) ?? UUID()
        
        return MeetingHistoryItem(
            id: id,
            title: title,
            date: transcriptDate,
            directory: directory,
            transcript: nil, // Lazy-loaded
            hasAudio: hasAudio,
            hasMicrophone: hasMicrophone,
            duration: duration,
            wordCount: wordCount
        )
    }
    
    /// Parse date from folder name format: YYYY-MM-DD_HH-MM_[UUID]
    private func parseDate(from folderName: String) -> Date? {
        // Format: YYYY-MM-DD_HH-MM_[UUID]
        // Extract: YYYY-MM-DD_HH-MM
        let components = folderName.components(separatedBy: "_")
        guard components.count >= 2 else { return nil }
        
        let datePart = components[0] // YYYY-MM-DD
        let timePart = components[1] // HH-MM
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm"
        
        return dateFormatter.date(from: "\(datePart)_\(timePart)")
    }
    
    /// Parse date from transcript.md second line format: YYYY-MM-DD HH:mm
    private func parseTranscriptDate(_ dateString: String) -> Date? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        return dateFormatter.date(from: dateString)
    }
    
    /// Extract UUID from folder name
    private func extractUUID(from folderName: String) -> UUID? {
        // Format: YYYY-MM-DD_HH-MM_[UUID]
        let components = folderName.components(separatedBy: "_")
        guard components.count >= 3 else { return nil }
        
        let uuidString = components[2]
        return UUID(uuidString: uuidString)
    }
    
    /// Get directory creation date as fallback
    private func getDirectoryCreationDate(_ directory: URL) -> Date {
        if let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
           let creationDate = attributes[.creationDate] as? Date {
            return creationDate
        }
        return Date()
    }
    
    // MARK: - Duration and Word Count
    
    /// Get audio duration from file
    /// - Parameter audioURL: URL to audio file, or nil if no audio
    /// - Returns: Duration in seconds, or nil if unavailable
    private func getAudioDuration(audioURL: URL?) -> TimeInterval? {
        guard let audioURL = audioURL, fileManager.fileExists(atPath: audioURL.path) else {
            return nil
        }
        
        let asset = AVAsset(url: audioURL)
        let duration = CMTimeGetSeconds(asset.duration)
        
        // Return nil for invalid durations
        guard duration.isFinite && duration > 0 else {
            return nil
        }
        
        return duration
    }
    
    /// Get word count from transcript file
    /// - Parameter transcriptURL: URL to transcript.md file
    /// - Returns: Word count, or nil if unavailable
    private func getWordCount(transcriptURL: URL) -> Int? {
        guard let content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return nil
        }
        
        // Extract just the transcript section (skip header/metadata)
        let lines = content.components(separatedBy: .newlines)
        var transcriptLines: [String] = []
        var inTranscriptSection = false
        
        for line in lines {
            if line.hasPrefix("## Transcript") {
                inTranscriptSection = true
                continue
            }
            if inTranscriptSection {
                transcriptLines.append(line)
            }
        }
        
        let transcriptText = transcriptLines.joined(separator: " ")
        
        // Count words (split by whitespace and filter empty)
        let words = transcriptText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        return words.isEmpty ? nil : words.count
    }
    
    // MARK: - Transcript Loading
    
    /// Load transcript content for a meeting (plain text format)
    /// - Parameter meeting: The meeting to load transcript for
    /// - Returns: Transcript text, or nil if not found
    func loadTranscript(for meeting: MeetingHistoryItem) -> String? {
        let transcriptURL = meeting.directory.appendingPathComponent("transcript.md")
        
        guard let content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return nil
        }
        
        // Extract just the transcript section (skip header)
        let lines = content.components(separatedBy: .newlines)
        var transcriptLines: [String] = []
        var inTranscriptSection = false
        
        for line in lines {
            if line.hasPrefix("## Transcript") {
                inTranscriptSection = true
                continue
            }
            if inTranscriptSection {
                transcriptLines.append(line)
            }
        }
        
        let transcript = transcriptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? nil : transcript
    }
    
    /// Load transcript blocks for a meeting (block format)
    /// Parses the markdown format back into TranscriptBlock objects
    /// - Parameter meeting: The meeting to load transcript blocks for
    /// - Returns: Array of transcript blocks, or nil if not found or legacy format
    func loadTranscriptBlocks(for meeting: MeetingHistoryItem) -> [TranscriptBlock]? {
        let transcriptURL = meeting.directory.appendingPathComponent("transcript.md")
        
        guard let content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return nil
        }
        
        // Extract just the transcript section (skip header)
        let lines = content.components(separatedBy: .newlines)
        var transcriptLines: [String] = []
        var inTranscriptSection = false
        
        for line in lines {
            if line.hasPrefix("## Transcript") {
                inTranscriptSection = true
                continue
            }
            if inTranscriptSection {
                transcriptLines.append(line)
            }
        }
        
        // Parse blocks from the format:
        // **Me** _[0:15]_
        //
        // Block text here...
        //
        // **Them** _[1:30]_
        //
        // Their block text here...
        
        var blocks: [TranscriptBlock] = []
        var currentSpeaker: TranscriptBlock.Speaker?
        var currentTimestamp: TimeInterval = 0
        var currentTextLines: [String] = []
        
        let speakerPattern = #"^\*\*(Me|Them)\*\* _\[(\d+):(\d+)(?::(\d+))?\]_$"#
        let speakerRegex = try? NSRegularExpression(pattern: speakerPattern, options: [])
        
        for line in transcriptLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Check if this is a speaker header line
            if let match = speakerRegex?.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
               let speakerRange = Range(match.range(at: 1), in: trimmed) {
                
                // Save previous block if any
                if let speaker = currentSpeaker, !currentTextLines.isEmpty {
                    let text = currentTextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let block = TranscriptBlock(
                            id: UUID(),
                            speaker: speaker,
                            text: text,
                            startTimestamp: currentTimestamp,
                            endTimestamp: currentTimestamp // Will be updated on next block
                        )
                        blocks.append(block)
                    }
                    currentTextLines = []
                }
                
                // Parse new speaker and timestamp
                let speakerStr = String(trimmed[speakerRange])
                currentSpeaker = speakerStr == "Me" ? .me : .them
                
                // Parse timestamp (handles both M:SS and H:MM:SS formats)
                if let firstRange = Range(match.range(at: 2), in: trimmed),
                   let secondRange = Range(match.range(at: 3), in: trimmed) {
                    let first = Int(trimmed[firstRange]) ?? 0
                    let second = Int(trimmed[secondRange]) ?? 0
                    
                    // Check for hours (optional 4th group)
                    if match.range(at: 4).location != NSNotFound,
                       let thirdRange = Range(match.range(at: 4), in: trimmed) {
                        // Format: H:MM:SS
                        let third = Int(trimmed[thirdRange]) ?? 0
                        currentTimestamp = TimeInterval(first * 3600 + second * 60 + third)
                    } else {
                        // Format: M:SS
                        currentTimestamp = TimeInterval(first * 60 + second)
                    }
                }
                
            } else if !trimmed.isEmpty {
                // Add to current block's text
                currentTextLines.append(line)
            }
        }
        
        // Save final block if any
        if let speaker = currentSpeaker, !currentTextLines.isEmpty {
            let text = currentTextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let block = TranscriptBlock(
                    id: UUID(),
                    speaker: speaker,
                    text: text,
                    startTimestamp: currentTimestamp,
                    endTimestamp: currentTimestamp
                )
                blocks.append(block)
            }
        }
        
        // Update endTimestamps based on next block's start
        // Use indices.dropLast() for safe iteration (handles empty arrays correctly)
        for i in blocks.indices.dropLast() {
            blocks[i].endTimestamp = blocks[i + 1].startTimestamp
        }
        
        return blocks.isEmpty ? nil : blocks
    }
}
