# MuesliTests

Comprehensive test suite for MuesliViewModel and related components.

## Setup

To add the test target to the Xcode project:

1. Open `Muesli.xcodeproj` in Xcode
2. Go to **File → New → Target...**
3. Select **macOS → Unit Testing Bundle**
4. Configure:
   - Product Name: `MuesliTests`
   - Team: (your team)
   - Organization Identifier: `com.muesli.app.vmr`
   - Target to be Tested: `Muesli`
5. Click **Finish**

Then add the test files:

1. Right-click on the `MuesliTests` group in Xcode
2. Select **Add Files to "Muesli"...**
3. Navigate to the `MuesliTests` folder and add all `.swift` files

Or use the Finder to drag the files into Xcode.

## Test Structure

```
MuesliTests/
├── MuesliViewModelTests.swift    # Main test suite
├── Mocks/                        # Mock implementations
│   ├── MockAudioCaptureService.swift
│   ├── MockTranscriptionService.swift
│   ├── MockFileOutputService.swift
│   ├── MockMeetingHistoryService.swift
│   ├── MockMeetingAppDetector.swift
│   ├── MockPermissionManager.swift
│   ├── MockMicrophoneManager.swift
│   ├── MockModelManager.swift
│   └── MockLLMManager.swift
└── Protocols/
    └── ServiceProtocols.swift    # Protocol interfaces for mocking
```

## Running Tests

From command line:
```bash
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test -quiet
```

Or from Xcode: **Product → Test** (⌘U)

### Running Tests with Coverage

**Local development:**
```bash
# Generate coverage report with detailed breakdown
./scripts/generate-coverage.sh
```

This will:
- Run all tests with coverage enabled
- Generate JSON and text coverage reports
- Display coverage summary in terminal
- Show files with lowest coverage (priority areas)

**View coverage in Xcode:**
1. Open `Muesli.xcodeproj` in Xcode
2. Run tests with coverage: **Product → Test** (⌘U)
3. Open Report Navigator (⌘9)
4. Select the latest test run
5. Click the **Coverage** tab
6. Click any file to see line-by-line coverage

**CI/CD:**
- Coverage is automatically collected on every PR and push to main
- Coverage reports are uploaded to [Codecov](https://codecov.io/gh/dburkhardt/muesli)
- PRs show coverage diff in automated comments
- Status checks enforce minimum 80% coverage for new code

## Coverage Metrics

Current coverage targets:
- **Overall project**: ≥70% line coverage
- **New code (PR diff)**: ≥80% line coverage (enforced)
- **Critical paths**: ≥90% target (audio, transcription, file I/O)

View live coverage: [![codecov](https://codecov.io/gh/dburkhardt/muesli/branch/main/graph/badge.svg)](https://codecov.io/gh/dburkhardt/muesli)

### Priority Areas for Coverage

Based on the current test suite, these areas should receive testing priority:

1. **Controllers** (core business logic)
   - RecordingController - recording lifecycle and state management
   
2. **Services** (critical functionality)
   - AudioCaptureService - system audio and microphone capture
   - TranscriptionService - WhisperKit integration and audio processing
   - FileOutputService - file writing and directory management
   - TranscriptionRefinementService - LLM-based transcript refinement
   
3. **Managers** (state and configuration)
   - ModelManager - WhisperKit model download and selection
   - MeetingHistoryManager - history list and selection
   - PreferencesManager - settings persistence
   - MicrophoneManager - device selection and monitoring
   
4. **Coordinators** (workflow orchestration)
   - TranscriptionCoordinator - real-time transcription flow
   - RefinementCoordinator - transcript refinement state
   
5. **Views** (UI logic - lower priority)
   - Focus on complex UI state logic
   - Simple presentational views can have lower coverage

## Test Coverage

The test suite covers:

### Preferences Tests
- Output directory defaults and persistence
- Transcription mode changes
- Echo cancellation state
- Launch at login preferences
- UserDefaults key documentation

### Meeting History Tests  
- Meeting discovery and grouping (by day/month)
- Single and multi-select functionality
- Range selection (Shift+click)
- Deletion state management

### Recording Lifecycle Tests
- Session creation and initial state
- Active session tracking
- UI state management (sheets, alerts)
- Error handling

### Refinement Tests
- Transcript toggle state (original/refined)
- Refinement availability checks
- Refinement state management

### Model Tests
- TranscriptBlock properties and methods
- TranscriptSegment initialization
- RecordingSession state and methods
- MeetingHistoryItem formatted properties

## Note on Testing Approach

Since `MuesliViewModel` currently creates its own service instances internally, tests verify behavior through the public API. The mock implementations are prepared for Phase 1+ of the refactor when dependency injection is added.

Key testing principles:
- Test observable state changes
- Verify computed properties
- Test state transitions
- Document UserDefaults keys
- Prepare mocks for future DI support
