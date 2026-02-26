import SwiftUI

/// Detail view showing active recording, completed recording, or historical meeting
struct RecordingDetailView: View {
    @Bindable var viewModel: MuesliViewModel
    @Environment(MeetingHistoryManager.self) private var historyManager
    
    /// Check if active session is a resumed recording for the selected meeting
    private var isResumedRecordingForSelectedMeeting: Bool {
        guard let activeSession = viewModel.activeRecordingSession,
              let selectedMeeting = historyManager.selectedMeeting,
              let parentMeeting = activeSession.parentMeeting else {
            return false
        }
        return parentMeeting.id == selectedMeeting.id && !activeSession.isCompleted
    }
    
    var body: some View {
        @Bindable var history = historyManager
        
        Group {
            if let activeSession = viewModel.activeRecordingSession, !activeSession.isCompleted {
                if isResumedRecordingForSelectedMeeting {
                    // Resumed recording for selected meeting - show as active recording
                    activeRecordingView(session: activeSession)
                } else if historyManager.selectedMeeting != nil {
                    // Recording a different meeting while viewing selected one
                    historicalMeetingViewWithIndicator(meeting: historyManager.selectedMeeting!)
                } else {
                    // New recording (no selected meeting)
                    activeRecordingView(session: activeSession)
                }
            } else if let selectedMeeting = historyManager.selectedMeeting {
                // Not recording, viewing a saved meeting
                historicalMeetingViewWithIndicator(meeting: selectedMeeting)
            } else {
                emptyDetailView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .alert("Delete Meeting?", isPresented: $history.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                historyManager.cancelDeleteMeetings()
            }
            Button("Delete", role: .destructive) {
                historyManager.confirmDeleteMeetings()
            }
        } message: {
            if let meeting = historyManager.meetingsPendingDeletion.first {
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
                progress: viewModel.refinementCoordinator.refinementProgress,
                isRefining: viewModel.refinementCoordinator.isRefining,
                errorMessage: viewModel.refinementCoordinator.errorMessage,
                onCancel: {
                    viewModel.cancelRefinement()
                }
            )
        }
    }
    
    // MARK: - Active Recording View
    
    private func activeRecordingView(session: RecordingSession) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .bottom) {
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
                    
                    // Audio-only mode banner (shown when model is downloading or compiling)
                    if session.isRecordingOnly && viewModel.isAnyModelBusy {
                        audioOnlyBanner
                    }
                    
                    // Header with title and recording indicator
                    headerView(session: session)
                    
                    // Transcript content - different view for resumed vs new recordings
                    if let parentMeeting = session.parentMeeting {
                        resumedRecordingContentView(session: session, meeting: parentMeeting)
                    } else {
                        recordingContentView(session: session)
                    }
                }
                
