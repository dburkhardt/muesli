import SwiftUI

/// Unified list view showing all meetings with option to start recording
struct UnifiedHistoryView: View {
    @Bindable var viewModel: MuesliViewModel
    @Environment(MeetingHistoryManager.self) private var historyManager
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        @Bindable var history = historyManager
        
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Warning banners (if any active warnings)
                if viewModel.warningManager.hasActiveWarnings {
                    WarningBannerStack(
                        warnings: viewModel.warningManager.activeWarnings,
                        onDismiss: { id in
                            viewModel.warningManager.dismissWarning(id)
                        },
                        onCopy: { id in
                            viewModel.warningManager.copyWarningDetails(id)
                        }
                    )
                }
                
                // Header with title and start button
                headerView
                
                Divider()
                
                // Meeting list
                if historyManager.groupedHistory.isEmpty {
                    emptyStateView
                } else {
                    meetingListView
                }
            }
            
            // Floating download indicator (shown when model download in progress)
            DownloadIndicatorView(viewModel: viewModel)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onDeleteCommand {
            // Handle Delete key
            historyManager.requestDeleteSelectedMeetings()
        }
        .alert(
            "Delete Meeting\(historyManager.meetingsPendingDeletion.count > 1 ? "s" : "")?",
            isPresented: $history.showDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                historyManager.cancelDeleteMeetings()
            }
            Button("Delete", role: .destructive) {
                historyManager.confirmDeleteMeetings()
            }
        } message: {
            if historyManager.meetingsPendingDeletion.count == 1 {
                Text(
                    """
                    This will permanently delete \
                    "\(historyManager.meetingsPendingDeletion.first?.title ?? "Meeting")" and its audio files.
                    """
                )
            } else {
                Text(
                    """
                    This will permanently delete \(historyManager.meetingsPendingDeletion.count) meetings \
                    and their audio files.
                    """
                )
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("Meetings")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.primary)
            
            Spacer()
            
            Button(
                action: {
                    // Quick start: immediately begin recording all system audio
                    viewModel.quickStartRecording()
                },
                label: {
                    HStack(spacing: 4) {
                        if !viewModel.modelManager.hasAnyReadyModel && viewModel.activeSession == nil {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                            Text("Preparing...")
                                .font(.system(size: 13, weight: .medium))
                        } else {
                            Text("New")
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            )
            .buttonStyle(.plain)
            .disabled(!viewModel.canStartRecording)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            
            Text("No meetings yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("Start your first recording to get started")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Meeting List
    
    private var meetingListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(historyManager.groupedHistory) { group in
                    // Group header
                    Text(group.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                    
                    // Meetings in group
                    ForEach(group.meetings) { meeting in
                        MeetingListItemView(
                            meeting: meeting,
                            isSelected: historyManager.selectedMeetingIDs.contains(meeting.id),
                            onSelect: { extendSelection in
                                handleMeetingClick(meeting, extendSelection: extendSelection)
                            },
                            onDoubleClick: {
                                handleMeetingDoubleClick(meeting)
                            },
                        onDelete: {
                            // If this meeting is part of a multi-selection, delete all selected
                            if historyManager.selectedMeetingIDs.contains(meeting.id) &&
                               historyManager.selectedMeetingIDs.count > 1 {
                                historyManager.requestDeleteSelectedMeetings()
                            } else {
                                    historyManager.requestDeleteMeeting(meeting)
                                }
                            },
                            onShiftClick: {
                                historyManager.selectMeetingsInRange(to: meeting)
                            }
                        )
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }
    
    // MARK: - Meeting Selection
    
    private func handleMeetingClick(_ meeting: MeetingHistoryItem, extendSelection: Bool) {
        if extendSelection {
            // Cmd+click: toggle multi-select
            historyManager.toggleMeetingSelection(meeting, extendSelection: true)
        } else {
            // Single click: show in detail pane immediately
            // Note: Setting selectedMeeting alone triggers split view via shouldShowSplitView
            // (which checks historyManager.selectedMeeting != nil)
            historyManager.selectMeeting(meeting)
        }
    }
    
    private func handleMeetingDoubleClick(_ meeting: MeetingHistoryItem) {
        // Double-click: always open in dedicated window
        openCompletedMeetingWindow(meeting)
    }
    
    private func openCompletedMeetingWindow(_ meeting: MeetingHistoryItem) {
        historyManager.completedMeetingWindowItem = meeting
        Task {
            await historyManager.loadTranscript(for: meeting)
        }
        openWindow(id: "completedMeeting")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Meeting List Item

struct MeetingListItemView: View {
    let meeting: MeetingHistoryItem
    let isSelected: Bool
    let onSelect: (Bool) -> Void  // Bool indicates if extending selection (Cmd+click)
    let onDoubleClick: () -> Void
    let onDelete: () -> Void
    var onShiftClick: () -> Void = {}
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "waveform")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            
            // Title and date
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                
                Text(formatDate(meeting.date))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Duration and word count
            if let metadataText = formattedMetadata {
                Text(metadataText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            
            // Delete button (shown on hover) or audio indicators
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete meeting")
            } else {
                // Audio indicators
                HStack(spacing: 4) {
                    if meeting.hasAudio {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if meeting.hasMicrophone {
                        Image(systemName: "mic")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            isSelected ? Color.accentColor.opacity(0.1) :
                (isHovered ? Color.secondary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            onDoubleClick()
        }
        .onTapGesture(count: 1) {
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.shift) {
                onShiftClick()
            } else {
                let extendSelection = modifiers.contains(.command)
                onSelect(extendSelection)
            }
        }
        .contextMenu {
            Button("Open") {
                onDoubleClick()
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    /// Formatted metadata string combining duration and word count
    private var formattedMetadata: String? {
        let parts = [meeting.formattedDuration, meeting.formattedWordCount].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#Preview {
    let vm = MuesliViewModel()
    let historyManager = MeetingHistoryManager()
    return UnifiedHistoryView(viewModel: vm)
        .environment(historyManager)
        .frame(width: 600, height: 800)
}
