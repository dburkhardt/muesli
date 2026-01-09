import SwiftUI

/// Sheet prompting user to enter a meeting title before saving
/// Shown when stopping a recording with an empty title
struct MeetingTitlePromptSheet: View {
    @Binding var isPresented: Bool
    @Binding var meetingTitle: String
    let recordingStartTime: Date?
    let onSave: () -> Void
    let onSkip: () -> Void
    let onDiscard: (() -> Void)?
    
    @State private var editingTitle: String = ""
    @State private var showDiscardConfirmation: Bool = false
    @FocusState private var isTitleFocused: Bool
    
    init(
        isPresented: Binding<Bool>,
        meetingTitle: Binding<String>,
        recordingStartTime: Date? = nil,
        onSave: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onDiscard: (() -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self._meetingTitle = meetingTitle
        self.recordingStartTime = recordingStartTime
        self.onSave = onSave
        self.onSkip = onSkip
        self.onDiscard = onDiscard
    }
    
    /// Generate suggested title based on recording start time
    private var suggestedTitle: String {
        let date = recordingStartTime ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        let dateString = formatter.string(from: date)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mma"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        let timeString = timeFormatter.string(from: date).lowercased()
        
        return "Meeting - \(dateString) at \(timeString)"
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                
                Text("Name Your Recording")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text("Give your meeting a name to find it later")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            
            // Title text field
            VStack(alignment: .leading, spacing: 8) {
                Text("Meeting Title")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                
                TextField("e.g., Team Standup, Client Call", text: $editingTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($isTitleFocused)
                    .onSubmit {
                        saveTitle()
                    }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Buttons
            VStack(spacing: 12) {
                // Primary actions - centered
                HStack(spacing: 16) {
                    Button("Skip") {
                        skipTitle()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    
                    Button("Save") {
                        saveTitle()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                
                // Discard option - subtle, at bottom
                if onDiscard != nil {
                    Button("Discard Recording") {
                        showDiscardConfirmation = true
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.8))
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: 400, height: 320)
        .onAppear {
            // Pre-populate with suggested title if meeting title is empty
            if meetingTitle.isEmpty {
                editingTitle = suggestedTitle
            } else {
                editingTitle = meetingTitle
            }
            isTitleFocused = true
        }
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                discardRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio and transcript will be permanently deleted.")
        }
    }
    
    // MARK: - Actions
    
    private func saveTitle() {
        let titleToSave = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Use suggested title if field is empty or unchanged from suggestion
        if titleToSave.isEmpty {
            meetingTitle = suggestedTitle
        } else {
            meetingTitle = titleToSave
        }
        isPresented = false
        onSave()
    }
    
    private func skipTitle() {
        // Use suggested title instead of generic "Meeting"
        meetingTitle = suggestedTitle
        isPresented = false
        onSkip()
    }
    
    private func discardRecording() {
        isPresented = false
        onDiscard?()
    }
}

#Preview {
    MeetingTitlePromptSheet(
        isPresented: .constant(true),
        meetingTitle: .constant(""),
        recordingStartTime: Date(),
        onSave: {},
        onSkip: {},
        onDiscard: {}
    )
}
