import SwiftUI

/// Sheet for selecting a meeting app to start recording
struct StartRecordingSheet: View {
    let viewModel: MuesliViewModel
    @Binding var isPresented: Bool
    @State private var selectedApp: MeetingAppDetector.DetectedApp?
    @State private var isStarting = false
    @State private var refreshTimer: Timer?
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Start Recording")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text("Select a meeting app to capture audio from")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            
            // App picker
            VStack(alignment: .leading, spacing: 12) {
                Text("Meeting App:")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                
                if viewModel.availableMeetingApps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        
                        Text("No meeting apps detected")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        Text("Start Zoom, Teams, or a browser with Google Meet.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                    .padding(.vertical, 20)
                } else {
                    Picker("Meeting App", selection: $selectedApp) {
                        Text("Select app...").tag(nil as MeetingAppDetector.DetectedApp?)
                        ForEach(viewModel.availableMeetingApps) { app in
                            Text(app.name).tag(app as MeetingAppDetector.DetectedApp?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300)
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
            Button(
                action: {
                    startRecording()
                },
                label: {
                    if isStarting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Starting...")
                        }
                    } else {
                        Text("Start Recording")
                    }
                }
            )
                .buttonStyle(.borderedProminent)
                .disabled(selectedApp == nil || isStarting)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 400, height: 300)
        .task {
            // Refresh apps when sheet appears
            await viewModel.refreshMeetingApps()
            
            // Set up auto-refresh timer (every second)
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    await viewModel.refreshMeetingApps()
                }
            }
        }
        .onDisappear {
            // Stop timer when sheet closes
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }
    
    // MARK: - Actions
    
    private func startRecording() {
        guard let app = selectedApp else { return }
        
        isStarting = true
        
        // Create a new session
        let session = viewModel.createSession()
        session.selectedApp = app
        
        // Use default microphone (system default)
        if let defaultMic = viewModel.microphoneManager.currentDefaultDevice {
            viewModel.microphoneManager.setSelectedDeviceID(defaultMic.id)
        }
        
        // Ensure live transcription mode
        viewModel.transcriptionMode = .live
        
        // Start recording (this will set activeSession internally)
        viewModel.startRecording(for: session)
        
        // Transition to split view
        viewModel.isSplitViewVisible = true
        
        // Dismiss sheet
        isPresented = false
        isStarting = false
    }
}

#Preview {
    let vm = MuesliViewModel()
    return StartRecordingSheet(viewModel: vm, isPresented: .constant(true))
}
