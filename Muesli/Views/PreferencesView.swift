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
        .frame(minWidth: 520, minHeight: 450)
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
    @State private var showExportDirectoryPicker = false
    @State private var isExporting = false
    @State private var exportCount: Int?
    
    private static let logger = Logger(subsystem: "com.muesli.app", category: "PreferencesView")
    
    var body: some View {
        @Bindable var prefs = preferencesManager
        
        Form {
            Section("Recording Output Location") {
                Text("Choose where meeting recordings and transcripts are saved.")
                    .foregroundStyle(.secondary)
                
                HStack {
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
            
            Section("Export for External Tools") {
                Toggle(isOn: $prefs.exportEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic Export")
                        Text("Export transcripts to a structured folder for MCP servers and IDE extensions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                
                LabeledContent("Export Location") {
                    HStack {
                        Text(preferencesManager.exportDirectory.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        
                        Button("Choose...") {
                            showExportDirectoryPicker = true
                        }
                        .disabled(!prefs.exportEnabled)
                    }
                }
                
                Button("Reset to Default") {
                    preferencesManager.resetExportDirectory()
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(!prefs.exportEnabled)
                
                HStack {
                    Button(isExporting ? "Exporting..." : "Export All Now") {
                        Task {
                            await exportAllMeetings()
                        }
                    }
                    .disabled(isExporting || !prefs.exportEnabled)
                    
                    if let count = exportCount {
                        Text("Exported \(count) meetings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
        .fileImporter(
            isPresented: $showExportDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    preferencesManager.exportDirectory = url
                }
            case .failure(let error):
                Self.logger.error("Failed to select export directory: \(error)")
            }
        }
    }
    
    private func exportAllMeetings() async {
        isExporting = true
        exportCount = nil
        
        // Get the viewModel from the environment or create temporary export service
        let exportService = ExportService()
        let meetingHistoryService = MeetingHistoryService()
        let meetings = meetingHistoryService.discoverMeetings()
        
        do {
            let count = try await exportService.exportAllMeetings(meetings)
            exportCount = count
            Self.logger.info("Exported \(count) meetings")
        } catch {
            Self.logger.error("Failed to export meetings: \(error.localizedDescription)")
            exportCount = 0
        }
        
        isExporting = false
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
            Section("Startup") {
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
            
            Section("Transcription") {
                LabeledContent("Default Mode") {
                    Picker(selection: $prefs.transcriptionMode) {
                        Text("Live").tag(PreferencesManager.TranscriptionMode.live)
                        Text("Post-processing").tag(PreferencesManager.TranscriptionMode.postProcessing)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 250)
                }
                
                Text("Live mode transcribes during recording. Post-processing waits until the recording ends for potentially better accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Transcription Quality") {
                Toggle(isOn: $prefs.isLiveStabilizerEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live transcript stabilization")
                        Text("Suppress duplicate overlap text and show a tentative draft tail during recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                
                Toggle(isOn: $prefs.isSecondPassASREnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Finalize transcript after recording")
                        Text("Runs a second-pass ASR over saved audio for higher quality final transcript.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                
                Toggle(isOn: $prefs.isAutoRefineEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-refine with AI (experimental)")
                        Text("Applies constrained LLM cleanup after second-pass ASR.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                
                LabeledContent("Second-pass model") {
                    Picker(selection: $prefs.secondPassModelPreference) {
                        Text("Best available").tag(PreferencesManager.SecondPassModelPreference.bestAvailable)
                        Text("Same as live model").tag(PreferencesManager.SecondPassModelPreference.sameAsLive)
                        Text("Best available (no downgrade)").tag(PreferencesManager.SecondPassModelPreference.bestAvailableNoDowngrade)
                        Text("Specific model").tag(PreferencesManager.SecondPassModelPreference.specific)
                    } label: {
                        EmptyView()
                    }
                    .frame(maxWidth: 280)
                }
            }
            
            Section("Audio") {
                #if DEBUG
                Toggle(isOn: $prefs.isEchoCancellationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Echo Cancellation")
                        Text("Remove echo from microphone audio caused by speakers. Improves transcription quality and saved audio files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                #else
                LabeledContent {
                    Text("Automatic")
                        .foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Echo Cancellation")
                        Text("Managed by Muesli based on your audio device. Cannot be disabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif
                
                LabeledContent("Audio Chunk Duration") {
                    Text(String(format: "%.1f seconds", prefs.audioChunkDuration))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                Slider(value: $prefs.audioChunkDuration, in: 2.0...10.0, step: 0.5)
                
                Text("Shorter chunks provide faster transcription but may reduce accuracy. Longer chunks improve accuracy but increase latency. Changes apply to new recordings only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Preferences") {
    let vm = MuesliViewModel()
    let prefs = PreferencesManager()
    return PreferencesView(viewModel: vm)
        .environment(prefs)
}
