import AppKit
import SwiftUI

/// Reusable component for copying transcript content to clipboard
/// Provides both plain text and markdown export options with visual feedback
struct CopyTranscriptButton: View {
    /// Closure that returns transcript blocks to copy, or nil if unavailable
    let getBlocks: () -> [TranscriptBlock]?
    
    /// Closure that returns plain text content when block rendering is unavailable
    let getText: () -> String?
    
    /// Optional custom help text
    let helpText: String
    
    /// Show temporary confirmation feedback
    @State private var showConfirmation = false
    
    init(
        getBlocks: @escaping () -> [TranscriptBlock]?,
        getText: @escaping () -> String? = { nil },
        helpText: String = "Copy transcript to clipboard"
    ) {
        self.getBlocks = getBlocks
        self.getText = getText
        self.helpText = helpText
    }
    
    var body: some View {
        Menu {
            Button("Copy as Plain Text") {
                if let blocks = getBlocks() {
                    ClipboardHelper.copyTranscriptAsPlainText(blocks)
                    showCopyFeedback()
                } else if let text = getText() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    showCopyFeedback()
                }
            }
            
            Button("Copy as Markdown") {
                if let blocks = getBlocks() {
                    ClipboardHelper.copyTranscriptAsMarkdown(blocks)
                    showCopyFeedback()
                } else if let text = getText() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    showCopyFeedback()
                }
            }
        } label: {
            Group {
                if showConfirmation {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12))
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(.blue)
            .padding(8)
            .background(Color.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .disabled(getBlocks() == nil && getText() == nil)
        .help(helpText)
    }
    
    /// Show temporary copy confirmation feedback
    private func showCopyFeedback() {
        showConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            showConfirmation = false
        }
    }
}
