import AppKit
import Foundation

/// Utility for copying transcript content to system clipboard
enum ClipboardHelper {
    /// Copy text to clipboard
    /// - Parameter text: The text to copy
    /// - Returns: True if successful
    @discardableResult
    static func copyToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    
    /// Format transcript blocks as plain text (no markdown)
    /// - Parameter blocks: Array of transcript blocks
    /// - Returns: Plain text representation
    static func formatAsPlainText(_ blocks: [TranscriptBlock]) -> String {
        var output: [String] = []
        
        for block in blocks {
            // Format timestamp as HH:MM:SS or MM:SS
            let timestamp = TimeFormatting.formatTimestamp(block.startTimestamp, style: .standard)
            
            // Format speaker
            let speaker: String
            switch block.speaker {
            case .me:
                speaker = "Me"
            case .them:
                speaker = "Them"
            }
            
            // Build plain text line
            output.append("[\(timestamp)] \(speaker): \(block.text)")
        }
        
        return output.joined(separator: "\n")
    }
    
    /// Format transcript blocks as markdown (preserves formatting)
    /// - Parameter blocks: Array of transcript blocks
    /// - Returns: Markdown representation
    static func formatAsMarkdown(_ blocks: [TranscriptBlock]) -> String {
        var output: [String] = []
        
        for block in blocks {
            // Format timestamp as HH:MM:SS or MM:SS
            let timestamp = TimeFormatting.formatTimestamp(block.startTimestamp, style: .standard)
            
            // Format speaker
            let speaker: String
            switch block.speaker {
            case .me:
                speaker = "**Me**"
            case .them:
                speaker = "**Them**"
            }
            
            // Build markdown line
            output.append("**[\(timestamp)]** \(speaker): \(block.text)")
        }
        
        return output.joined(separator: "\n\n")
    }
    
    /// Copy transcript blocks as plain text
    /// - Parameter blocks: Array of transcript blocks
    /// - Returns: True if successful
    @discardableResult
    static func copyTranscriptAsPlainText(_ blocks: [TranscriptBlock]) -> Bool {
        let text = formatAsPlainText(blocks)
        return copyToClipboard(text)
    }
    
    /// Copy transcript blocks as markdown
    /// - Parameter blocks: Array of transcript blocks
    /// - Returns: True if successful
    @discardableResult
    static func copyTranscriptAsMarkdown(_ blocks: [TranscriptBlock]) -> Bool {
        let text = formatAsMarkdown(blocks)
        return copyToClipboard(text)
    }
}
