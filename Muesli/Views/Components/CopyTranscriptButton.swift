import SwiftUI

/// Reusable component for copying transcript content to clipboard
/// Provides both plain text and markdown export options with visual feedback
struct CopyTranscriptButton: View {
    /// Closure that returns transcript blocks to copy, or nil if unavailable
    let getBlocks: () -> [TranscriptBlock]?
    
    /// Optional custom help text
    let helpText: String
    
    /// Show temporary confirmation feedback
    @State private var showConfirmation = false
    
    init(getBlocks: @escaping () -> [TranscriptBlock]?, helpText: String = "Copy transcript to clipboard") {
        self.getBlocks = getBlocks
        self.helpText = helpText
    }
    
    var body: some View {
        Menu {
            Button("Copy as Plain Text") {
                if let blocks = getBlocks() {
                    ClipboardHelper.copyTranscriptAsPlainText(blocks)
                    showCopyFeedback()
                }
            }
            
            Button("Copy as Markdown") {
                if let blocks = getBlocks() {
                    ClipboardHelper.copyTranscriptAsMarkdown(blocks)
                    showCopyFeedback()
                }
            }
        } label: {
            Image(systemName: showConfirmation ? "checkmark" : "doc.on.doc")
                .foregroundStyle(showConfirmation ? .green : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(getBlocks() == nil)
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
