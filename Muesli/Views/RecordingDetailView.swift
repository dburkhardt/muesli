import SwiftUI

/// Detail view showing active recording, completed recording, or historical meeting
struct RecordingDetailView: View {
    @Bindable var viewModel: MuesliViewModel
    
    var body: some View {
        Group {
            if let selectedMeeting = viewModel.selectedMeeting {
                // User is viewing a past meeting (possibly while recording)
                historicalMeetingViewWithIndicator(meeting: selectedMeeting)
            } else if let activeSession = viewModel.activeRecordingSession, !activeSession.isCompleted {
                // No selected meeting, show active recording
                activeRecordingView(session: activeSession)
            } else {
                emptyDetailView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .alert("Delete Meeting?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelDeleteMeetings()
            }
            Button("Delete", role: .destructive) {
                viewModel.confirmDeleteMeetings()
            }
        } message: {
            if let meeting = viewModel.meetingsPendingDeletion.first {
                Text("This will permanently delete \"\(meeting.title)\" and its audio files.")
            }
        }
        .sheet(isPresented: $viewModel.showTitlePromptSheet) {
            if let session = viewModel.pendingStopSession {
                MeetingTitlePromptSheet(
                    isPresented: $viewModel.showTitlePromptSheet,
                    meetingTitle: Binding(
                        get: { session.meetingTitle },
                        set: { session.meetingTitle = $0 }
                    ),
                    recordingStartTime: session.recordingStartTime,
                    onSave: {
                        viewModel.confirmStopRecording()
                    },
                    onSkip: {
                        viewModel.confirmStopRecording()
                    },
                    onDiscard: {
                        viewModel.discardRecording()
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.showRefineSheet) {
            RefineTranscriptSheet(
                isPresented: $viewModel.showRefineSheet,
                progress: viewModel.refinementService.progress,
                isRefining: viewModel.refinementService.isRefining,
                errorMessage: viewModel.refinementService.errorMessage,
                onCancel: {
                    viewModel.cancelRefinement()
                }
            )
        }
    }
    
    // MARK: - Active Recording View
    
    private func activeRecordingView(session: RecordingSession) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Header with title and recording indicator
                headerView(session: session)
                
                Divider()
                
                // Transcript content
                recordingContentView(session: session)
            }
            
            // Floating control bar at bottom
            floatingControlBar(session: session)
                .padding(.bottom, 16)
        }
    }
    
    // MARK: - Header
    
    private func headerView(session: RecordingSession) -> some View {
        HStack(spacing: 12) {
            // Title text field
            TextField("Meeting Title", text: Binding(
                get: { session.meetingTitle },
                set: { session.meetingTitle = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.primary)
            
            Spacer()
            
            // Recording indicator
            RecordingIndicator(elapsedTime: session.elapsedTimeString)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    
    // MARK: - Floating Control Bar
    
    private func floatingControlBar(session: RecordingSession) -> some View {
        HStack(spacing: 16) {
            // Microphone control with level indicator
            microphoneControl(session: session)
            
            // Settings menu (Live Transcript + Audio Source)
            settingsMenuControl(session: session)
            
            // Stop recording button
            stopRecordingButton(session: session)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        }
    }
    
    // MARK: - Microphone Control with Level
    
    private func microphoneControl(session: RecordingSession) -> some View {
        MicrophoneControlWithLevel(
            level: session.microphoneLevel,
            isRecording: session.isRecording,
            isMuted: session.isMicrophoneMuted,
            availableDevices: viewModel.microphoneManager.availableDevices,
            selectedDeviceID: viewModel.microphoneManager.selectedDeviceID,
            onToggleMute: {
                viewModel.toggleMicrophoneMute()
            },
            onSelectDevice: { deviceID in
                viewModel.microphoneManager.setSelectedDeviceID(deviceID)
            }
        )
    }
    
    // MARK: - Settings Menu Control (Gear icon with submenus)
    
    private func settingsMenuControl(session: RecordingSession) -> some View {
        Menu {
            // Submenu 1: Live Transcript
            Menu("Live Transcript") {
                Button(action: {
                    viewModel.transcriptionMode = .live
                }) {
                    HStack {
                        Text("Live")
                        if viewModel.transcriptionMode == .live {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                
                Button(action: {
                    viewModel.transcriptionMode = .postProcessing
                }) {
                    HStack {
                        Text("Post-processing")
                        if viewModel.transcriptionMode == .postProcessing {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            
            Divider()
            
            // Submenu 2: Audio Source (shows current, can change only when not recording)
            Menu("Audio Source") {
                // "All System Audio" option
                Button(action: {
                    if !session.isRecording {
                        session.selectedApp = nil
                    }
                }) {
                    HStack {
                        Text("All System Audio")
                        if session.selectedApp == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(session.isRecording)
                
                if !viewModel.availableMeetingApps.isEmpty {
                    Divider()
                    
                    // Detected apps
                    ForEach(viewModel.availableMeetingApps) { app in
                        Button(action: {
                            if !session.isRecording {
                                session.selectedApp = app
                            }
                        }) {
                            HStack {
                                Text(app.name)
                                if session.selectedApp?.bundleIdentifier == app.bundleIdentifier {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(session.isRecording)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .task {
            // Refresh available apps when menu appears
            await viewModel.refreshMeetingApps()
        }
    }
    
    // MARK: - Stop Recording Button
    
    private func stopRecordingButton(session: RecordingSession) -> some View {
        Button(action: {
            viewModel.stopRecording(for: session)
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.red))
        }
        .buttonStyle(.plain)
        .disabled(session.state == .stopping)
    }
    
    // MARK: - Recording Content
    
    private func recordingContentView(session: RecordingSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session.transcriptBlocks.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        
                        Image(systemName: "waveform")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        
                        Text("Listening...")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        Text("Transcript will appear here as you speak")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                    .padding(.bottom, 100) // Space for floating control bar
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(session.transcriptBlocks) { block in
                            TranscriptBlockView(block: block)
                                .id(block.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 100) // Space for floating control bar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: session.transcriptBlocks.count) { _, _ in
                // Auto-scroll to latest block
                if let lastBlock = session.transcriptBlocks.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastBlock.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    
    // MARK: - Completed Recording View
    
    private func completedRecordingView(session: RecordingSession) -> some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 12) {
                TextField("Meeting Title", text: Binding(
                    get: { session.meetingTitle },
                    set: { session.meetingTitle = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                
                Spacer()
                
                CompletedIndicator()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if session.transcriptText.isEmpty {
                        VStack(spacing: 16) {
                            Spacer()
                            
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.green)
                            
                            Text("Recording Saved!")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            
                            Text("audio.caf + microphone.caf + transcript.md")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            if let directory = session.outputDirectory {
                                Text(directory.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            
                            if session.isRetranscribing {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Re-transcribing with post-processing...")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 8)
                            }
                            
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        if session.isRetranscribing {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Re-transcribing with post-processing...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 8)
                        }
                        
                        Text(session.transcriptText)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            
            // Footer
            HStack(spacing: 12) {
                Spacer()
                
                if let directory = session.outputDirectory {
                    Button(action: {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
                    }) {
                        Text("Open in Finder")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                
                if session.canRetranscribe && !session.isRetranscribing {
                    Button(action: {
                        viewModel.retranscribeWithPostProcessing(for: session)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Re-transcribe")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
            }
            .padding(16)
        }
    }
    
    // MARK: - Historical Meeting View with Floating Indicator
    
    private func historicalMeetingViewWithIndicator(meeting: MeetingHistoryItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            historicalMeetingView(meeting: meeting)
            
            // Show floating indicator when there's an active recording
            if viewModel.isViewingPastMeetingWhileRecording,
               let activeSession = viewModel.activeRecordingSession {
                FloatingRecordingIndicator(
                    elapsedTime: activeSession.elapsedTimeString,
                    onTap: {
                        viewModel.returnToLiveRecording()
                    }
                )
                .padding(16)
            }
        }
    }
    
    // MARK: - Historical Meeting View
    
    private func historicalMeetingView(meeting: MeetingHistoryItem) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    TextField("Meeting Title", text: Binding(
                        get: { meeting.title },
                        set: { meeting.title = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    CompletedIndicator()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                Divider()
                
                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Metadata row with date, Open in Finder, and Delete
                        HStack(spacing: 8) {
                            Label(formatDate(meeting.date), systemImage: "calendar")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            
                            Button(action: {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: meeting.directory.path)
                            }) {
                                Text("Open in Finder")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.blue)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            
                            Button(action: {
                                viewModel.requestDeleteMeeting(meeting)
                            }) {
                                Text("Delete Recording")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            
                        }
                        .padding(.bottom, 8)
                        
                        // Show recording start time for resumable meetings
                        if meeting.canResume, let firstSegment = meeting.transcriptSegments.first {
                            Group {
                                let formatter: DateFormatter = {
                                    let f = DateFormatter()
                                    f.dateStyle = .medium
                                    f.timeStyle = .short
                                    return f
                                }()
                                Text("Recording started: \(formatter.string(from: firstSegment.startTime))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 8)
                            }
                        }
                        
                        // Transcript - prefer segments, then blocks, then plain text
                        if !meeting.transcriptSegments.isEmpty {
                            // Segment-based display with markers
                            LazyVStack(spacing: 8) {
                                ForEach(meeting.transcriptSegments.sorted(by: { $0.segmentNumber < $1.segmentNumber })) { segment in
                                    Group {
                                        // Segment marker (except for first segment)
                                        if segment.segmentNumber > 1 {
                                            let formatter: DateFormatter = {
                                                let f = DateFormatter()
                                                f.dateStyle = .none
                                                f.timeStyle = .short
                                                return f
                                            }()
                                            Text("Recording resumed at \(formatter.string(from: segment.startTime))")
                                                .font(.system(size: 12))
                                                .foregroundStyle(.tertiary)
                                                .padding(.vertical, 8)
                                        }
                                        
                                        // Blocks for this segment
                                        let blocksToShow = (meeting.isShowingRefined && segment.isRefined) ?
                                            (segment.refinedBlocks ?? segment.originalBlocks) :
                                            segment.originalBlocks
                                        
                                        ForEach(blocksToShow) { block in
                                            TranscriptBlockView(block: block)
                                        }
                                    }
                                }
                            }
                        } else {
                            // Fallback to block-based or plain text display
                            let hasOriginal = (meeting.originalTranscriptBlocks != nil || meeting.originalTranscript != nil)
                            let showingOriginal = viewModel.showOriginalTranscript(for: meeting) && hasOriginal
                            
                            if let blocks = meeting.transcriptBlocks, !blocks.isEmpty {
                                // Block-based display (new format)
                                LazyVStack(spacing: 8) {
                                    ForEach(showingOriginal ? (meeting.originalTranscriptBlocks ?? blocks) : blocks) { block in
                                        TranscriptBlockView(block: block)
                                    }
                                }
                            } else if let transcript = meeting.transcript {
                                // Plain text display (legacy format)
                                Text(showingOriginal ? (meeting.originalTranscript ?? transcript) : transcript)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("Loading transcript...")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .onAppear {
                                        viewModel.loadTranscript(for: meeting)
                                    }
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 80) // Space for floating control pane
                }
            }
            
            // Floating control pane: Resume controls for resumable meetings, refinement controls otherwise
            if meeting.canResume {
                // Show resume control pane for resumable meetings
                ResumeControlPane(viewModel: viewModel, meeting: meeting)
                    .padding(.bottom, 16)
            } else if viewModel.canRefineTranscripts {
                // Show refinement control pane for non-resumable meetings
                let isRefined = meeting.isRefined || meeting.originalTranscriptBlocks != nil || meeting.originalTranscript != nil
                let isRefining = viewModel.meetingBeingRefined?.id == meeting.id && viewModel.refinementService.isRefining
                // Check if refinement will happen (meeting has transcript but hasn't been refined yet)
                let willRefine = !isRefined && ((meeting.transcriptBlocks != nil && !meeting.transcriptBlocks!.isEmpty) || (meeting.transcript != nil && !meeting.transcript!.isEmpty))
                
                Group {
                    if isRefining || willRefine {
                        // Show loading indicator while refining OR if refinement will happen
                        HStack(spacing: 16) {
                            RefinementLoadingIndicator()
                        }
                    } else if isRefined {
                        // Only show toggle control when refinement is complete
                        HStack(spacing: 16) {
                            RefinementToggleControl(
                                isOn: Binding(
                                    get: { 
                                        // Show refined (toggle ON) unless user explicitly wants original
                                        return !viewModel.showOriginalTranscript(for: meeting)
                                    },
                                    set: { _ in viewModel.toggleOriginalTranscript(for: meeting) }
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    Capsule()
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                }
                .padding(.bottom, 16)
            }
        }
    }
    
    // MARK: - Empty Detail View
    
    private var emptyDetailView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            
            Text("Select a meeting")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("Choose a meeting from the sidebar to view its transcript")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Helpers
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Floating Recording Indicator

/// Floating indicator shown when viewing a past meeting while recording is active
/// Allows quick return to the live recording view
struct FloatingRecordingIndicator: View {
    let elapsedTime: String
    let onTap: () -> Void
    
    @State private var isPulsing = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Pulsing red dot
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(isPulsing ? 0.5 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.8)
                        .repeatForever(autoreverses: true),
                        value: isPulsing
                    )
                
                // Waveform icon
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                
                // Elapsed time
                Text(elapsedTime)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            isPulsing = true
        }
        .help("Return to live recording")
    }
}

#Preview("Active Recording") {
    let vm = MuesliViewModel()
    RecordingDetailView(viewModel: vm)
        .frame(width: 600, height: 800)
}

#Preview("Empty") {
    let vm = MuesliViewModel()
    RecordingDetailView(viewModel: vm)
        .frame(width: 600, height: 800)
}
