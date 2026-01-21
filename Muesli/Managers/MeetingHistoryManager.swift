import Foundation
import os.log

/// Manages meeting history including discovery, selection, and deletion
/// Extracted from MuesliViewModel as part of the god object refactoring
@Observable
@MainActor
final class MeetingHistoryManager {
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "MeetingHistoryManager")
    
    // MARK: - Dependencies
    
    private let meetingHistoryService: MeetingHistoryService
    
    // MARK: - Meeting History
    
    /// All discovered meeting recordings
    var meetingHistory: [MeetingHistoryItem] = []
    
    /// Meeting history grouped by date
    var groupedHistory: [MeetingHistoryGroup] = []
    
    // MARK: - Selection State
    
    /// Currently selected meeting for viewing (single selection)
    var selectedMeeting: MeetingHistoryItem?
    
    /// Set of selected meeting IDs (for multi-select)
    var selectedMeetingIDs: Set<UUID> = []
    
    /// Computed property for selected meetings
    var selectedMeetings: [MeetingHistoryItem] {
        meetingHistory.filter { selectedMeetingIDs.contains($0.id) }
    }
    
    /// Whether any meetings are selected
    var hasSelection: Bool {
        !selectedMeetingIDs.isEmpty
    }
    
    // MARK: - Deletion State
    
    /// Whether to show delete confirmation dialog
    var showDeleteConfirmation: Bool = false
    
    /// Meetings pending deletion (after confirmation)
    var meetingsPendingDeletion: [MeetingHistoryItem] = []
    
    /// Error from most recent deletion attempt (nil if successful)
    var deletionError: String?
    
    // MARK: - Window State
    
    /// Meeting to show in completed meeting window
    var completedMeetingWindowItem: MeetingHistoryItem?
    
    // MARK: - Initialization
    
    /// Initialize the meeting history manager
    /// - Parameters:
    ///   - meetingHistoryService: Service for discovering meetings (injectable for testing)
    ///   - skipInitialLoad: If true, skips loading history from disk (for testing)
    init(meetingHistoryService: MeetingHistoryService = MeetingHistoryService(), skipInitialLoad: Bool = false) {
        self.meetingHistoryService = meetingHistoryService
        if !skipInitialLoad {
            loadMeetingHistory()
        }
    }
    
    deinit {
        logger.debug("Deallocating")
    }
    
    // MARK: - History Management
    
    /// Load meeting history from disk
    func loadMeetingHistory() {
        meetingHistory = meetingHistoryService.discoverMeetings()
        groupedHistory = groupMeetingsByDate(meetingHistory)
    }
    
    /// Refresh meeting history (call after recording completes)
    func refreshMeetingHistory() {
        loadMeetingHistory()
    }
    
    /// Group meetings by date: by day for last week, by month for older
    /// - Parameter meetings: Array of meetings to group
    /// - Returns: Array of groups, sorted newest first
    func groupMeetingsByDate(_ meetings: [MeetingHistoryItem]) -> [MeetingHistoryGroup] {
        guard !meetings.isEmpty else { return [] }
        
        let calendar = Calendar.current
        let now = Date()
        
        // Separate meetings into last 7 days and older
        var lastWeekMeetings: [MeetingHistoryItem] = []
        var olderMeetings: [MeetingHistoryItem] = []
        
        for meeting in meetings {
            let daysSince = calendar.dateComponents([.day], from: meeting.date, to: now).day ?? 0
            if daysSince < 7 {
                lastWeekMeetings.append(meeting)
            } else {
                olderMeetings.append(meeting)
            }
        }
        
        var groups: [MeetingHistoryGroup] = []
        
        // Group last week by day
        let lastWeekGroups = Dictionary(grouping: lastWeekMeetings) { meeting -> Date in
            calendar.startOfDay(for: meeting.date)
        }
        
        for (dayStart, dayMeetings) in lastWeekGroups.sorted(by: { $0.key > $1.key }) {
            let label = formatDayLabel(dayStart, relativeTo: now)
            groups.append(MeetingHistoryGroup(
                date: dayStart,
                label: label,
                meetings: dayMeetings.sorted { $0.date > $1.date }
            ))
        }
        
        // Group older meetings by month
        let monthGroups = Dictionary(grouping: olderMeetings) { meeting -> Date in
            let components = calendar.dateComponents([.year, .month], from: meeting.date)
            return calendar.date(from: components) ?? meeting.date
        }
        
        for (monthStart, monthMeetings) in monthGroups.sorted(by: { $0.key > $1.key }) {
            let label = formatMonthLabel(monthStart)
            groups.append(MeetingHistoryGroup(
                date: monthStart,
                label: label,
                meetings: monthMeetings.sorted { $0.date > $1.date }
            ))
        }
        
        return groups
    }
    
    /// Format a day label (Today, Yesterday, or date)
    private func formatDayLabel(_ date: Date, relativeTo now: Date) -> String {
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: date)
        }
    }
    
    /// Format a month label
    private func formatMonthLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
    
    // MARK: - Selection Management
    
    /// Toggle selection of a meeting
    func toggleMeetingSelection(_ meeting: MeetingHistoryItem, extendSelection: Bool = false) {
        if extendSelection {
            // Cmd+click: toggle individual selection
            if selectedMeetingIDs.contains(meeting.id) {
                selectedMeetingIDs.remove(meeting.id)
            } else {
                selectedMeetingIDs.insert(meeting.id)
            }
        } else {
            // Regular click: single selection
            selectedMeetingIDs = [meeting.id]
        }
        
        // Update selectedMeeting for detail view
        if selectedMeetingIDs.count == 1, let id = selectedMeetingIDs.first {
            selectedMeeting = meetingHistory.first { $0.id == id }
            if let meeting = selectedMeeting {
                Task {
                    await loadTranscript(for: meeting)
                }
            }
        } else {
            selectedMeeting = nil
        }
    }
    
    /// Select a single meeting (non-toggle)
    func selectMeeting(_ meeting: MeetingHistoryItem) {
        selectedMeeting = meeting
        selectedMeetingIDs = [meeting.id]
        Task {
            await loadTranscript(for: meeting)
        }
    }
    
    /// Select all meetings in a range (for Shift+click)
    func selectMeetingsInRange(to meeting: MeetingHistoryItem) {
        guard let lastSelectedID = selectedMeetingIDs.first,
              let lastIndex = meetingHistory.firstIndex(where: { $0.id == lastSelectedID }),
              let targetIndex = meetingHistory.firstIndex(where: { $0.id == meeting.id }) else {
            toggleMeetingSelection(meeting)
            return
        }
        
        let range = min(lastIndex, targetIndex)...max(lastIndex, targetIndex)
        for i in range {
            selectedMeetingIDs.insert(meetingHistory[i].id)
        }
    }
    
    /// Clear all selections
    func clearSelection() {
        selectedMeetingIDs.removeAll()
        selectedMeeting = nil
    }
    
    // MARK: - Transcript Loading
    
    /// Load transcript for a meeting (lazy-load, async to prevent UI blocking)
    func loadTranscript(for meeting: MeetingHistoryItem) async {
        guard meeting.transcript == nil && !meeting.isLoadingTranscript else { return }
        
        meeting.isLoadingTranscript = true

        let directory = meeting.directory
        
        // Both MeetingHistoryManager and MeetingHistoryService are @MainActor
        // Call the existing service instance
        let transcript = meetingHistoryService.loadTranscript(at: directory)
        let blocks = meetingHistoryService.loadTranscriptBlocks(at: directory)

        meeting.transcript = transcript
        if meeting.transcriptBlocks == nil {
            meeting.transcriptBlocks = blocks
        }

        meeting.isLoadingTranscript = false
    }
    
    // MARK: - Meeting Deletion
    
    /// Request deletion of selected meetings (shows confirmation)
    func requestDeleteSelectedMeetings() {
        let meetings = selectedMeetings
        guard !meetings.isEmpty else { return }
        meetingsPendingDeletion = meetings
        showDeleteConfirmation = true
    }
    
    /// Request deletion of a specific meeting (shows confirmation)
    func requestDeleteMeeting(_ meeting: MeetingHistoryItem) {
        meetingsPendingDeletion = [meeting]
        showDeleteConfirmation = true
    }
    
    /// Confirm and execute deletion
    func confirmDeleteMeetings() {
        let meetingsToDelete = meetingsPendingDeletion
        meetingsPendingDeletion = []
        showDeleteConfirmation = false
        deletionError = nil  // Clear any previous error
        
        // Delete from disk
        var failedMeetings: [String] = []
        for meeting in meetingsToDelete {
            do {
                try deleteMeetingFromDisk(meeting)
            } catch {
                failedMeetings.append("\(meeting.title): \(error.localizedDescription)")
            }
        }
        
        // Set error state if any deletions failed
        if !failedMeetings.isEmpty {
            deletionError = "Failed to delete:\n" + failedMeetings.joined(separator: "\n")
        }
        
        // Clear selection if deleted meetings were selected
        for meeting in meetingsToDelete {
            selectedMeetingIDs.remove(meeting.id)
            if selectedMeeting?.id == meeting.id {
                selectedMeeting = nil
            }
        }
        
        // Refresh history (will show remaining meetings including any that failed to delete)
        refreshMeetingHistory()
    }
    
    /// Cancel deletion
    func cancelDeleteMeetings() {
        meetingsPendingDeletion = []
        showDeleteConfirmation = false
    }
    
    /// Clear the deletion error state
    func clearDeletionError() {
        deletionError = nil
    }
    
    /// Delete a meeting's folder from disk
    /// - Throws: Any file system error that occurs during deletion
    private func deleteMeetingFromDisk(_ meeting: MeetingHistoryItem) throws {
        let fileManager = FileManager.default
        try fileManager.removeItem(at: meeting.directory)
    }
    
    // MARK: - Helper Methods
    
    /// Find a meeting by its directory URL
    func meeting(for directory: URL) -> MeetingHistoryItem? {
        meetingHistory.first { $0.directory == directory }
    }
    
    /// Add a newly created meeting to history
    func addMeeting(_ meeting: MeetingHistoryItem) {
        meetingHistory.insert(meeting, at: 0)
        groupedHistory = groupMeetingsByDate(meetingHistory)
    }
}
