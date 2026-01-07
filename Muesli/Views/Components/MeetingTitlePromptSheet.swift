import SwiftUI

/// Sheet prompting user to enter a meeting title before saving
/// Shown when stopping a recording with an empty title
struct MeetingTitlePromptSheet: View {
    @Binding var isPresented: Bool
    @Binding var meetingTitle: String
    let onSave: () -> Void
    let onSkip: () -> Void
    let onDiscard: (() -> Void)?
    
    @State private var editingTitle: String = ""
    @State private var showDiscardConfirmation: Bool = false
    @FocusState private var isTitleFocused: Bool
    
    init(
        isPresented: Binding<Bool>,
        meetingTitle: Binding<String>,
        onSave: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onDiscard: (() -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self._meetingTitle = meetingTitle
        self.onSave = onSave
        self.onSkip = onSkip
        self.onDiscard = onDiscard
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
            editingTitle = meetingTitle
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
        meetingTitle = titleToSave.isEmpty ? "Meeting" : titleToSave
        isPresented = false
        onSave()
    }
    
    private func skipTitle() {
        meetingTitle = "Meeting"
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
        onSave: {},
        onSkip: {},
        onDiscard: {}
    )
}
