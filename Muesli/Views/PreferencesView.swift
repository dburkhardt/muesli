import SwiftUI
import ServiceManagement

/// Main Preferences view with tabbed sections for Models, Output, and General settings
struct PreferencesView: View {
    @Bindable var viewModel: MuesliViewModel
    
    var body: some View {
        TabView {
            ModelsPreferencesTab(viewModel: viewModel)
                .tabItem {
                    Label("Models", systemImage: "brain.head.profile")
                }
            
            OutputPreferencesTab(viewModel: viewModel)
                .tabItem {
                    Label("Output", systemImage: "folder")
                }
            
            GeneralPreferencesTab(viewModel: viewModel)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - Models Tab

/// Models preferences tab - embeds existing ModelManagementView
struct ModelsPreferencesTab: View {
    @Bindable var viewModel: MuesliViewModel
    
    var body: some View {
        ModelManagementView(viewModel: viewModel)
    }
}

// MARK: - Output Tab

/// Output preferences tab - configure where recordings are saved
struct OutputPreferencesTab: View {
    @Bindable var viewModel: MuesliViewModel
    @State private var showDirectoryPicker = false
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recording Output Location")
                        .font(.headline)
                    
                    Text("Choose where meeting recordings and transcripts are saved.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        // Show current directory path
                        Text(viewModel.outputDirectory.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        
                        Button("Choose...") {
                            showDirectoryPicker = true
                        }
                    }
                    
                    Button("Reset to Default") {
                        viewModel.resetOutputDirectory()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding()
        }
        .fileImporter(
            isPresented: $showDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.setOutputDirectory(url)
                }
            case .failure(let error):
                print("Failed to select directory: \(error)")
            }
        }
    }
}

// MARK: - General Tab

/// General preferences tab - launch at login and other settings
struct GeneralPreferencesTab: View {
    @Bindable var viewModel: MuesliViewModel
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Startup")
                        .font(.headline)
                    
                    Toggle(isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { viewModel.setLaunchAtLogin($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch Muesli at Login")
                            Text("Muesli will start automatically when you log in.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding()
            
            Divider()
            
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Transcription")
                        .font(.headline)
                    
                    Picker("Default Mode:", selection: Binding(
                        get: { viewModel.transcriptionMode },
                        set: { viewModel.transcriptionMode = $0 }
                    )) {
                        Text("Live").tag(TranscriptionService.TranscriptionMode.live)
                        Text("Post-processing").tag(TranscriptionService.TranscriptionMode.postProcessing)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 250)
                    
                    Text("Live mode transcribes during recording. Post-processing waits until the recording ends for potentially better accuracy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            
            Divider()
            
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Audio")
                        .font(.headline)
                    
                    Toggle(isOn: Binding(
                        get: { viewModel.isEchoCancellationEnabled },
                        set: { viewModel.isEchoCancellationEnabled = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Echo Cancellation")
                            Text("Remove echo from microphone audio caused by speakers. Improves transcription quality and saved audio files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding()
        }
    }
}

#Preview("Preferences") {
    let vm = MuesliViewModel()
    return PreferencesView(viewModel: vm)
}
