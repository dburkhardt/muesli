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
│   ├── MockLLMManager.swift
│   └── MockEchoCancellationService.swift
└── Protocols/
    └── ServiceProtocols.swift    # Protocol interfaces for mocking
```

## Running Tests

From command line:
```bash
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test -quiet
```

Or from Xcode: **Product → Test** (⌘U)

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
