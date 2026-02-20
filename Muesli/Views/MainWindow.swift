import SwiftUI

/// Main window displaying the transcript and recording controls
struct MainWindow: View {
    let viewModel: MuesliViewModel
    @Bindable var session: RecordingSession
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with title and recording indicator
            headerView
            
            Divider()
            
            // Main content area based on session state
            switch session.state {
            case .idle:
                idleView
            case .recording, .stopping:
                recordingView
            case .completed:
                completedView
            }
            
            // Footer with action buttons
            Divider()
            footerView
        }
        .frame(minWidth: 400, minHeight: 400)
        .background(.background)
        .alert("Error", isPresented: $session.showError) {
            Button("Open Settings") {
                viewModel.openScreenRecordingSettings()
                session.dismissError()
            }
            .keyboardShortcut(.defaultAction)
            
            Button("Cancel", role: .cancel) {
                session.dismissError()
            }
        } message: {
            if let message = session.errorMessage {
                Text(message)
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 12) {
            // Title text field
            TextField("Meeting Title", text: $session.meetingTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .disabled(session.isCompleted)
            
            Spacer()
            
            // Recording indicator
            if session.isRecording {
                RecordingIndicator(
                    elapsedTime: session.elapsedTimeString,
                    isInitializing: session.isInitializing,
                    isModelLoading: session.isModelLoading,
                    isSlowModelLoad: viewModel.isSlowModelLoad,
                    isRecordingOnly: session.isRecordingOnly
                )
            } else if session.isCompleted {
                CompletedIndicator()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    
    // MARK: - Idle View
    
    private var idleView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            
            Text("Ready to Record")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            // Transcription mode selector
            VStack(spacing: 8) {
                Text("Transcription mode:")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                
                Picker("Transcription Mode", selection: Binding(
                    get: { viewModel.transcriptionMode },
                    set: { viewModel.transcriptionMode = $0 }
                )) {
                    Text("Live (Real-time)").tag(TranscriptionService.TranscriptionMode.live)
                    Text("Post-processing (Better accuracy)").tag(TranscriptionService.TranscriptionMode.postProcessing)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                
                Text(viewModel.transcriptionMode == .live 
                     ? "Transcribe as you record (faster, lower accuracy)"
                     : "Transcribe after recording stops (slower, higher accuracy)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            
            // Microphone picker
            VStack(spacing: 8) {
                Text("Microphone:")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                
                HStack(spacing: 8) {
                    Picker("Microphone", selection: Binding(
                        get: { viewModel.microphoneManager.selectedDeviceID },
                        set: { viewModel.selectMicrophoneDevice($0) }
                    )) {
                        ForEach(viewModel.microphoneManager.availableDevices) { device in
                            HStack {
                                Text(device.name)
                                if device.isDefault {
                                    Text("(Default)")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                            .tag(device.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    
                Button(
                    action: {
                        viewModel.microphoneManager.refreshDevices()
                    },
                    label: {
                        Image(systemName: "arrow.clockwise")
                    }
                )
                .buttonStyle(.borderless)
                .help("Refresh microphone list")
                }
                
                if viewModel.microphoneManager.availableDevices.isEmpty {
                    Text("No microphones detected")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    // MARK: - Recording View
    
    private var recordingView: some View {
        ScrollView {
            if session.transcriptText.isEmpty {
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
            } else {
                Text(session.transcriptText)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Completed View
    
    private var completedView: some View {
        VStack(spacing: 16) {
            if session.transcriptText.isEmpty {
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
            } else {
                // Show transcript if available
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Recording Saved")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 8)
                        
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
                    .padding(20)
                }
            }
            
            // Re-transcribe button (shown if audio files exist and not currently retranscribing)
            if session.canRetranscribe && !session.isRetranscribing {
                Button(
                    action: {
                        viewModel.retranscribeWithPostProcessing(for: session)
                    },
                    label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Re-transcribe with Post-Processing")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                )
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        HStack(spacing: 12) {
            switch session.state {
            case .idle:
                Spacer()
                
            Button(
                action: {
                    viewModel.startRecording(for: session)
                },
                label: {
                    Text("Start Recording")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            )
            .buttonStyle(.plain)
                
                Spacer()
                
            case .recording, .stopping:
                Spacer()
                
            Button(
                action: {
                    viewModel.stopRecording(for: session)
                },
                label: {
                    Text(session.state == .stopping ? "Stopping..." : "Stop Recording")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            )
            .buttonStyle(.plain)
            .disabled(session.state == .stopping)
                
                Spacer()
                
            case .completed:
                Spacer()
                
            Button(
                action: {
                    session.openOutputFolder()
                },
                label: {
                    Text("Open in Finder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            )
            .buttonStyle(.plain)
                
            Button(
                action: {
                    openWindow(id: "session")
                },
                label: {
                    Text("New Recording")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            )
            .buttonStyle(.plain)
                
                Spacer()
            }
        }
        .padding(16)
    }
}

#Preview("Idle") {
    let vm = MuesliViewModel()
    let session = RecordingSession()
    return MainWindow(viewModel: vm, session: session)
        .frame(width: 500, height: 600)
}

#Preview("Recording") {
    let vm = MuesliViewModel()
    let session = RecordingSession()
    session.state = .recording
    session.recordingStartTime = Date()
    return MainWindow(viewModel: vm, session: session)
        .frame(width: 500, height: 600)
}

#Preview("Completed") {
    let vm = MuesliViewModel()
    let session = RecordingSession()
    session.state = .completed
    session.meetingTitle = "Team Standup"
    session.outputDirectory = URL(
        fileURLWithPath: "/Users/test/Library/Application Support/Muesli/Recordings/2026-01-05_14-00_Team-Standup"
    )
    return MainWindow(viewModel: vm, session: session)
        .frame(width: 500, height: 600)
}
