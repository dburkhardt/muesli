import SwiftUI

/// Sidebar showing meeting history with active recording indicator
struct MeetingHistorySidebar: View {
    @Bindable var viewModel: MuesliViewModel
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Content
            if viewModel.groupedHistory.isEmpty && viewModel.activeRecordingSession == nil {
                emptyStateView
            } else {
                meetingListView
            }
        }
        .frame(minWidth: 200, idealWidth: 250)
        .background(.background)
        .onDeleteCommand {
            // Handle Delete key
            viewModel.requestDeleteSelectedMeetings()
        }
        .alert("Delete Meeting\(viewModel.meetingsPendingDeletion.count > 1 ? "s" : "")?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelDeleteMeetings()
            }
            Button("Delete", role: .destructive) {
                viewModel.confirmDeleteMeetings()
            }
        } message: {
            if viewModel.meetingsPendingDeletion.count == 1 {
                Text("This will permanently delete \"\(viewModel.meetingsPendingDeletion.first?.title ?? "Meeting")\" and its audio files.")
            } else {
                Text("This will permanently delete \(viewModel.meetingsPendingDeletion.count) meetings and their audio files.")
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("Meetings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            
            Spacer()
            
            Button(action: {
                // Quick start: immediately begin recording all system audio
                viewModel.quickStartRecording()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.activeSession != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()
            
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            
            Text("No meetings")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Meeting List
    
    private var meetingListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Active recording section (if recording)
                if let activeSession = viewModel.activeRecordingSession {
                    Section {
                        ActiveRecordingItemView(
                            session: activeSession,
                            isSelected: viewModel.selectedMeeting == nil && viewModel.activeRecordingSession != nil,
                            onTap: {
                                // Clear selected meeting to show live recording
                                viewModel.selectedMeeting = nil
                                viewModel.selectedMeetingIDs.removeAll()
                            }
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    } header: {
                        Text("Now Recording")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }
                    
                    Divider()
                        .padding(.vertical, 8)
                }
                
                // Historical meetings grouped by date
                ForEach(viewModel.groupedHistory) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            MeetingSidebarItemView(
                                meeting: meeting,
                                isSelected: viewModel.selectedMeetingIDs.contains(meeting.id),
                                onSelect: { extendSelection in
                                    handleMeetingClick(meeting, extendSelection: extendSelection)
                                },
                                onDoubleClick: {
                                    handleMeetingDoubleClick(meeting)
                                },
                                onDelete: {
                                    // If this meeting is part of a multi-selection, delete all selected
                                    if viewModel.selectedMeetingIDs.contains(meeting.id) && viewModel.selectedMeetingIDs.count > 1 {
                                        viewModel.requestDeleteSelectedMeetings()
                                    } else {
                                        viewModel.requestDeleteMeeting(meeting)
                                    }
                                },
                                onShiftClick: {
                                    viewModel.selectMeetingsInRange(to: meeting)
                                }
                            )
                        }
                    } header: {
                        Text(group.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }
    
    // MARK: - Meeting Selection
    
    private func handleMeetingClick(_ meeting: MeetingHistoryItem, extendSelection: Bool) {
        if extendSelection {
            // Cmd+click: toggle multi-select
            viewModel.toggleMeetingSelection(meeting, extendSelection: true)
        } else {
            // Single click: show in detail pane immediately
            viewModel.selectedMeeting = meeting
            viewModel.selectedMeetingIDs = [meeting.id]
            viewModel.loadTranscript(for: meeting)
        }
    }
    
    private func handleMeetingDoubleClick(_ meeting: MeetingHistoryItem) {
        // Double-click: always open in dedicated window
        openCompletedMeetingWindow(meeting)
    }
    
    private func openCompletedMeetingWindow(_ meeting: MeetingHistoryItem) {
        viewModel.completedMeetingWindowItem = meeting
        viewModel.loadTranscript(for: meeting)
        openWindow(id: "completedMeeting")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Active Recording Item

struct ActiveRecordingItemView: View {
    let session: RecordingSession
    var isSelected: Bool = false
    var onTap: () -> Void = {}
    
    var body: some View {
        HStack(spacing: 8) {
            // Recording indicator
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            
            // Title
            Text(session.meetingTitle.isEmpty ? "Recording..." : session.meetingTitle)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            // Time
            Text(session.elapsedTimeString)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.red.opacity(isSelected ? 0.2 : 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

// MARK: - Meeting Sidebar Item

struct MeetingSidebarItemView: View {
    let meeting: MeetingHistoryItem
    let isSelected: Bool
    let onSelect: (Bool) -> Void  // Bool indicates if extending selection (Cmd+click)
    let onDoubleClick: () -> Void
    let onDelete: () -> Void
    var onShiftClick: () -> Void = {}
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Title
            Text(meeting.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            // Delete button (shown on hover)
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete meeting")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.secondary.opacity(0.05) : Color.clear))
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
}

#Preview {
    let vm = MuesliViewModel()
    return MeetingHistorySidebar(viewModel: vm)
        .frame(width: 250, height: 600)
}
