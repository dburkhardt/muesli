# TODO & Future Features

This file tracks features, improvements, and fixes to implement later.

## Format
Each item should include:
- **Category** (Feature/Enhancement/Bug/Refactor)
- **Priority** (High/Medium/Low)
- **Description**
- **Notes** (optional context)

---

## Backlog

### Features

**[Feature]** [Medium] Add automatic speaker detection
- Description: Implement automatic speaker detection to identify and label different speakers in the transcript
- Notes: Research speaker diarization techniques compatible with WhisperKit or as post-processing step

**[Feature]** [Medium] Add database structure for searchable meeting notes
- Description: Create a database structure that makes searching meeting notes possible, with MCP server integration
- Notes: Consider SQLite or other embedded database options for indexing transcripts and metadata
- MCP Integration: Expose transcript data via Model Context Protocol so other local tools can query and access meeting information
- Related: Research MCP server implementation patterns for Swift

**[Feature]** [Low] Create Google Drive integration for cloud syncing
- Description: Add integration into Google Drive to enable cloud syncing of recordings and transcripts
- Notes: Requires OAuth setup, API integration, and user preference for opt-in

**[Feature]** [Low] Add option to use cloud transcription APIs
- Description: Provide alternative to local WhisperKit transcription using cloud APIs (e.g., OpenAI Whisper API, Google Speech-to-Text)
- Notes: Should be opt-in preference, requires API key management

**[Feature]** [Medium] Add Outlook calendar integration
- Description: Integrate with local Outlook app to automatically link recordings to calendar events
- Notes: Must work locally without cloud API access - use macOS scripting bridge or AppleScript to access Outlook data
- Implementation: Detect Outlook.app running locally, query calendar via ScriptingBridge, match meeting times to recordings
- Related: Similar pattern to MeetingAppDetector.swift, requires Outlook.app to be open

### Enhancements

**[Enhancement]** [Medium] Add visuals to website
- Description: Add screenshots, GIFs, or videos demonstrating the app in action to the website
- Notes: Show key features like onboarding, recording in progress, transcript view, meeting history
- Consider animated GIF of full workflow or individual screenshots for each major feature
- Related: docs/index.html, docs/assets/
- Status: UI test infrastructure created in v0.1.2, screenshots can be generated from tests

**[Enhancement]** [High] Capture and publish app screenshots for website
- Description: Execute UI tests to capture screenshots and add them to website
- Notes: Now that UI test infrastructure exists, run screenshot tests and publish results
  - Run MuesliUITests in both light and dark modes
  - Capture: onboarding flow, recording in progress, transcript view, meeting history, preferences
  - Optimize images for web (compress, proper dimensions)
  - Add to docs/assets/screenshots/
  - Update docs/index.html to display screenshots
- Commands:
  - Run tests: xcodebuild test -scheme Muesli -testPlan MuesliUITests
  - Screenshots saved to: ~/Library/Developer/Xcode/DerivedData/.../Attachments/
- Related: MuesliUITests/, docs/index.html, docs/assets/screenshots/

