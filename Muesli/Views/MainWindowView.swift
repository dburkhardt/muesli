import SwiftUI

/// Main window view — always shows sidebar + detail split view
struct MainWindowView: View {
    @Bindable var viewModel: MuesliViewModel
    @Environment(MeetingHistoryManager.self) private var historyManager
    
    var body: some View {
        NavigationSplitView {
            MeetingHistorySidebar(viewModel: viewModel)
        } detail: {
            RecordingDetailView(viewModel: viewModel)
        }
        .frame(minWidth: 900, minHeight: 650)
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
            Text(
                """
                The transcription model is corrupted or incomplete. You can continue recording audio only \
                (no transcription), or cancel and download a working model in Preferences.
                """
            )
        }
    }
}

#Preview {
    let vm = MuesliViewModel()
    let historyManager = MeetingHistoryManager()
    return MainWindowView(viewModel: vm)
        .environment(historyManager)
        .frame(width: 900, height: 650)
}
