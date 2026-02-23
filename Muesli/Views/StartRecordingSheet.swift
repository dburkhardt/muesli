import SwiftUI

/// Sheet for confirming a new recording
struct StartRecordingSheet: View {
    let viewModel: MuesliViewModel
    @Binding var isPresented: Bool
    @State private var isStarting = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Start Recording")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text("Captures all system audio")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            
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
                .disabled(isStarting)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 400, height: 160)
    }
    
    // MARK: - Actions
    
    private func startRecording() {
        isStarting = true
        
        // Create a new session
        let session = viewModel.createSession()
        
        // Use default microphone (system default)
        if let defaultMic = viewModel.microphoneManager.currentDefaultDevice {
            viewModel.selectMicrophoneDevice(defaultMic.id)
        }
        
        // Ensure live transcription mode
        viewModel.transcriptionMode = .live
        
        // Start recording (this will set activeSession internally)
        viewModel.startRecording(for: session)
        
        // Dismiss sheet
        isPresented = false
        isStarting = false
    }
}

#Preview {
    let vm = MuesliViewModel()
    return StartRecordingSheet(viewModel: vm, isPresented: .constant(true))
}
