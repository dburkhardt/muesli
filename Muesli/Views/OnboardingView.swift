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
    
    // MARK: - Model Compilation State
    
    /// Whether model is currently being compiled/optimized
    @State private var isCompiling = false
    
    /// Error that occurred during compilation
    @State private var compilationError: Error?
    
    /// Task for tracking compilation (for cancellation)
    @State private var compilationTask: Task<Void, Never>?
    
    /// When compilation started (to detect if model was already compiled)
    @State private var compilationStartTime: Date?
    
    /// The model currently being compiled
    @State private var compilingModel: ModelManager.ModelSize?
    
    /// Whether compilation was cancelled while user navigated away (per plan Issue 5)
    /// Used to refresh stale UI state in onAppear
    @State private var wasCompilationCancelled = false
    
    // MARK: - Background Download State
    
    /// Whether user has initiated at least one download (enables Continue button)
    @State private var userHasInitiatedDownload = false
    
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
                .padding(.top, 16)
                .padding(.bottom, 24) // Increased bottom padding to prevent dots from being cut off
        }
        .frame(width: 520, height: 600) // Slightly taller to accommodate padding
        .background(Color("OnboardingBackground"))
        .onAppear {
            // Initial permission check on appear
            Task {
                // Always use synchronous check to avoid triggering permission prompts
                viewModel.refreshPermissions()
                
                // Start monitoring on permission screens
                if currentStep == .screenRecording || currentStep == .microphone {
                    startPermissionMonitoring()
                }
                
                advanceBasedOnPermissions()
            }
        }
        .onDisappear {
            // Stop monitoring when view disappears
            stopPermissionMonitoring()
        }
        .onChange(of: currentStep) { oldValue, newValue in
            // Stop monitoring when leaving permission screens
            if oldValue == .screenRecording || oldValue == .microphone {
                stopPermissionMonitoring()
            }
            
            // Check permissions when switching to permission steps
            if newValue == .screenRecording || newValue == .microphone {
                // Use synchronous check to avoid triggering prompts
                viewModel.refreshPermissions()
                advanceBasedOnPermissions()
                // Start real-time monitoring
                startPermissionMonitoring()
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
            
            Text(
                """
                Muesli needs Screen Recording permission to capture audio from meeting apps \
                like Zoom, Teams, and Google Meet.
                """
            )
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
                        viewModel.markAwaitingScreenRecordingFromSettings()
                        viewModel.openScreenRecordingSettings()
                    }
                    .buttonStyle(.bordered)
                    
                    HoverableLink(title: "Check Again") {
                        Task {
                            await DiagnosticLogger.shared.log(.onboarding, "Check Again tapped (screen recording)")
                        }
                        // Use synchronous check to avoid triggering prompts
                        viewModel.refreshPermissions()
                    }
                }
            } else {
                // Initial state - request permission
                Button("Grant Screen Recording Access") {
                    Task {
                        await DiagnosticLogger.shared.log(.onboarding, "Grant Screen Recording Access button tapped")
                    }
                    viewModel.requestScreenRecordingPermission()
                    screenRecordingRequested = true
                    // Verify permission after request and auto-advance if granted
                    Task {
                        await DiagnosticLogger.shared.log(.onboarding, "Calling verifyScreenRecordingAfterRequest()")
                        let granted = await viewModel.verifyScreenRecordingAfterRequest()
                        await DiagnosticLogger.shared.log(.onboarding, "verifyScreenRecordingAfterRequest() returned: \(granted)")
                        if granted {
                            withAnimation { setStep(.microphone) }
                        }
                        AppDelegate.shared?.bringOnboardingWindowToFront()
                    }
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
                    
                    VStack(spacing: 8) {
                        Text("To use Muesli, please enable microphone access:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("1.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text("Click 'Open System Settings' below")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("2.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text("Find \(appName) in the Microphone list and enable it")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("3.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text("Return here and click 'Check Again'")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    
                    Button("Open System Settings") {
                        viewModel.markAwaitingMicrophoneFromSettings()
                        viewModel.openMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    HoverableLink(title: "Check Again") {
                        Task {
                            await DiagnosticLogger.shared.log(.onboarding, "Check Again tapped (microphone)")
                        }
                        // Use synchronous check to avoid triggering prompts
                        viewModel.refreshPermissions()
                    }
                    
                    Text("Don't see \(appName) in the list? Restart the app and grant permission when prompted.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
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
                    Task {
                        await DiagnosticLogger.shared.log(.onboarding, "Grant Microphone Access button tapped")
                    }
                    microphoneRequested = true
                    Task {
                        await DiagnosticLogger.shared.log(.onboarding, "Calling requestMicrophonePermission()")
                        await viewModel.requestMicrophonePermission()
                        await DiagnosticLogger.shared.log(.onboarding, "requestMicrophonePermission() returned")
                        
                        // Use synchronous refresh to update cached state
                        // requestMicrophonePermission() already handles the permission request
                        viewModel.refreshPermissions()
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
    
    /// Check if any model is downloading or ready
    private var isAnyModelDownloadingOrReady: Bool {
        modelManager.isAnyModelDownloading || modelManager.hasModel
    }
    
    private var modelSetupScreen: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            
            Text("Transcription Models")
                .font(.system(size: 22, weight: .bold))
            
            Text("Download one or more models for transcription....")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            // Model list
            modelListView
                .padding(.top, 4)
            
            // Compilation status message (shown during first-time setup)
            if isCompiling {
                VStack(spacing: 8) {
                    Text("Optimizing for your device...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("This one-time setup may take a few minutes")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }
            
            // Compilation error (shown if optimization failed)
            if let error = compilationError {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Optimization failed")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
            }
            
            // Background download message (shown when downloading and user can proceed)
            if modelManager.isAnyModelDownloading && !modelManager.hasModel {
                VStack(spacing: 4) {
                    Text("Download will continue in background")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("You can start using the app now - transcription will be available once the model is ready")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
            }
            
            // Active model picker (only if models are downloaded and not compiling)
            if !modelManager.downloadedModels.isEmpty && !isCompiling && compilationError == nil {
                activeModelPicker
                    .padding(.top, 4)
            }
            
            Spacer()
            
            Button("Continue") {
                withAnimation {
                    setStep(.llmSetup)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Enable Continue once user has initiated a download OR a model is ready
            // No longer blocks on compilation completion
            .disabled(!userHasInitiatedDownload && !modelManager.hasModel)
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .padding(.bottom, 8) // Reduced since progress indicator now has more bottom padding
        .onDisappear {
            // Cancel compilation task if user navigates away (per plan Issue 5)
            compilationTask?.cancel()
            wasCompilationCancelled = true
        }
        .onAppear {
            // Refresh stale compilation state (per plan Issue 5)
            // Case 1: User navigated away and cancelled
            if isCompiling && wasCompilationCancelled {
                isCompiling = false
                compilingModel = nil
                wasCompilationCancelled = false
            }
            
            // Case 2: Task completed but UI didn't update (defensive)
            if isCompiling && compilationTask == nil {
                isCompiling = false
                compilingModel = nil
            }
            
            // If user already has models, mark as initiated
            if modelManager.hasModel || modelManager.isAnyModelDownloading {
                userHasInitiatedDownload = true
            }
        }
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
                    .frame(width: 50)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                // Cancel button
                Button {
                    llmManager.cancelDownload(model)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
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
                Text(model.displayNameDetailed)
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
        
        // Check if this model is currently compiling
        if isCompiling && compilingModel == model {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Optimizing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let error = compilationError, compilingModel == model {
            // Compilation failed for this model
            Button("Retry") {
                compilationError = nil
                startCompilation(for: model)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(error.localizedDescription)
        } else {
            switch state {
            case .idle, .checking:
                Button("Download") {
                    userHasInitiatedDownload = true
                    Task { @MainActor in
                        await modelManager.downloadModel(model)
                        // After download completes, start compilation
                        if modelManager.downloadState(for: model) == .completed {
                            startCompilation(for: model)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
            case .downloading(let progress):
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 50)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                    // Cancel button
                    Button {
                        modelManager.cancelDownload(model)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }
                
            case .completed:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
            case .failed(let error):
                Button("Retry") {
                    userHasInitiatedDownload = true
                    Task { @MainActor in
                        await modelManager.downloadModel(model)
                        // After download completes, start compilation
                        if modelManager.downloadState(for: model) == .completed {
                            startCompilation(for: model)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(error)
            }
        }
    }
    
    // MARK: - Model Compilation
    
    /// Start compiling a model for the device
    private func startCompilation(for model: ModelManager.ModelSize) {
        // Prevent overlapping compilations (per plan Issue 3)
        guard !isCompiling else {
            // Log skipped compilation for debugging (per bdb9 review)
            print("Skipping compilation for \(model) - already compiling \(String(describing: compilingModel))")
            return
        }
        
        isCompiling = true
        compilingModel = model
        compilationStartTime = Date()
        compilationError = nil
        
        compilationTask = Task {
            do {
                try await modelManager.compileModel(model)
                
                // Check if we were cancelled while compiling (per plan Issue 5)
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    isCompiling = false
                    compilingModel = nil
                    // Model is now ready for use
                }
            } catch {
                // Check if we were cancelled while compiling (per plan Issue 5)
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    compilationError = error
                    isCompiling = false
                }
            }
        }
    }
    
    // MARK: - Active Model Picker
    
    private var activeModelPicker: some View {
        HStack {
            Text("Active Model:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Picker("", selection: Binding(
                get: { modelManager.activeModel ?? .small },
                set: { modelManager.setActiveModel($0) }
            )) {
                ForEach(modelManager.downloadedModelsOrdered) { model in
                    Text(model.displayNameDetailed).tag(model)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
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
    
    // MARK: - Permission Monitoring
    
    /// Start real-time permission monitoring
    private func startPermissionMonitoring() {
        // Set up callback for instant updates
        viewModel.permissionManager.permissionDidChange = { [weak viewModel] _, _ in
            Task { @MainActor in
                guard let viewModel = viewModel else { return }
                
                // Update viewModel state using synchronous refresh
                // The monitoring mechanism now uses only sync checks to avoid triggering prompts
                viewModel.refreshPermissions()
                
                // Auto-advance if permission granted
                self.advanceBasedOnPermissions()
            }
        }
        
        // Start monitoring
        viewModel.permissionManager.startMonitoringPermissions()
    }
    
    /// Stop permission monitoring
    private func stopPermissionMonitoring() {
        viewModel.permissionManager.stopMonitoringPermissions()
        viewModel.permissionManager.permissionDidChange = nil
    }
    
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
        Task {
            await DiagnosticLogger.shared.log(.onboarding, "Step transition: \(currentStep.rawValue) → \(step.rawValue)")
        }
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
