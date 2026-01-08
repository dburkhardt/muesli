import SwiftUI

/// Window for managing transcription models
struct ModelManagementView: View {
    @Bindable var viewModel: MuesliViewModel
    
    /// Use the viewModel's modelManager so state is shared
    private var modelManager: ModelManager {
        viewModel.modelManager
    }
    
    /// Use the viewModel's llmManager so state is shared
    private var llmManager: LLMManager {
        viewModel.llmManager
    }
    
    @State private var modelToDelete: ModelManager.ModelSize?
    @State private var showDeleteConfirmation = false
    @State private var llmModelToDelete: LLMManager.LLMModel?
    @State private var showLLMDeleteConfirmation = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Transcription Models Section
                transcriptionModelsSection
                
                Divider()
                    .padding(.horizontal)
                
                // MARK: - LLM Models Section
                llmModelsSection
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 520, height: 580)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Delete Model", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
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
            Button("Cancel", role: .cancel) {
                llmModelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let model = llmModelToDelete {
                    _ = llmManager.deleteModel(model)
                    llmModelToDelete = nil
                }
            }
        } message: {
            if let model = llmModelToDelete {
                if llmManager.activeModel == model {
                    Text("This is your active LLM model. Another model will be selected automatically.")
                } else {
                    Text("Delete this LLM model?")
                }
            }
        }
    }
    
    // MARK: - Transcription Models Section
    
    private var transcriptionModelsSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            
            Text("Transcription Models")
                .font(.system(size: 18, weight: .bold))
            
            Text("Speech-to-text models for transcription.\nLarger models are more accurate but slower.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            
            // Model list
            whisperModelListView
                .padding(.top, 4)
            
            // Active model picker (only if models are downloaded)
            if !modelManager.downloadedModels.isEmpty {
                whisperActiveModelPicker
                    .padding(.top, 4)
            }
        }
    }
    
    // MARK: - LLM Models Section
    
    private var llmModelsSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36))
                .foregroundStyle(Color.purple)
            
            Text("Text Processing")
                .font(.system(size: 18, weight: .bold))
            
            Text("Local LLM for transcript stitching and cleanup.\nImproves text flow between audio chunks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            
            // LLM model list
            llmModelListView
                .padding(.top, 4)
            
            // Active LLM model picker (only if models are downloaded)
            if !llmManager.downloadedModels.isEmpty {
                llmActiveModelPicker
                    .padding(.top, 4)
            }
            
            // Enable/disable toggle
            Toggle(isOn: Binding(
                get: { llmManager.isLLMStitchingEnabled },
                set: { llmManager.isLLMStitchingEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable LLM Stitching")
                        .font(.subheadline)
                    Text("Use AI to improve transcript text flow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .disabled(llmManager.downloadedModels.isEmpty)
        }
    }
    
    // MARK: - Whisper Model List View
    
    private var whisperModelListView: some View {
        VStack(spacing: 0) {
            ForEach(ModelManager.ModelSize.allCases) { model in
                whisperModelRowView(for: model)
                
                if model != ModelManager.ModelSize.allCases.last {
                    Divider()
                        .padding(.horizontal, 8)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private func whisperModelRowView(for model: ModelManager.ModelSize) -> some View {
        HStack {
            // Model name and size
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
            
            // Status / Action
            whisperModelStatusView(for: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func whisperModelStatusView(for model: ModelManager.ModelSize) -> some View {
        let state = modelManager.downloadState(for: model)
        
        switch state {
        case .idle, .checking:
            Button("Download") {
                Task {
                    await modelManager.downloadModel(model)
                }
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
            HStack(spacing: 8) {
                Button("Retry") {
                    Task {
                        await modelManager.downloadModel(model)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
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
            .help(error)
        }
    }
    
    // MARK: - Whisper Active Model Picker
    
    private var whisperActiveModelPicker: some View {
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
        }
        .padding(.top, 4)
    }
    
    // MARK: - LLM Model List View
    
    private var llmModelListView: some View {
        VStack(spacing: 0) {
            ForEach(LLMManager.LLMModel.allCases) { model in
                llmModelRowView(for: model)
                
                if model != LLMManager.LLMModel.allCases.last {
                    Divider()
                        .padding(.horizontal, 8)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private func llmModelRowView(for model: LLMManager.LLMModel) -> some View {
        HStack {
            // Model name and size
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if llmManager.activeModel == model {
                        Text("(Active)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(model.sizeDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                    Text(model.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Status / Action
            llmModelStatusView(for: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func llmModelStatusView(for model: LLMManager.LLMModel) -> some View {
        let state = llmManager.downloadState(for: model)
        
        switch state {
        case .idle, .checking:
            Button("Download") {
                Task {
                    await llmManager.downloadModel(model)
                }
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
                    .controlSize(.small)
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
            HStack(spacing: 8) {
                Button("Retry") {
                    Task {
                        await llmManager.downloadModel(model)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
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
            .help(error)
        }
    }
    
    // MARK: - LLM Active Model Picker
    
    private var llmActiveModelPicker: some View {
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
        }
        .padding(.top, 4)
    }
}
