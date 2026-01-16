import SwiftUI

/// Multi-step onboarding flow for first-run setup
struct OnboardingView: View {
    @Bindable var viewModel: MuesliViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    
    /// Use the viewModel's modelManager so state is shared
    private var modelManager: ModelManager {
        viewModel.modelManager
    }
    
    /// Use the viewModel's llmManager for LLM model downloads
    private var llmManager: LLMManager {
        viewModel.llmManager
    }
    @State private var currentStep: OnboardingStep
    @State private var showFilePicker = false
    
    // Using centralized AppStorageKeys for onboarding state
    
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Muesli"
    }
    
    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case screenRecording = 1
        case microphone = 2
        case modelSetup = 3
        case llmSetup = 4
    }
    
    init(viewModel: MuesliViewModel) {
        self.viewModel = viewModel
        // Restore saved step, defaulting to welcome
        let savedStep = UserDefaults.standard.integer(forKey: AppStorageKeys.onboardingCurrentStep)
        _currentStep = State(initialValue: OnboardingStep(rawValue: savedStep) ?? .welcome)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Content area
            Group {
                switch currentStep {
                case .welcome:
                    welcomeScreen
                case .screenRecording:
                    screenRecordingScreen
                case .microphone:
                    microphoneScreen
                case .modelSetup:
                    modelSetupScreen
                case .llmSetup:
                    llmSetupScreen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Progress indicator - always at bottom
            progressIndicator
                .padding(.vertical, 16)
        }
        .frame(width: 520, height: 580) // Larger window to fit all content
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Initial permission check on appear
            Task {
                // If we're past the welcome screen, use async permission check
                // This is reliable and won't trigger a prompt if permission is already granted
                // Only on welcome screen do we avoid async check to prevent prompts
                if currentStep != .welcome {
                    await viewModel.refreshPermissionsAsync()
                } else {
                    viewModel.refreshPermissions()
                }
                advanceBasedOnPermissions()
            }
        }
        .onChange(of: currentStep) { oldValue, newValue in
            // Check permissions when switching to permission steps
            // Use async check for reliable detection after granting permission
            if newValue == .screenRecording || newValue == .microphone {
                Task {
                    await viewModel.refreshPermissionsAsync()
                    advanceBasedOnPermissions()
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }
    
    // MARK: - Progress Indicator
    
    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }
    
    // MARK: - Welcome Screen
    
    private var welcomeScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.accentColor)
            
            Text("Welcome to \(appName)")
                .font(.system(size: 28, weight: .bold))
            
            Text("Local meeting transcription for macOS.\nYour audio never leaves your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            
            Spacer()
            
            Button("Get Started") {
                withAnimation {
                    setStep(.screenRecording)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 60)
        .padding(.top, 40)
        .padding(.bottom, 24)
    }
    
    // MARK: - Screen Recording Screen
    
    @State private var screenRecordingRequested = false
    
    private var screenRecordingScreen: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor)
            
            Text("Screen Recording Access")
                .font(.system(size: 24, weight: .bold))
            
            Text("Muesli needs Screen Recording permission to capture audio from meeting apps like Zoom, Teams, and Google Meet.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            
            Spacer()
            
            if viewModel.hasScreenRecordingPermission {
                // Permission granted
                permissionStatusView(granted: true, label: "Screen Recording")
            } else if screenRecordingRequested {
                // Permission was requested but not granted - show recovery options
                VStack(spacing: 12) {
                    Text("Waiting for permission...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("If you accidentally denied permission, you can grant it in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Open System Settings") {
                        viewModel.openScreenRecordingSettings()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Try Again") {
                        viewModel.requestScreenRecordingPermission()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }
            } else {
                // Initial state - request permission
                Button("Grant Screen Recording Access") {
                    viewModel.requestScreenRecordingPermission()
                    screenRecordingRequested = true
                    // Bring onboarding window back to front after system dialog dismisses
                    AppDelegate.shared?.bringOnboardingWindowToFront()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                permissionStatusView(granted: false, label: "Screen Recording")
            }
            
            Spacer()
            
            Button("Continue") {
                withAnimation {
                    setStep(.microphone)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.hasScreenRecordingPermission)
        }
        .padding(.horizontal, 60)
        .padding(.top, 40)
        .padding(.bottom, 24)
    }
    
    // MARK: - Microphone Screen
    
    @State private var microphoneRequested = false
    
    private var microphoneScreen: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor)
            
            Text("Microphone Access")
                .font(.system(size: 24, weight: .bold))
            
            Text("Muesli needs Microphone permission to capture your voice during meetings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            
            Spacer()
            
            if viewModel.hasMicrophonePermission {
                // Permission granted
                permissionStatusView(granted: true, label: "Microphone")
            } else if viewModel.isMicrophonePermissionDenied {
                // Permission was denied - show recovery options
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Permission Denied")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    
                    Text("Microphone access was denied. To use Muesli, please grant permission in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Open System Settings") {
                        viewModel.openMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else if microphoneRequested {
                // Permission was requested but response pending
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Waiting for permission...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Initial state - request permission
                Button("Grant Microphone Access") {
                    microphoneRequested = true
                    Task {
                        await viewModel.requestMicrophonePermission()
                        microphoneRequested = false
                        // Bring onboarding window back to front after system dialog dismisses
                        AppDelegate.shared?.bringOnboardingWindowToFront()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                permissionStatusView(granted: false, label: "Microphone")
            }
            
            Spacer()
            
            Button("Continue") {
                withAnimation {
                    setStep(.modelSetup)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.hasMicrophonePermission)
        }
        .padding(.horizontal, 60)
        .padding(.top, 40)
        .padding(.bottom, 24)
    }
    
    // MARK: - Model Setup Screen
    
    private var modelSetupScreen: some View {
        VStack(spacing: 16) {
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
            
            // Model list
            modelListView
                .padding(.top, 8)
            
            // Active model picker (only if models are downloaded)
            if !modelManager.downloadedModels.isEmpty {
                activeModelPicker
                    .padding(.top, 8)
            }
            
            Spacer()
            
            Button("Continue") {
                withAnimation {
                    setStep(.llmSetup)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!modelManager.hasModel)
        }
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .padding(.bottom, 24)
    }
    
    // MARK: - LLM Setup Screen
    
    private var llmSetupScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 50))
                .foregroundStyle(Color.accentColor)
            
            Text("Text Processing (Optional)")
                .font(.system(size: 24, weight: .bold))
            
            Text("Download an AI model to improve transcript quality\nby intelligently merging audio chunks.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            
            // LLM model list
            llmModelListView
                .padding(.top, 8)
            
            Text("This is optional - transcription works without it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            Spacer()
            
            HStack(spacing: 16) {
                Button("Skip for Now") {
                    completeOnboarding()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button("Finish Setup") {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .padding(.bottom, 24)
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
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    Text(model.sizeDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Link(model.sourceRepo, destination: model.sourceURL)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Status / Action
            llmModelStatusView(for: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                    .scaleEffect(0.7)
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
        case .failed(let error):
            Button("Retry") {
                Task {
                    await llmManager.downloadModel(model)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(error)
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
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                Text(model.sizeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Link(model.sourceRepo, destination: model.sourceURL)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
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
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
        case .failed(let error):
            Button("Retry") {
                Task {
                    await modelManager.downloadModel(model)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
                ForEach(modelManager.downloadedModelsOrdered) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
        }
        .padding(.top, 4)
    }
    
    // MARK: - Permission Status View
    
    private func permissionStatusView(granted: Bool, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            
            Text(granted ? "\(label) granted" : "Waiting for \(label)...")
                .font(.subheadline)
                .foregroundStyle(granted ? .primary : .secondary)
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Permission Polling
    
    // MARK: - File Selection
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            _ = modelManager.useExistingModel(at: url)
        case .failure:
            // User cancelled or error - just ignore
            break
        }
    }
    
    // MARK: - Step Management
    
    private func setStep(_ step: OnboardingStep) {
        currentStep = step
        UserDefaults.standard.set(step.rawValue, forKey: AppStorageKeys.onboardingCurrentStep)
    }
    
    /// Advance to appropriate step based on current permissions
    /// Skips past already-completed permission steps when user returns to the app
    private func advanceBasedOnPermissions() {
        // Determine the appropriate step based on current permissions
        let targetStep: OnboardingStep
        
        if viewModel.hasScreenRecordingPermission && viewModel.hasMicrophonePermission {
            // All permissions granted - go to model setup or complete
            if !modelManager.hasModel {
                targetStep = .modelSetup
            } else if !llmManager.hasModel {
                targetStep = .llmSetup
            } else {
                // All done - complete onboarding
                completeOnboarding()
                return
            }
        } else if viewModel.hasScreenRecordingPermission {
            // Screen recording granted - skip to microphone
            targetStep = .microphone
        } else {
            // No permissions yet - stay on current step (don't auto-advance from welcome)
            return
        }
        
        // Only advance forward, never backward
        if targetStep.rawValue > currentStep.rawValue {
            setStep(targetStep)
        }
    }
    
    // MARK: - Complete Onboarding
    
    private func completeOnboarding() {
        viewModel.completeOnboarding()
        
        // Clear saved step
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.onboardingCurrentStep)
        
        // Notify AppDelegate to handle window transition
        // This ensures the main window opens properly
        AppDelegate.shared?.completeOnboarding()
    }
}
