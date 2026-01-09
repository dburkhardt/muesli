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
        .frame(width: 520, height: 580)
        .overlay(alignment: .topTrailing) {
            WorkTreeBadge()
        }
    }
}

// MARK: - Models Tab

/// Models preferences tab - transcription models and LLM refinement models
struct ModelsPreferencesTab: View {
    @Bindable var viewModel: MuesliViewModel
    
    private var modelManager: ModelManager {
        viewModel.modelManager
    }
    
    private var llmManager: LLMManager {
        viewModel.llmManager
    }
    
    @State private var modelToDelete: ModelManager.ModelSize?
    @State private var showDeleteConfirmation = false
    @State private var llmModelToDelete: LLMManager.LLMModel?
    @State private var showLLMDeleteConfirmation = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Transcription Models Section
                transcriptionModelsSection
                
                Divider()
                
                // LLM Refinement Models Section
                llmModelsSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .alert("Delete Model", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { modelToDelete = nil }
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    _ = modelManager.deleteModel(model)
                    modelToDelete = nil
                }
            }
        } message: {
            if let model = modelToDelete {
                if modelManager.activeModel == model {
                    Text("This is your active model. Another model will be selected automatically.")
                } else {
                    Text("Delete this model?")
                }
            }
        }
        .alert("Delete LLM Model", isPresented: $showLLMDeleteConfirmation) {
            Button("Cancel", role: .cancel) { llmModelToDelete = nil }
            Button("Delete", role: .destructive) {
                if let model = llmModelToDelete {
                    _ = llmManager.deleteModel(model)
                    llmModelToDelete = nil
                }
            }
        } message: {
            Text("Delete this text processing model?")
        }
    }
    
    // MARK: - Transcription Models Section
    
    private var transcriptionModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription Models")
                .font(.headline)
            
            Text("Models for converting speech to text.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            // Model list
            VStack(spacing: 0) {
                ForEach(ModelManager.ModelSize.allCases) { model in
                    transcriptionModelRow(for: model)
                    if model != ModelManager.ModelSize.allCases.last {
                        Divider().padding(.horizontal, 8)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Active model picker
            if !modelManager.downloadedModels.isEmpty {
                HStack {
                    Text("Active Model:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { modelManager.activeModel ?? .base },
                        set: { modelManager.setActiveModel($0) }
                    )) {
                        ForEach(Array(modelManager.downloadedModels).sorted(by: { $0.rawValue < $1.rawValue })) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                    
                    Spacer()
                    
                    Button("Show in Finder") {
                        modelManager.showModelsInFinder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 8)
            }
        }
    }
    
    private func transcriptionModelRow(for model: ModelManager.ModelSize) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if modelManager.activeModel == model {
                        Text("(Active)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.sizeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            transcriptionModelStatus(for: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func transcriptionModelStatus(for model: ModelManager.ModelSize) -> some View {
        let state = modelManager.downloadState(for: model)
        switch state {
        case .idle, .checking:
            Button("Download") {
                Task { await modelManager.downloadModel(model) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }
        case .completed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button {
                    modelToDelete = model
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .controlSize(.small)
            }
        case .failed(let error):
            Button("Retry") {
                Task { await modelManager.downloadModel(model) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(error)
        }
    }
    
    // MARK: - LLM Models Section
    
    private var llmModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text Processing Models (Optional)")
                .font(.headline)
            
            Text("AI models to improve transcript quality by intelligently merging audio chunks.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            // LLM model list
            VStack(spacing: 0) {
                ForEach(LLMManager.LLMModel.allCases) { model in
                    llmModelRow(for: model)
                    if model != LLMManager.LLMModel.allCases.last {
                        Divider().padding(.horizontal, 8)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Active LLM picker and show in finder
            if !llmManager.downloadedModels.isEmpty {
                HStack {
                    Text("Active Model:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { llmManager.activeModel ?? .llama3_2_3b },
                        set: { llmManager.setActiveModel($0) }
                    )) {
                        ForEach(Array(llmManager.downloadedModels).sorted(by: { $0.rawValue < $1.rawValue })) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    
                    Spacer()
                    
                    Button("Show in Finder") {
                        llmManager.showModelsInFinder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 8)
            }
        }
    }
    
    private func llmModelRow(for model: LLMManager.LLMModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    Text(model.sizeDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(model.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            llmModelStatus(for: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    
    @ViewBuilder
    private func llmModelStatus(for model: LLMManager.LLMModel) -> some View {
        let state = llmManager.downloadState(for: model)
        switch state {
        case .idle, .checking:
            Button("Download") {
                Task { await llmManager.downloadModel(model) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .completed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button {
                    llmModelToDelete = model
                    showLLMDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .controlSize(.small)
            }
        case .failed(let error):
            Button("Retry") {
                Task { await llmManager.downloadModel(model) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(error)
        }
    }
}

// MARK: - Output Tab

/// Output preferences tab - configure where recordings are saved
struct OutputPreferencesTab: View {
    @Bindable var viewModel: MuesliViewModel
    @State private var showDirectoryPicker = false
    
    var body: some View {
        Form {
            Section("Recording Output Location") {
                VStack(alignment: .leading, spacing: 12) {
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
            Section("Startup") {
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
            
            Section("Transcription") {
                VStack(alignment: .leading, spacing: 12) {
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
        }
        .formStyle(.grouped)
    }
}

#Preview("Preferences") {
    let vm = MuesliViewModel()
    return PreferencesView(viewModel: vm)
}
