import SwiftUI

/// Flexible content view for managing transcription models
/// Used both in standalone window and embedded in preferences
struct ModelManagementContent: View {
    @Bindable var viewModel: MuesliViewModel
    
    /// Whether to show the header (icon + title). Set to false when embedded in preferences.
    var showHeader: Bool = true
    
    /// Use the viewModel's modelManager so state is shared
    private var modelManager: ModelManager {
        viewModel.modelManager
    }
    
    @State private var modelToDelete: ModelManager.ModelSize?
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        VStack(spacing: 16) {
            if showHeader {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 50))
                    .foregroundStyle(Color.accentColor)
                
                Text("Transcription Models")
                    .font(.system(size: 24, weight: .bold))
                
                Text("Download one or more models for transcription.\nLarger models are more accurate but slower.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            
            // Model list
            modelListView
                .padding(.top, showHeader ? 8 : 0)
            
            // Active model picker (only if models are downloaded)
            if !modelManager.downloadedModels.isEmpty {
                activeModelPicker
                    .padding(.top, 8)
            }
            
            Spacer()
            
            // Show in Finder button
            Button("Show in Finder") {
                modelManager.showModelsInFinder()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
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
    }
    
    // MARK: - Model List View
    
    private var modelListView: some View {
        VStack(spacing: 0) {
            ForEach(ModelManager.ModelSize.allCases) { model in
                modelRowView(for: model)
                
                if model != ModelManager.ModelSize.allCases.last {
                    Divider()
                        .padding(.horizontal, 8)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private func modelRowView(for model: ModelManager.ModelSize) -> some View {
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
            modelStatusView(for: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func modelStatusView(for model: ModelManager.ModelSize) -> some View {
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
    
    // MARK: - Active Model Picker
    
    private var activeModelPicker: some View {
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
}

// MARK: - Standalone Window Wrapper

/// Standalone window for managing transcription models
/// Wraps ModelManagementContent with fixed sizing for dedicated window use
struct ModelManagementView: View {
    @Bindable var viewModel: MuesliViewModel
    
    var body: some View {
        ModelManagementContent(viewModel: viewModel, showHeader: true)
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(width: 520, height: 580)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(alignment: .topTrailing) {
                WorkTreeBadge()
            }
    }
}