**[Enhancement]** [Low] Make reprocessing chunk size configurable in preferences
- Description: Add preference setting to allow users to configure chunk size specifically for reprocessing transcripts
- Notes: Currently reprocessing uses the same audio chunk duration setting as live recording. Consider whether to use the same setting or add a separate "reprocessing chunk duration" preference
- May want different chunk sizes for reprocessing vs live recording (e.g., larger chunks for better accuracy when latency doesn't matter)
- Related: PreferencesView.swift, PreferencesManager.swift, RecordingDetailView.swift, CompletedMeetingWindow.swift

### Bugs

*No items - All high-priority bugs fixed in v0.1.2*

### Refactoring

**[Refactor]** [Low] Enforce SwiftLint in CI
- Description: Fix all existing lint violations and remove continue-on-error from CI
- Notes: Currently advisory only. Need baseline cleanup first before enforcing strict mode.
- Related: .swiftlint.yml, .github/workflows/ci.yml

**[Refactor]** [Low] Use GitHub milestones and project plans for release management
- Description: Implement GitHub milestones and project plans to better organize and track release cycles
- Notes: Would provide better visibility into what features/fixes are planned for each release version, integrate with PR workflow
- Related: .github/workflows/release.yml, git_workflow.md

**[Refactor]** [Medium] Investigate sandboxed build and launch for agent testing
- Description: Research and implement ways to build and launch the app in a sandbox environment that AI agents can interact with
- Notes: Would enable agents to test permission flows, inspect UI for visual errors, verify onboarding screens, and test recording functionality
- Potential approaches: Headless testing frameworks, UI automation APIs, screenshot comparison tools, virtual display environments
- Related: Testing infrastructure, CI/CD workflows

**[Refactor]** [Medium] Create integration tests with paired audio/transcript fixtures
- Description: Build test suite that uses known audio files with expected transcripts to verify end-to-end transcription accuracy
- Notes: Create fixture directory with sample audio files (CAF format) and their expected transcript outputs
- Tests should verify: audio processing pipeline, transcription accuracy, timestamp generation, file output format
- Related: MuesliTests/, TranscriptionService.swift, AudioCaptureService.swift

**[Refactor]** [Medium] Create testing instruction generator for releases/branches
- Description: Add automated mechanism to generate clear, user-friendly testing instructions based on branch changes or release version
- Notes: Should analyze git diff or CHANGELOG and create structured test plan with:
  - What changed (user-facing features/fixes)
  - Step-by-step testing instructions
  - Expected behavior/results
  - Edge cases to check
- Potential approaches:
  - Script that parses CHANGELOG.md and generates test-instructions.md
  - GitHub Actions workflow to auto-generate testing checklist on PR/release
  - Template in docs/ that gets populated with release-specific instructions
- Would help QA testing and pre-release validation
- Related: CHANGELOG.md, spec/*, AGENTS.md release checklist

**[Refactor]** [Medium] Mutation testing with Muter
- Description: Implement mutation testing to measure test quality, not just coverage
- Notes: Muter introduces small mutations to code and verifies tests catch them
- Helps identify weak tests that have high coverage but don't actually validate behavior
- Related: https://github.com/muter-mutation-testing/muter
- Integration: Could run as part of CI or as manual quality check before releases

**[Refactor]** [Low] Coverage-guided test generation using AI tools
- Description: Explore AI-powered tools to automatically generate tests for uncovered code paths
- Notes: Could use LLM-based test generation tools to identify gaps and suggest test cases
- Should complement manual testing, not replace it
- Focus on edge cases and error paths that are easy to miss
- Related: Testing infrastructure, CI/CD workflows

**[Refactor]** [Medium] Update agent instructions for test execution
- Description: Clarify in AGENTS.md how agents should run tests, capture results, and extract information efficiently
- Notes: Should cover:
  - Running tests with output capture (tee vs direct output)
  - Extracting specific test results (grep patterns for failures, specific tests)
  - Best practices for test iteration (avoid re-running just to see different output)
  - Understanding XCTest output format
- Would improve agent efficiency and reduce unnecessary test runs
- Related: AGENTS.md, MuesliTests/, test execution workflows

**[Refactor]** [Low] Create commands/ directory with common agent commands
- Description: Add commands/ directory containing commonly used command scripts for agents
- Notes: Could include:
  - build.sh - Standard build command with timestamp
  - test.sh - Run tests with proper output capture
  - clean-build.sh - Clean and rebuild
  - launch.sh - Kill and relaunch app
  - full-cycle.sh - Build, test, launch in one command
- Makes it easier for agents to execute common workflows
- Related: AGENTS.md, scripts/

---

## Test Coverage Initiative - Road to 70%

**Current Status:** 9.98% coverage (2,138 / 21,419 lines)
**Target:** 70%+ coverage (14,993+ lines)
**Gap:** 12,854 lines need coverage

Each task below is designed to be completable by a single agent in one session. Run `./scripts/generate-coverage.sh` after each task to track progress.

### Phase 1: Critical Services (Target: 25% overall)

**[Test]** [Critical] AudioCaptureService - System Audio Tests (Part 1/3)
- Description: Create AudioCaptureServiceTests.swift with basic initialization and configuration tests
- Tests to add (~15 tests):
  - Service initialization
  - Buffer handler configuration
  - Interrupted handler configuration
  - Level handler configuration
  - Microphone device selection
  - Error cases (handler not set, already recording, not recording)
- Coverage target: AudioCaptureService.swift 30% → 50%
- Files: Create MuesliTests/AudioCaptureServiceTests.swift

**[Test]** [Critical] AudioCaptureService - Stream Lifecycle Tests (Part 2/3)
- Description: Add tests for stream start/stop/interruption lifecycle
- Tests to add (~15 tests):
  - Start capture for all system audio
  - Start capture for specific app bundle identifier
  - Stop capture successfully
  - Handle stream interruption
  - Handle app not found error
  - Handle no display error
  - Concurrent start attempts (should error)
  - Stop when not recording (should error)
- Coverage target: AudioCaptureService.swift 50% → 70%
- Files: Expand MuesliTests/AudioCaptureServiceTests.swift

**[Test]** [Critical] AudioCaptureService - Audio Processing Tests (Part 3/3)
- Description: Add tests for audio buffer processing and level calculation
- Tests to add (~15 tests):
  - Audio buffer handling (system and microphone)
  - RMS level calculation for Float32 (system audio)
  - RMS level calculation for Int16 (microphone audio)
  - Level normalization (0-1 range)
  - Invalid buffer handling
  - Empty buffer handling
  - Audio format detection
  - Concurrent audio processing
- Coverage target: AudioCaptureService.swift 70% → 85%
- Files: Expand MuesliTests/AudioCaptureServiceTests.swift

**[Test]** [Critical] TranscriptionService - Initialization Tests (Part 1/4)
- Description: Create TranscriptionServiceTests.swift with initialization and configuration tests
- Tests to add (~15 tests):
  - Service initialization
  - WhisperKit initialization
  - Model loading and validation
  - Configuration settings (sample rate, language)
  - Transcription mode selection (live vs batch)
  - Progress callback setup
  - Segment callback setup
  - Error handling (model not found, invalid config)
- Coverage target: TranscriptionService.swift 3% → 20%
- Files: Create MuesliTests/TranscriptionServiceTests.swift

**[Test]** [Critical] TranscriptionService - Audio Processing Tests (Part 2/4)
- Description: Add tests for audio buffer resampling and format conversion
- Tests to add (~15 tests):
  - Resample 48kHz to 16kHz (system audio)
  - Resample 48kHz to 16kHz (microphone)
  - Stereo to mono conversion
  - Float32 to Int16 conversion
  - Buffer size validation
  - Empty buffer handling
  - Invalid sample rate handling
  - Format description validation
- Coverage target: TranscriptionService.swift 20% → 40%
- Files: Expand MuesliTests/TranscriptionServiceTests.swift

**[Test]** [Critical] TranscriptionService - Transcription Pipeline Tests (Part 3/4)
- Description: Add tests for transcription execution and segment generation
- Tests to add (~15 tests):
  - Start transcription pipeline
  - Process audio chunks
  - Generate transcript segments
  - Timestamp calculation and formatting
  - Speaker detection and labeling
  - Language detection
  - Transcription quality settings
  - Stop transcription
- Coverage target: TranscriptionService.swift 40% → 65%
- Files: Expand MuesliTests/TranscriptionServiceTests.swift

**[Test]** [Critical] TranscriptionService - Error Handling Tests (Part 4/4)
- Description: Add tests for error scenarios and edge cases
- Tests to add (~10 tests):
  - Model not loaded error
  - Invalid audio format error
  - Transcription timeout
  - Memory pressure handling
  - Silent audio handling
  - Background noise handling
  - Very long audio streams
  - Concurrent transcription attempts
- Coverage target: TranscriptionService.swift 65% → 85%
- Files: Expand MuesliTests/TranscriptionServiceTests.swift

**[Test]** [Critical] FileOutputService - Directory Management Tests (Part 1/3)
- Description: Create FileOutputServiceTests.swift with directory creation and structure tests
- Tests to add (~12 tests):
  - Recording directory creation
  - Directory naming (timestamp + UUID)
  - Output directory preference handling
  - Directory permissions validation
  - Cleanup on cancelled recording
  - Directory already exists handling
  - Invalid path handling
  - Disk space checking
- Coverage target: FileOutputService.swift 3% → 30%
- Files: Create MuesliTests/FileOutputServiceTests.swift

**[Test]** [Critical] FileOutputService - Audio File Writing Tests (Part 2/3)
- Description: Add tests for audio file (CAF) writing operations
- Tests to add (~12 tests):
  - Write system audio to audio.caf
  - Write microphone audio to microphone.caf
  - CAF format validation
  - Audio format preservation (48kHz stereo Float32)
  - Concurrent file writes
  - Large file handling
  - File write error handling (disk full)
  - File corruption prevention (atomic writes)
- Coverage target: FileOutputService.swift 30% → 60%
- Files: Expand MuesliTests/FileOutputServiceTests.swift

**[Test]** [Critical] FileOutputService - Transcript Writing Tests (Part 3/3)
- Description: Add tests for transcript markdown generation and writing
- Tests to add (~12 tests):
  - Generate transcript.md with timestamps
  - Markdown formatting (headings, timestamps, speaker labels)
  - Unicode handling in transcript text
  - Empty transcript handling
  - Very long transcript handling
  - Metadata preservation (duration, date)
  - File write permissions
  - Resume/append operations
- Coverage target: FileOutputService.swift 60% → 85%
- Files: Expand MuesliTests/FileOutputServiceTests.swift

**[Test]** [Critical] RecordingController - Lifecycle Tests (Part 1/3)
- Description: Expand RecordingControllerTests.swift with complete lifecycle tests
- Tests to add (~18 tests):
  - Create new recording session
  - Start recording (happy path)
  - Stop recording successfully
  - Save recording with title
  - Discard recording
  - Cancel recording (error state)
  - Multiple start attempts (should block)
  - Session state transitions
  - Active session tracking
- Coverage target: RecordingController.swift 8% → 30%
- Files: Expand MuesliTests/RecordingControllerTests.swift

**[Test]** [Critical] RecordingController - Integration Tests (Part 2/3)
- Description: Add tests for service coordination and data flow
- Tests to add (~18 tests):
  - Audio service coordination
  - Transcription service coordination
  - File output service coordination
  - Audio buffer routing (system + microphone)
  - Progress tracking and updates
  - Error propagation from services
  - Service cleanup on stop
  - Memory management during recording
- Coverage target: RecordingController.swift 30% → 55%
- Files: Expand MuesliTests/RecordingControllerTests.swift

**[Test]** [Critical] RecordingController - Edge Cases Tests (Part 3/3)
- Description: Add tests for error scenarios and edge cases
- Tests to add (~18 tests):
  - Microphone mute/unmute handling
  - Permission denied during recording
  - Service failure recovery
  - State machine error handling
  - Concurrent operation prevention
  - Long recording stability
  - Session management edge cases
  - Cleanup verification (no leaks)
- Coverage target: RecordingController.swift 55% → 80%
- Files: Expand MuesliTests/RecordingControllerTests.swift

### Phase 2: Controllers & Managers (Target: 45% overall)

**[Test]** [High] ModelManager - Model Discovery Tests (Part 1/2)
- Description: Expand ModelManagerTests.swift with model discovery and selection tests
- Tests to add (~12 tests):
  - Available models discovery
  - Model selection and persistence
  - Model validation
  - Default model selection
  - Model switching
  - Model metadata retrieval
- Coverage target: ModelManager.swift 30% → 60%
- Files: Expand MuesliTests/ModelManagerTests.swift

**[Test]** [High] ModelManager - Download Management Tests (Part 2/2)
- Description: Add tests for model download and caching
- Tests to add (~15 tests):
  - Model download initiation
  - Download progress tracking
  - Download cancellation
  - Download error handling (network failure)
  - Download retry logic
  - Disk space management
  - Cache validation
  - Concurrent download prevention
  - Downloaded model verification
- Coverage target: ModelManager.swift 60% → 85%
- Files: Expand MuesliTests/ModelManagerTests.swift

**[Test]** [High] PermissionManager - Permission Checking Tests (Part 1/2)
- Description: Create PermissionManagerTests.swift with permission checking tests
- Tests to add (~12 tests):
  - Check screen recording permission
  - Check microphone permission
  - Permission state caching
  - Async permission verification
  - Permission state changes detection
  - TCC permission checking
- Coverage target: PermissionManager.swift 18% → 55%
- Files: Create MuesliTests/PermissionManagerTests.swift

**[Test]** [High] PermissionManager - Permission Request Tests (Part 2/2)
- Description: Add tests for permission request flows and error handling
- Tests to add (~10 tests):
  - Request screen recording permission
  - Request microphone permission
  - Handle permission denied
  - Handle permission granted
  - Permission prompt display
  - Error handling for permission APIs
- Coverage target: PermissionManager.swift 55% → 85%
- Files: Expand MuesliTests/PermissionManagerTests.swift

**[Test]** [High] MicrophoneManager - Device Management Tests
- Description: Create MicrophoneManagerTests.swift with device enumeration and selection tests
- Tests to add (~18 tests):
  - Enumerate available microphones
  - Default device selection
  - Device selection by ID
  - Device name retrieval
  - Device UID retrieval
  - Device availability checking
  - Hotplug detection (device added)
  - Hotplug detection (device removed)
  - Handle no devices available
  - Device property queries
  - Device state changes
  - Invalid device ID handling
- Coverage target: MicrophoneManager.swift 9% → 85%
- Files: Create MuesliTests/MicrophoneManagerTests.swift

**[Test]** [High] PreferencesManager - Additional Tests
- Description: Expand PreferencesManagerTests.swift with comprehensive preference tests
- Tests to add (~18 tests):
  - All preference key getters/setters
  - Default value verification
  - Persistence across app restarts
  - Migration from old preference keys
  - Thread safety verification (expanded)
  - Invalid value handling
  - Preference change notifications
  - UserDefaults synchronization
- Coverage target: PreferencesManager.swift 56% → 90%
- Files: Expand MuesliTests/PreferencesManagerTests.swift

**[Test]** [High] MeetingHistoryService - Directory Scanning Tests (Part 1/2)
- Description: Create MeetingHistoryServiceTests.swift with recording discovery tests
- Tests to add (~18 tests):
  - Scan recordings directory
  - Parse recording directory structure
  - Extract meeting metadata (date, time, title)
  - Validate recording directories
  - Handle invalid directories
  - Handle missing transcript files
  - Handle corrupted files
  - Performance with many recordings
- Coverage target: MeetingHistoryService.swift 8% → 45%
- Files: Create MuesliTests/MeetingHistoryServiceTests.swift

**[Test]** [High] MeetingHistoryService - Operations Tests (Part 2/2)
- Description: Add tests for meeting operations and data management
- Tests to add (~15 tests):
  - Load transcript for meeting
  - Search meetings by text
  - Filter meetings by date
  - Sort meetings (by date, name)
  - Delete single meeting
  - Delete multiple meetings
  - Cache management
  - Handle concurrent operations
- Coverage target: MeetingHistoryService.swift 45% → 80%
- Files: Expand MuesliTests/MeetingHistoryServiceTests.swift

### Phase 3: Coordinators & Supporting Services (Target: 60% overall)

**[Test]** [Medium] TranscriptionCoordinator - State Management Tests
- Description: Expand TranscriptionCoordinatorTests.swift with comprehensive state tests
- Tests to add (~22 tests):
  - Initial state (notReady)
  - Model preparation flow
  - State transition to preparing
  - State transition to ready
  - Audio buffering when notReady
  - Audio forwarding when ready
  - Buffer flush on ready transition
  - Error handling in each state
  - Concurrent audio chunks
  - State machine validation
- Coverage target: TranscriptionCoordinator.swift → 85%
- Files: Expand MuesliTests/TranscriptionCoordinatorTests.swift

**[Test]** [Medium] RefinementCoordinator - Coordination Tests (Part 1/2)
- Description: Create RefinementCoordinatorTests.swift with state management tests
- Tests to add (~15 tests):
  - Refinement state initialization
  - Check refinement availability
  - Start refinement process
  - Toggle between original/refined transcript
  - Refinement progress tracking
  - Handle refinement not available
  - State persistence
- Coverage target: RefinementCoordinator.swift 9% → 50%
- Files: Create MuesliTests/RefinementCoordinatorTests.swift

**[Test]** [Medium] RefinementCoordinator - LLM Integration Tests (Part 2/2)
- Description: Add tests for LLM interaction and error handling
- Tests to add (~12 tests):
  - LLM manager coordination
  - Refinement cancellation
  - Error handling (LLM failure)
  - Retry logic
  - Refinement quality validation
  - Memory management
- Coverage target: RefinementCoordinator.swift 50% → 80%
- Files: Expand MuesliTests/RefinementCoordinatorTests.swift

**[Test]** [Medium] TranscriptRefinementService - Prompt Generation Tests (Part 1/2)
- Description: Create TranscriptRefinementServiceTests.swift with prompt and API tests
- Tests to add (~18 tests):
  - Generate refinement prompt
  - Prompt formatting
  - Context inclusion
  - API request formation
  - API response parsing
  - Handle API errors
  - Rate limiting
  - Retry logic
  - Timeout handling
- Coverage target: TranscriptRefinementService.swift 2% → 40%
- Files: Create MuesliTests/TranscriptRefinementServiceTests.swift

**[Test]** [Medium] TranscriptRefinementService - Refinement Quality Tests (Part 2/2)
- Description: Add tests for refinement processing and quality validation
- Tests to add (~15 tests):
  - Process refined transcript
  - Quality validation
  - Caching refined results
  - Handle empty responses
  - Handle malformed responses
  - Preserve formatting
  - Handle special characters
  - Large transcript handling
- Coverage target: TranscriptRefinementService.swift 40% → 75%
- Files: Expand MuesliTests/TranscriptRefinementServiceTests.swift

**[Test]** [Medium] LLMManager - Model Management Tests (Part 1/2)
- Description: Create LLMManagerTests.swift with model loading and configuration tests
- Tests to add (~15 tests):
  - Model loading
  - Model configuration
  - Model validation
  - Model switching
  - Memory management
  - Model availability checking
  - Error handling (model not found)
- Coverage target: LLMManager.swift 9% → 45%
- Files: Create MuesliTests/LLMManagerTests.swift

**[Test]** [Medium] LLMManager - Prompt Processing Tests (Part 2/2)
- Description: Add tests for prompt processing and response generation
- Tests to add (~12 tests):
  - Process prompts
  - Generate responses
  - Handle streaming responses
  - Temperature and parameter settings
  - Token limit handling
  - Error handling
  - Concurrent requests
- Coverage target: LLMManager.swift 45% → 75%
- Files: Expand MuesliTests/LLMManagerTests.swift

**[Test]** [Medium] TranscriptProcessor - Parsing Tests (Part 1/2)
- Description: Create TranscriptProcessorTests.swift with transcript parsing tests
- Tests to add (~12 tests):
  - Parse WhisperKit segments
  - Extract timestamps
  - Format timestamps
  - Detect speakers
  - Generate transcript blocks
  - Handle overlapping segments
- Coverage target: TranscriptProcessor.swift 17% → 50%
- Files: Create MuesliTests/TranscriptProcessorTests.swift

**[Test]** [Medium] TranscriptProcessor - Processing Tests (Part 2/2)
- Description: Add tests for transcript processing and validation
- Tests to add (~10 tests):
  - Filter hallucinations
  - Clean up filler words
  - Format validation
  - Handle empty segments
  - Handle special characters
  - Merge similar segments
- Coverage target: TranscriptProcessor.swift 50% → 80%
- Files: Expand MuesliTests/TranscriptProcessorTests.swift

**[Test]** [Medium] RecordingStateMachine - State Tests
- Description: Create RecordingStateMachineTests.swift with comprehensive state machine tests
- Tests to add (~18 tests):
  - All valid state transitions
  - Invalid transition rejection
  - State callbacks
  - Concurrent state access
  - Error states
  - State persistence
  - Reset to initial state
  - Transition history
- Coverage target: RecordingStateMachine.swift 32% → 85%
- Files: Create MuesliTests/RecordingStateMachineTests.swift

### Phase 4: Supporting Services & Final Push (Target: 70%+ overall)

**[Test]** [Medium] EchoCancellationService - AEC Tests
- Description: Create EchoCancellationServiceTests.swift with echo cancellation tests
- Tests to add (~15 tests):
  - AEC initialization
  - Process audio buffers
  - Echo detection
  - Echo reduction
  - Configuration settings
  - Enable/disable AEC
  - Performance metrics
  - Error handling
- Coverage target: EchoCancellationService.swift 0% → 70%
- Files: Create MuesliTests/EchoCancellationServiceTests.swift

**[Test]** [Low] UpdateChecker - Update Check Tests
- Description: Create UpdateCheckerTests.swift with version checking tests
- Tests to add (~12 tests):
  - Check for updates
  - Parse version numbers
  - Compare versions
  - Download metadata
  - Handle no updates available
  - Handle network errors
  - Update availability notification
  - Skip version handling
- Coverage target: UpdateChecker.swift 2% → 70%
- Files: Create MuesliTests/UpdateCheckerTests.swift

**[Test]** [Medium] MeetingAppDetector - Detection Tests
- Description: Expand MeetingAppDetectorTests.swift with comprehensive app detection tests
- Tests to add (~10 tests):
  - Detect running meeting apps
  - Zoom detection
  - Teams detection
  - Google Meet detection
  - Multiple apps running
  - No apps running
  - App launch detection
  - App quit detection
- Coverage target: MeetingAppDetector.swift 79% → 90%
- Files: Expand MuesliTests/MeetingAppDetectorTests.swift

**[Test]** [Low] Utility and Helper Tests
- Description: Create tests for utility functions and helpers
- Tests to add (~12 tests):
  - ClipboardHelper tests
  - AudioConfiguration tests
  - MuesliError tests
  - AppStorageKeys validation
  - Extension methods tests
- Coverage target: Utilities 0% → 60%
- Files: Create MuesliTests/UtilityTests.swift

**[Test]** [Medium] Model Tests - Edge Cases (Part 1/2)
- Description: Expand RecordingSessionTests with edge cases
- Tests to add (~10 tests):
  - Concurrent property access
  - Invalid state scenarios
  - Nil handling
  - Large transcript handling
  - Time calculations edge cases
- Coverage target: RecordingSession.swift 51% → 75%
- Files: Expand existing model tests

**[Test]** [Medium] Model Tests - Edge Cases (Part 2/2)
- Description: Expand MeetingHistoryItemTests and TranscriptBlockTests
- Tests to add (~12 tests):
  - MeetingHistoryItem edge cases (missing data, invalid dates)
  - TranscriptBlock edge cases (empty text, invalid timestamps)
  - Formatting edge cases
  - Computed property validation
- Coverage target: MeetingHistoryItem.swift 87% → 95%, TranscriptBlock.swift 59% → 85%
- Files: Expand existing model tests

**[Test]** [Low] MenuBarView - UI Logic Tests
- Description: Create MenuBarViewTests.swift for state-dependent rendering
- Tests to add (~15 tests):
  - Recording state rendering
  - Idle state rendering
  - Menu options based on state
  - Error state display
  - Recording indicator visibility
  - Tooltip content
- Coverage target: MenuBarView.swift 51% → 75%
- Files: Create MuesliTests/MenuBarViewTests.swift

**[Test]** [Low] OnboardingView - Flow Logic Tests
- Description: Create OnboardingViewTests.swift for onboarding flow logic
- Tests to add (~15 tests):
  - Welcome screen state
  - Permission screen transitions
  - Model download screen logic
  - Completion detection
  - Skip logic
  - Error state handling
  - Progress tracking
- Coverage target: OnboardingView.swift 13% → 40%
- Files: Create MuesliTests/OnboardingViewTests.swift

---

## Example Entry

**[Feature]** [High] Add keyboard shortcuts for recording controls
- Notes: Cmd+R to start/stop, Cmd+P to pause/resume
- Related: See SPEC.md Phase X

---

## Completed

Archive completed items here with completion date.

### v0.1.2 - 2026-01-18

**[Enhancement]** Add configurable audio chunking duration preference
- Completed: User-adjustable slider in preferences (2-10 seconds)
- Files: PreferencesView.swift, PreferencesManager.swift, AppStorageKeys.swift

**[Enhancement]** Add live transcript refinement
- Completed: Infrastructure added for real-time refinement during recording
- Files: TranscriptionCoordinator.swift, RefinementCoordinator.swift
- Notes: Backend support complete, UI activation to come in future release

**[Enhancement]** Add copy transcript to clipboard button
- Completed: Copy button with plain text and Markdown format options
- Files: ClipboardHelper.swift, RecordingDetailView.swift, CompletedMeetingWindow.swift

**[Enhancement]** Improve DMG installer appearance
- Completed: Custom SVG background with app icon, arrow, installation instructions
- Files: assets/dmg-background.svg, scripts/create-dmg-modern.sh

**[Bug]** Onboarding instant permission updates
- Completed: Real-time monitoring with distributed notifications + polling fallback
- Files: PermissionManager.swift, OnboardingView.swift

**[Bug]** Handle blank audio and random snippets
- Completed: Hallucination filter added to TranscriptProcessor
- Files: TranscriptProcessor.swift
- Filters: "thank you", "subscribe", repetitive text, common filler words

**[Refactor]** UI Testing Framework
- Completed: XCUITest suite for screenshot capture
- Files: MuesliUITests/ directory with test files and helpers
- Supports: Light/dark modes, mocked permissions, fixture data

**[Refactor]** SwiftLint Configuration
- Completed: Code quality standards configured
- File: .swiftlint.yml
- Status: Advisory mode (will enforce in future release)