                // Floating control bar at bottom
                floatingControlBar(session: session)
                    .padding(.bottom, 16)
            }
            
            VStack(spacing: 8) {
                if session.state == .stopping {
                    stoppingFloatingIndicator(session: session)
                }

                if let refinedMeeting = viewModel.refinementCoordinator.meetingBeingRefined,
                   let startTime = viewModel.refinementCoordinator.refinementStartTime,
                   viewModel.refinementCoordinator.isRefining {
                    FloatingProcessingIndicator(
                        phase: .refining,
                        startTime: startTime,
                        onTap: { historyManager.selectMeeting(refinedMeeting) }
                    )
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 80)
            .animation(.easeInOut(duration: 0.3), value: session.state == .stopping)
            .animation(.easeInOut(duration: 0.3), value: viewModel.refinementCoordinator.isRefining)
        }
    }
    
    // MARK: - Resumed Recording Content View
    
    /// Content view for resumed recordings - shows existing segments + "Recording resumed" marker + live transcript
    private func resumedRecordingContentView(session: RecordingSession, meeting: MeetingHistoryItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Recording started header
                    if let firstSegment = meeting.transcriptSegments.first {
                        HStack {
                            Spacer()
                            let formatter: DateFormatter = {
                                let dateFormatter = DateFormatter()
                                dateFormatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
                                return dateFormatter
                            }()
                            Text("Recording started: \(formatter.string(from: firstSegment.startTime))")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    
                    // Show existing segments from the meeting
                    ForEach(Array(meeting.transcriptSegments.enumerated()), id: \.element.id) { index, segment in
                        // Show "Recording resumed" marker for segments after the first
                        if index > 0 {
                            HStack {
                                Spacer()
                                let formatter: DateFormatter = {
                                    let dateFormatter = DateFormatter()
                                    dateFormatter.dateStyle = .none
                                    dateFormatter.timeStyle = .short
                                    return dateFormatter
                                }()
                                Text("Recording resumed at \(formatter.string(from: segment.startTime))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 8)
                                Spacer()
                            }
                        }
                        
                        // Show blocks for this segment (respect current view mode)
                        let blocksToShow = (meeting.isShowingRefined && segment.isRefined) ?
                            (segment.refinedBlocks ?? segment.originalBlocks) :
                            segment.originalBlocks
                        
                        ForEach(blocksToShow) { block in
                            TranscriptBlockView(block: block)
                        }
                    }
                    
                    // "Recording resumed" marker for the current live recording
                    HStack {
                        Spacer()
                        let formatter: DateFormatter = {
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateStyle = .none
                            dateFormatter.timeStyle = .short
                            return dateFormatter
                        }()
                        Text("Recording resumed at \(formatter.string(from: session.recordingStartTime ?? Date()))")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                        Spacer()
                    }
                    .id("resumeMarker")
                    
                    // Live transcript blocks from current session
                    if session.transcriptBlocks.isEmpty {
                        VStack(spacing: 16) {
                            if session.isModelLoading && viewModel.isSlowModelLoad {
                                // First-time compilation - show detailed message
                                ProgressView()
                                    .scaleEffect(1.2)
                                Text("Preparing transcription model...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("This is a one-time setup that may take a few minutes.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            } else if session.isModelLoading {
                                // Normal loading - brief spinner
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading model...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                // Model ready, waiting for speech
                                Image(systemName: "waveform")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.tertiary)
                                Text("Listening...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .id("listeningPlaceholder")
                    } else {
                        ForEach(session.transcriptBlocks) { block in
                            TranscriptBlockView(block: block)
                                .id(block.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 100) // Space for floating control bar
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
            .onAppear {
                // Scroll to the resume marker when view appears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation {
                        proxy.scrollTo("resumeMarker", anchor: .top)
                    }
                }
            }
        }
    }
    
    // MARK: - Header
    
    private func headerView(session: RecordingSession) -> some View {
        HStack(spacing: 12) {
            // Title text field - use parent meeting title for resumed recordings
            if let parentMeeting = session.parentMeeting {
                TextField("Meeting Title", text: Binding(
                    get: { parentMeeting.title },
                    set: { parentMeeting.title = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
            } else {
                TextField("Meeting Title", text: Binding(
                    get: { session.meetingTitle },
                    set: { session.meetingTitle = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
            }
            
            Spacer()
            
            // Recording indicator (shows loading state during model init)
            RecordingIndicator(
                elapsedTime: session.elapsedTimeString,
                isInitializing: session.isInitializing,
                isModelLoading: session.isModelLoading,
                isSlowModelLoad: viewModel.isSlowModelLoad,
                isRecordingOnly: session.isRecordingOnly
            )
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
                viewModel.selectMicrophoneDevice(deviceID)
            }
        )
    }
    
    // MARK: - Settings Menu Control (Gear icon with submenus)
    
    private func settingsMenuControl(session: RecordingSession) -> some View {
        Menu {
            // Submenu 1: Live Transcript
            Menu("Live Transcript") {
                Button(
                    action: {
                        viewModel.transcriptionMode = .live
                    },
                    label: {
                        HStack {
                            Text("Live")
                            if viewModel.transcriptionMode == .live {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                )
                
                Button(
                    action: {
                        viewModel.transcriptionMode = .postProcessing
                    },
                    label: {
                        HStack {
                            Text("Post-processing")
                            if viewModel.transcriptionMode == .postProcessing {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                )
            }
            
            Divider()
            
            // Submenu 2: Transcription Model
            // Disable during switching or first-time model compilation
            transcriptionModelMenu
            
            Divider()
            
            #if DEBUG
            Toggle(isOn: $viewModel.isEchoCancellationEnabled) {
                Text("Echo Cancellation")
            }
            #else
            Text("Echo Cancellation (Auto)")
                .foregroundStyle(.secondary)
            #endif
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Transcription Model Menu
    
    @ViewBuilder
    private var transcriptionModelMenu: some View {
        let isModelBusy = viewModel.isModelSwitching || viewModel.isSlowModelLoad
        let models = viewModel.modelManager.downloadedModelsOrdered
        let activeModel = viewModel.modelManager.activeModel
        
        // Use simple string title to match other submenus (Live Transcript, Audio Source)
        // Custom labels with HStack break nested menu rendering
        Menu("Model") {
            ForEach(models, id: \.self) { model in
                Button {
                    Task {
                        await viewModel.switchTranscriptionModel(to: model)
                    }
                } label: {
                    HStack {
                        Text(model.displayName)
                        if activeModel == model {
                            if viewModel.isModelSwitching {
                                Image(systemName: "arrow.trianglehead.2.clockwise")
                            } else {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                .disabled(isModelBusy)
            }
        }
        .disabled(isModelBusy)
    }
    
    // MARK: - Stop Recording Button
    
    private func stopRecordingButton(session: RecordingSession) -> some View {
        Button(
            action: {
                viewModel.stopRecording(for: session)
            },
            label: {
                if session.state == .stopping {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.orange))
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.red))
                }
            }
        )
        .buttonStyle(.plain)
        .disabled(session.state == .stopping)
    }

    // MARK: - Recording Content
    
    private func recordingContentView(session: RecordingSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session.transcriptBlocks.isEmpty {
                    if session.liveDraftText == nil {
                        VStack(spacing: 16) {
                            Spacer()
                            
                            if session.isModelLoading && viewModel.isSlowModelLoad {
                                // First-time compilation - show detailed message
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("Preparing transcription model...")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text("This is a one-time setup that may take a few minutes.\nYour recording is active and audio is being captured.")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            } else if session.isModelLoading {
                                // Normal loading - brief spinner
                                ProgressView()
                                    .scaleEffect(1.2)
                                Text("Loading model...")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text("Transcript will appear shortly")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            } else {
                                // Model ready, waiting for speech
                                Image(systemName: "waveform")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.tertiary)
                                Text("Listening...")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text("Transcript will appear here as you speak")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            }
                            
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                        .padding(.bottom, 100) // Space for floating control bar
                    }
                    
                    // Show live draft immediately while waiting for first committed block.
                    // This removes the long "blank transcript" gap during active recording.
                    if let draftText = session.liveDraftText {
                        VStack {
                            DraftTranscriptView(text: draftText, speaker: session.liveDraftSpeaker)
                                .id("liveDraft")
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 100)
                    }
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

    private func stoppingFloatingIndicator(session: RecordingSession) -> some View {
        let processingState: TranscriptionCoordinator.MeetingProcessingState? = {
            guard let directory = session.outputDirectory else { return nil }
            return viewModel.processingState(for: directory)
        }()

        return FloatingProcessingIndicator(
            phase: .reprocessing,
            startTime: processingState?.startedAt ?? session.finalizationStartTime ?? Date(),
            statusText: processingState?.displayStatus ??
                (session.isFinalizingTranscript ? "Finalizing transcript..." : "Stopping recording...")
        )
    }

    // MARK: - Historical Meeting View with Floating Indicator
    
    @ViewBuilder
    private func processingIndicators(for meeting: MeetingHistoryItem) -> some View {
        // 1. Current meeting reprocessing (second-pass ASR / auto-reprocess / manual reprocess)
        if let processingState = viewModel.processingState(for: meeting) {
            let cancelAction: (() -> Void)? = processingState.cancellable
                ? { viewModel.cancelReprocessing(for: meeting) }
                : nil
            FloatingProcessingIndicator(
                phase: .reprocessing,
                startTime: processingState.startedAt,
                statusText: processingState.displayStatus,
                onCancel: cancelAction
            )
        } else if meeting.isReprocessing, let startTime = meeting.reprocessingStartTime {
            // Fallback for transient UI states while coordinator state is propagating.
            FloatingProcessingIndicator(
                phase: .reprocessing,
                startTime: startTime,
                onCancel: { viewModel.cancelReprocessing(for: meeting) }
            )
        }
        
        // 2. Current meeting refinement (LLM polish)
        if let refinedMeeting = viewModel.refinementCoordinator.meetingBeingRefined,
           let startTime = viewModel.refinementCoordinator.refinementStartTime,
           viewModel.refinementCoordinator.isRefining,
           refinedMeeting.id == meeting.id {
            FloatingProcessingIndicator(phase: .refining, startTime: startTime)
        }
        
        // 3. Different meeting refinement — tap to navigate
        if let refinedMeeting = viewModel.refinementCoordinator.meetingBeingRefined,
           let startTime = viewModel.refinementCoordinator.refinementStartTime,
           viewModel.refinementCoordinator.isRefining,
           refinedMeeting.id != meeting.id {
            FloatingProcessingIndicator(
                phase: .refining,
                startTime: startTime,
                onTap: { historyManager.selectMeeting(refinedMeeting) }
            )
        }
    }
    
    private func historicalMeetingViewWithIndicator(meeting: MeetingHistoryItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            historicalMeetingView(meeting: meeting)
            
            VStack(spacing: 8) {
                processingIndicators(for: meeting)
                
                // Show floating indicator when there's an active recording
                if viewModel.isViewingPastMeetingWhileRecording,
                   let activeSession = viewModel.activeRecordingSession {
                    FloatingRecordingIndicator(
                        elapsedTime: activeSession.elapsedTimeString,
                        isInitializing: activeSession.isInitializing,
                        isModelLoading: activeSession.isModelLoading,
                        isSlowModelLoad: viewModel.isSlowModelLoad,
                        isRecordingOnly: activeSession.isRecordingOnly,
                        onTap: {
                            viewModel.returnToLiveRecording()
                        }
                    )
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.3), value: meeting.isReprocessing)
            .animation(.easeInOut(duration: 0.3), value: viewModel.refinementCoordinator.isRefining)
        }
    }

    private var globalProcessingIndicator: (MeetingHistoryItem?, TranscriptionCoordinator.MeetingProcessingState)? {
        let processingStates = viewModel.allActiveProcessingStates()
            .sorted { $0.value.startedAt < $1.value.startedAt }
        guard let active = processingStates.first else { return nil }

        let meeting = historyManager.meetingHistory.first {
            $0.directory.standardizedFileURL.path == active.key
        }
        return (meeting, active.value)
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
                    
                    meetingActionsMenu(for: meeting)
                    
                    copyTranscriptButton(for: meeting)
                    
                    CompletedIndicator()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Metadata row with date
                        HStack(spacing: 8) {
                            Label(formatDate(meeting.date), systemImage: "calendar")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 8)
                        
                        // Show recording start time for resumable meetings
                        if meeting.canResume, let firstSegment = meeting.transcriptSegments.first {
                            Group {
                                let formatter: DateFormatter = {
                                    let dateFormatter = DateFormatter()
                                    dateFormatter.dateStyle = .medium
                                    dateFormatter.timeStyle = .short
                                    return dateFormatter
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
                                ForEach(
                                    meeting.transcriptSegments.sorted(by: { $0.segmentNumber < $1.segmentNumber })
                                ) { segment in
                                    Group {
                                        // Segment marker (except for first segment)
                                        if segment.segmentNumber > 1 {
                                            let formatter: DateFormatter = {
                                                let dateFormatter = DateFormatter()
                                                dateFormatter.dateStyle = .none
                                                dateFormatter.timeStyle = .short
                                                return dateFormatter
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
                            let hasOriginal = (
                                meeting.originalTranscriptBlocks != nil || meeting.originalTranscript != nil
                            )
                            let showingOriginal = viewModel.showOriginalTranscript(for: meeting) && hasOriginal
                            
                            if let blocks = meeting.transcriptBlocks, !blocks.isEmpty {
                                // Block-based display (new format)
                                LazyVStack(spacing: 8) {
                                    ForEach(
                                        showingOriginal ? (meeting.originalTranscriptBlocks ?? blocks) : blocks
                                    ) { block in
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
                                        Task {
                                            await historyManager.loadTranscript(for: meeting)
                                        }
                                    }
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 80) // Space for floating control pane
                }
            }
            
            // Floating control pane: Active recording controls or resume/refinement controls
            if let activeSession = viewModel.activeRecordingSession, !activeSession.isCompleted {
                // Show recording controls when actively recording (including resumed recordings)
                floatingControlBar(session: activeSession)
                    .padding(.bottom, 16)
            } else {
                // Show resume control pane for all saved meetings
                // ResumeControlPane handles: refinement loading, toggle, and resume button
                ResumeControlPane(viewModel: viewModel, meeting: meeting)
                    .padding(.bottom, 16)
            }
        }
    }
    
    // MARK: - Empty Detail View
    
    private var emptyDetailView: some View {
        ZStack(alignment: .bottomTrailing) {
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
            
            VStack(spacing: 8) {
                if let (meeting, state) = globalProcessingIndicator {
                    let cancelAction: (() -> Void)? = {
                        guard state.cancellable, let meeting else { return nil }
                        return { viewModel.cancelReprocessing(for: meeting) }
                    }()
                    let tapAction: (() -> Void)? = {
                        guard let meeting else { return nil }
                        return { historyManager.selectMeeting(meeting) }
                    }()
                    FloatingProcessingIndicator(
                        phase: .reprocessing,
                        startTime: state.startedAt,
                        statusText: state.displayStatus,
                        onTap: tapAction,
                        onCancel: cancelAction
                    )
                }

                if let refinedMeeting = viewModel.refinementCoordinator.meetingBeingRefined,
                   let startTime = viewModel.refinementCoordinator.refinementStartTime,
                   viewModel.refinementCoordinator.isRefining {
                    FloatingProcessingIndicator(
                        phase: .refining,
                        startTime: startTime,
                        onTap: { historyManager.selectMeeting(refinedMeeting) }
                    )
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.3), value: globalProcessingIndicator != nil)
            .animation(.easeInOut(duration: 0.3), value: viewModel.refinementCoordinator.isRefining)
        }
    }
    
    // MARK: - Audio-Only Mode Banner
    
    /// Banner shown when recording in audio-only mode (model downloading)
    private var audioOnlyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording audio only")
                    .font(.system(size: 12, weight: .medium))
                Text("Transcription will start when model download completes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Show download progress if available
            if let download = viewModel.activeDownloads.first {
                HStack(spacing: 4) {
                    ProgressView(value: download.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 40)
                    Text("\(Int(download.progress * 100))%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
    }
    
    // MARK: - Helpers
    
    /// Copy transcript button for historical meeting view
    private func copyTranscriptButton(for meeting: MeetingHistoryItem) -> some View {
        CopyTranscriptButton(getBlocks: { getTranscriptBlocks(for: meeting) })
    }
    
    /// Get transcript blocks from the meeting
    private func getTranscriptBlocks(for meeting: MeetingHistoryItem) -> [TranscriptBlock]? {
        // Try segments first (preferred)
        if !meeting.transcriptSegments.isEmpty {
            var allBlocks: [TranscriptBlock] = []
            for segment in meeting.transcriptSegments.sorted(by: { $0.segmentNumber < $1.segmentNumber }) {
                let blocksToUse = (meeting.isShowingRefined && segment.isRefined) ?
                    (segment.refinedBlocks ?? segment.originalBlocks) :
                    segment.originalBlocks
                allBlocks.append(contentsOf: blocksToUse)
            }
            return allBlocks.isEmpty ? nil : allBlocks
        }
        
        // Fallback to transcriptBlocks
        if let blocks = meeting.transcriptBlocks, !blocks.isEmpty {
            let showingOriginal = viewModel.showOriginalTranscript(for: meeting) &&
                meeting.originalTranscriptBlocks != nil
            return showingOriginal ? meeting.originalTranscriptBlocks : blocks
        }
        
        return nil
    }
    
    /// Ellipsis menu for completed-meeting actions (Apple HIG: ellipsis for "more actions").
    private func meetingActionsMenu(for meeting: MeetingHistoryItem) -> some View {
        EllipsisActionsMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: meeting.directory.path)
            }
            
            if !viewModel.modelManager.downloadedModels.isEmpty {
                Divider()
                Menu("Reprocess Transcript") {
                    ForEach(viewModel.modelManager.downloadedModelsOrdered, id: \.self) { model in
                        Button("With \(model.displayName)") {
                            viewModel.reprocessTranscript(for: meeting, using: model)
                        }
                    }
                }
                .disabled(viewModel.isMeetingProcessing(for: meeting))
            }
            
            Divider()
            Button("Delete Recording", role: .destructive) {
                historyManager.requestDeleteMeeting(meeting)
            }
        }
    }
    
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
    var isInitializing: Bool = false
    var isModelLoading: Bool = false
    var isSlowModelLoad: Bool = false
    var isRecordingOnly: Bool = false
    let onTap: () -> Void
    
    @State private var isPulsing = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isInitializing {
                    // Loading spinner when initializing
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    
                    Text("Starting...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
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
                    
                    Text(elapsedTime)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    
                    if isModelLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                            .help(isSlowModelLoad 
                                ? "Model preparing for first use (one-time setup)..." 
                                : "Transcription model loading...")
                    } else if isRecordingOnly {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
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
    let historyManager = MeetingHistoryManager()
    RecordingDetailView(viewModel: vm)
        .environment(historyManager)
        .frame(width: 600, height: 800)
}

#Preview("Empty") {
    let vm = MuesliViewModel()
    let historyManager = MeetingHistoryManager()
    RecordingDetailView(viewModel: vm)
        .environment(historyManager)
        .frame(width: 600, height: 800)
}
