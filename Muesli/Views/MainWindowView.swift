import SwiftUI

/// Main window view that conditionally shows unified list or split view
struct MainWindowView: View {
    @Bindable var viewModel: MuesliViewModel
    @Environment(MeetingHistoryManager.self) private var historyManager
    
    /// Show split view when a meeting is selected OR recording is active
    /// Show unified list otherwise (idle state)
    private var shouldShowSplitView: Bool {
        let result = historyManager.selectedMeeting != nil || viewModel.activeRecordingSession != nil || viewModel.isSplitViewVisible
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let logEntry = "{\"location\":\"MainWindowView.swift:shouldShowSplitView\",\"message\":\"Checking split view state\",\"data\":{\"historyMgrSelectedMeeting\":\"\(historyManager.selectedMeeting?.title ?? "nil")\",\"vmSelectedMeeting\":\"\(viewModel.selectedMeeting?.title ?? "nil")\",\"activeSession\":\(viewModel.activeRecordingSession != nil),\"isSplitViewVisible\":\(viewModel.isSplitViewVisible),\"result\":\(result)},\"timestamp\":\(Date().timeIntervalSince1970 * 1000),\"sessionId\":\"debug-session\",\"hypothesisId\":\"A\"}\n"
        if let handle = FileHandle(forWritingAtPath: logPath) { handle.seekToEndOfFile(); handle.write(logEntry.data(using: .utf8)!); handle.closeFile() } else { FileManager.default.createFile(atPath: logPath, contents: logEntry.data(using: .utf8), attributes: nil) }
        // #endregion
        return result
    }
    
    var body: some View {
        Group {
            if shouldShowSplitView {
                splitView
                    .frame(minWidth: 750, idealWidth: 900, minHeight: 500, idealHeight: 650)
            } else {
                unifiedView
                    .frame(minWidth: 420, maxWidth: 420, minHeight: 400, idealHeight: 600)
            }
        }
        // .overlay(alignment: .topTrailing) {
        //     WorkTreeBadge()
        // }
        .sheet(isPresented: Binding(
            get: { viewModel.showStartRecordingSheet },
            set: { viewModel.showStartRecordingSheet = $0 }
        )) {
            StartRecordingSheet(viewModel: viewModel, isPresented: Binding(
                get: { viewModel.showStartRecordingSheet },
                set: { viewModel.showStartRecordingSheet = $0 }
            ))
        }
        .alert("Unable to Load Transcription Model", isPresented: $viewModel.showModelErrorAlert) {
            Button("Recording Only") {
                viewModel.startRecordingWithoutTranscription()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelRecordingDueToModelError()
            }
        } message: {
            Text("The transcription model is corrupted or incomplete. You can continue recording audio only (no transcription), or cancel and download a working model in Preferences.")
        }
    }
    
    // MARK: - Unified View
    
    private var unifiedView: some View {
        UnifiedHistoryView(viewModel: viewModel)
    }
    
    // MARK: - Split View
    
    private var splitView: some View {
        NavigationSplitView {
            MeetingHistorySidebar(viewModel: viewModel)
        } detail: {
            RecordingDetailView(viewModel: viewModel)
        }
    }
}

#Preview("Unified") {
    let vm = MuesliViewModel()
    let historyManager = MeetingHistoryManager()
    return MainWindowView(viewModel: vm)
        .environment(historyManager)
        .frame(width: 420, height: 600)
}

#Preview("Split") {
    let vm = MuesliViewModel()
    let historyManager = MeetingHistoryManager()
    vm.isSplitViewVisible = true
    return MainWindowView(viewModel: vm)
        .environment(historyManager)
        .frame(width: 900, height: 650)
}
