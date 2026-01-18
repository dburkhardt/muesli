import os.log
import ServiceManagement
import SwiftUI

/// Main Preferences view with tabbed sections for Models, Output, and General settings
struct PreferencesView: View {
    @Bindable var viewModel: MuesliViewModel
    @Environment(PreferencesManager.self) private var preferencesManager
    
    private static let logger = Logger(subsystem: "com.muesli.app", category: "PreferencesView")
    
    var body: some View {
        TabView {
            ModelsPreferencesTab(viewModel: viewModel)
                .tabItem {
                    Label("Models", systemImage: "brain.head.profile")
                }
            
            OutputPreferencesTab()
                .tabItem {
                    Label("Output", systemImage: "folder")
                }
            
            GeneralPreferencesTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - Models Tab

/// Models preferences tab - embeds existing ModelManagementView
/// Note: Still uses viewModel for model management (will be migrated in later phase)
struct ModelsPreferencesTab: View {
    @Bindable var viewModel: MuesliViewModel
    
    var body: some View {
        ModelManagementView(viewModel: viewModel)
    }
}

// MARK: - Output Tab

/// Output preferences tab - configure where recordings are saved
/// Now uses PreferencesManager via environment
struct OutputPreferencesTab: View {
    @Environment(PreferencesManager.self) private var preferencesManager
    @State private var showDirectoryPicker = false
    
    private static let logger = Logger(subsystem: "com.muesli.app", category: "PreferencesView")
    
    var body: some View {
        @Bindable var prefs = preferencesManager
        
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
                        Text(preferencesManager.outputDirectory.path)
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
                        preferencesManager.resetOutputDirectory()
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
                    preferencesManager.setOutputDirectory(url)
                }
            case .failure(let error):
                Self.logger.error("Failed to select directory: \(error)")
            }
        }
    }
}

// MARK: - General Tab

/// General preferences tab - launch at login and other settings
/// Now uses PreferencesManager via environment
struct GeneralPreferencesTab: View {
    @Environment(PreferencesManager.self) private var preferencesManager
    
    var body: some View {
        @Bindable var prefs = preferencesManager
        
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Startup")
                        .font(.headline)
                    
                    Toggle(isOn: $prefs.launchAtLogin) {
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
                    
                    Picker("Default Mode:", selection: $prefs.transcriptionMode) {
                        Text("Live").tag(PreferencesManager.TranscriptionMode.live)
                        Text("Post-processing").tag(PreferencesManager.TranscriptionMode.postProcessing)
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
                    
                    Toggle(isOn: $prefs.isEchoCancellationEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Echo Cancellation")
                            Text("Remove echo from microphone audio caused by speakers. Improves transcription quality and saved audio files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Audio Chunk Duration")
                            Spacer()
                            Text(String(format: "%.1f seconds", prefs.audioChunkDuration))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        
                        Slider(value: $prefs.audioChunkDuration, in: 2.0...10.0, step: 0.5)
                        
                        Text(
                            """
                            Shorter chunks provide faster transcription but may reduce accuracy. \
                            Longer chunks improve accuracy but increase latency. \
                            Changes apply to new recordings only.
                            """
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
    }
}

#Preview("Preferences") {
    let vm = MuesliViewModel()
    let prefs = PreferencesManager()
    return PreferencesView(viewModel: vm)
        .environment(prefs)
}
