---
name: Achieve 70% Test Coverage
overview: Systematically add comprehensive test coverage from 9.98% to 70%+ across 4 phases, focusing on critical services, controllers, managers, coordinators, and supporting code.
todos:
  # Phase 1: Critical Services (Target: 25% overall coverage)
  - id: audio-capture-part1
    content: AudioCaptureService - Initialization & Configuration Tests (Part 1/3)
    status: completed
  - id: audio-capture-part2
    content: AudioCaptureService - Stream Lifecycle Tests (Part 2/3)
    status: pending
    dependencies:
      - audio-capture-part1
  - id: audio-capture-part3
    content: AudioCaptureService - Audio Processing Tests (Part 3/3)
    status: pending
    dependencies:
      - audio-capture-part2
  - id: transcription-service-part1
    content: TranscriptionService - Initialization Tests (Part 1/4)
    status: pending
  - id: transcription-service-part2
    content: TranscriptionService - Audio Processing Tests (Part 2/4)
    status: pending
    dependencies:
      - transcription-service-part1
  - id: transcription-service-part3
    content: TranscriptionService - Transcription Pipeline Tests (Part 3/4)
    status: pending
    dependencies:
      - transcription-service-part2
  - id: transcription-service-part4
    content: TranscriptionService - Error Handling Tests (Part 4/4)
    status: pending
    dependencies:
      - transcription-service-part3
  - id: file-output-part1
    content: FileOutputService - Directory Management Tests (Part 1/3)
    status: pending
  - id: file-output-part2
    content: FileOutputService - Audio File Writing Tests (Part 2/3)
    status: pending
    dependencies:
      - file-output-part1
  - id: file-output-part3
    content: FileOutputService - Transcript Writing Tests (Part 3/3)
    status: pending
    dependencies:
      - file-output-part2
  - id: recording-controller-part1
    content: RecordingController - Lifecycle Tests (Part 1/3)
    status: pending
  - id: recording-controller-part2
    content: RecordingController - Integration Tests (Part 2/3)
    status: pending
    dependencies:
      - recording-controller-part1
  - id: recording-controller-part3
    content: RecordingController - Edge Cases Tests (Part 3/3)
    status: pending
    dependencies:
      - recording-controller-part2
  - id: phase1-verify
    content: Verify Phase 1 - Overall coverage reaches 25%
    status: pending
    dependencies:
      - audio-capture-part3
      - transcription-service-part4
      - file-output-part3
      - recording-controller-part3
  
  # Phase 2: Controllers & Managers (Target: 45% overall coverage)
  - id: model-manager-part1
    content: ModelManager - Model Discovery Tests (Part 1/2)
    status: pending
    dependencies:
      - phase1-verify
  - id: model-manager-part2
    content: ModelManager - Download Management Tests (Part 2/2)
    status: pending
    dependencies:
      - model-manager-part1
  - id: permission-manager-part1
    content: PermissionManager - Permission Checking Tests (Part 1/2)
    status: pending
    dependencies:
      - phase1-verify
  - id: permission-manager-part2
    content: PermissionManager - Permission Request Tests (Part 2/2)
    status: pending
    dependencies:
      - permission-manager-part1
  - id: microphone-manager
    content: MicrophoneManager - Device Management Tests
    status: pending
    dependencies:
      - phase1-verify
  - id: preferences-manager-expand
    content: PreferencesManager - Additional Tests
    status: pending
    dependencies:
      - phase1-verify
  - id: meeting-history-service-part1
    content: MeetingHistoryService - Directory Scanning Tests (Part 1/2)
    status: pending
    dependencies:
      - phase1-verify
  - id: meeting-history-service-part2
    content: MeetingHistoryService - Operations Tests (Part 2/2)
    status: pending
    dependencies:
      - meeting-history-service-part1
  - id: phase2-verify
    content: Verify Phase 2 - Overall coverage reaches 45%
    status: pending
    dependencies:
      - model-manager-part2
      - permission-manager-part2
      - microphone-manager
      - preferences-manager-expand
      - meeting-history-service-part2
  
  # Phase 3: Coordinators & Supporting Services (Target: 60% overall coverage)
  - id: transcription-coordinator-expand
    content: TranscriptionCoordinator - State Management Tests
    status: pending
    dependencies:
      - phase2-verify
  - id: refinement-coordinator-part1
    content: RefinementCoordinator - Coordination Tests (Part 1/2)
    status: pending
    dependencies:
      - phase2-verify
  - id: refinement-coordinator-part2
    content: RefinementCoordinator - LLM Integration Tests (Part 2/2)
    status: pending
    dependencies:
      - refinement-coordinator-part1
  - id: transcript-refinement-part1
    content: TranscriptRefinementService - Prompt Generation Tests (Part 1/2)
    status: pending
    dependencies:
      - phase2-verify
  - id: transcript-refinement-part2
    content: TranscriptRefinementService - Refinement Quality Tests (Part 2/2)
    status: pending
    dependencies:
      - transcript-refinement-part1
  - id: llm-manager-part1
    content: LLMManager - Model Management Tests (Part 1/2)
    status: pending
    dependencies:
      - phase2-verify
  - id: llm-manager-part2
    content: LLMManager - Prompt Processing Tests (Part 2/2)
    status: pending
    dependencies:
      - llm-manager-part1
  - id: transcript-processor-part1
    content: TranscriptProcessor - Parsing Tests (Part 1/2)
    status: pending
    dependencies:
      - phase2-verify
  - id: transcript-processor-part2
    content: TranscriptProcessor - Processing Tests (Part 2/2)
    status: pending
    dependencies:
      - transcript-processor-part1
  - id: recording-state-machine
    content: RecordingStateMachine - State Tests
    status: pending
    dependencies:
      - phase2-verify
  - id: phase3-verify
    content: Verify Phase 3 - Overall coverage reaches 60%
    status: pending
    dependencies:
      - transcription-coordinator-expand
      - refinement-coordinator-part2
      - transcript-refinement-part2
      - llm-manager-part2
      - transcript-processor-part2
      - recording-state-machine
  
  # Phase 4: Supporting Services & Final Push (Target: 70%+ overall coverage)
  - id: echo-cancellation-service
    content: EchoCancellationService - AEC Tests
    status: pending
    dependencies:
      - phase3-verify
  - id: update-checker
    content: UpdateChecker - Update Check Tests
    status: pending
    dependencies:
      - phase3-verify
  - id: meeting-app-detector-expand
    content: MeetingAppDetector - Detection Tests
    status: pending
    dependencies:
      - phase3-verify
  - id: utility-tests
    content: Utility and Helper Tests
    status: pending
    dependencies:
      - phase3-verify
  - id: model-edge-cases-part1
    content: Model Tests - Edge Cases (Part 1/2)
    status: pending
    dependencies:
      - phase3-verify
  - id: model-edge-cases-part2
    content: Model Tests - Edge Cases (Part 2/2)
    status: pending
    dependencies:
      - model-edge-cases-part1
  - id: menubar-view-tests
    content: MenuBarView - UI Logic Tests
    status: pending
    dependencies:
      - phase3-verify
  - id: onboarding-view-tests
    content: OnboardingView - Flow Logic Tests
    status: pending
    dependencies:
      - phase3-verify
  - id: phase4-verify
    content: Verify Phase 4 - Overall coverage reaches 70%+
    status: pending
    dependencies:
      - echo-cancellation-service
      - update-checker
      - meeting-app-detector-expand
      - utility-tests
      - model-edge-cases-part2
      - menubar-view-tests
      - onboarding-view-tests
  
  # Final verification
  - id: final-verification
    content: Final verification and documentation
    status: pending
    dependencies:
      - phase4-verify
---

# Achieve 70%+ Test Coverage for Muesli

## Overview

Systematically increase code coverage from **9.98%** to **70%+** across 4 progressive phases, focusing on critical services first, then controllers/managers, coordinators, and finally supporting code.

**Current State:** 9.98% (2,138 / 21,419 lines)  
**Target State:** 70%+ (14,993+ / 21,419 lines)  
**Gap:** 12,854 lines need coverage

## Strategy

1. **Business logic first, UI later** - Prioritize critical paths (audio, transcription, file I/O)
2. **Progressive targets** - Each phase builds on the previous with concrete milestones
3. **Agent-sized tasks** - Each todo is completable in a single session
4. **Verify continuously** - Run coverage after each task to track progress

## Phase 1: Critical Services (Target: 25% overall coverage)

**Impact:** +3,200 covered lines

### 1.1 AudioCaptureService Tests (3 parts, ~45 tests total)

**Current:** 1.57% (8/511) | **Target:** 85% (434/511)

#### Part 1: Initialization & Configuration ✅ COMPLETED
- **File:** `MuesliTests/AudioCaptureServiceTests.swift`
- **Tests:** 28 tests covering initialization, handler configuration, error cases
- **Status:** Completed and committed

#### Part 2: Stream Lifecycle
Create tests for:
- Start capture for all system audio
- Start capture for specific app (bundle identifier)
- Stop capture successfully
- Handle stream interruption
- Handle app not found error
- Handle no display error
- Concurrent start attempts (should error)
- Stop when not recording (should error)

**Example test:**
```swift
func testStartCaptureForAllSystemAudio() async throws {
    // Given: Service with buffer handler set
    await service.setBufferHandler { _, _ in }
    
    // When: Starting capture for all apps
    try await service.startCapture()
    
    // Then: Should be recording
    let isRecording = await service.isRecording
    XCTAssertTrue(isRecording)
    
    // Cleanup
    try await service.stopCapture()
}
```

**Coverage target:** 30% → 50%

#### Part 3: Audio Processing
Create tests for:
- Audio buffer handling (system and microphone)
- RMS level calculation for Float32 (system audio)
- RMS level calculation for Int16 (microphone audio)
- Level normalization (0-1 range)
- Invalid buffer handling
- Empty buffer handling
- Audio format detection
- Concurrent audio processing

**Coverage target:** 50% → 85%

### 1.2 TranscriptionService Tests (4 parts, ~55 tests total)

**Current:** 3.33% (28/840) | **Target:** 85% (714/840)

#### Part 1: Initialization (15 tests)
- WhisperKit initialization
- Model loading and validation
- Configuration settings (sample rate, language)
- Transcription mode selection
- Progress/segment callback setup
- Error handling

#### Part 2: Audio Processing (15 tests)
- Resample 48kHz → 16kHz
- Stereo to mono conversion
- Float32 to Int16 conversion
- Buffer size validation
- Format description validation

#### Part 3: Transcription Pipeline (15 tests)
- Start/stop transcription
- Process audio chunks
- Generate segments with timestamps
- Speaker detection
- Language detection

#### Part 4: Error Handling (10 tests)
- Model not loaded error
- Invalid audio format
- Timeout handling
- Memory pressure
- Silent audio handling

### 1.3 FileOutputService Tests (3 parts, ~36 tests total)

**Current:** 3.09% (18/583) | **Target:** 85% (495/583)

#### Part 1: Directory Management (12 tests)
- Recording directory creation
- Directory naming (timestamp + UUID)
- Output directory preference
- Cleanup on cancellation
- Disk space checking

#### Part 2: Audio File Writing (12 tests)
- Write system audio to audio.caf
- Write microphone to microphone.caf
- CAF format validation
- Concurrent writes
- Large file handling
- Atomic writes (corruption prevention)

#### Part 3: Transcript Writing (12 tests)
- Generate transcript.md with timestamps
- Markdown formatting
- Unicode handling
- Empty transcript handling
- Metadata preservation

### 1.4 RecordingController Tests (3 parts, ~54 tests total)

**Current:** 7.98% (73/915) | **Target:** 80% (732/915)

#### Part 1: Lifecycle (18 tests)
- Create new session
- Start/stop recording
- Save with title
- Discard recording
- Cancel on error
- State transitions

#### Part 2: Integration (18 tests)
- Audio service coordination
- Transcription service coordination
- File output coordination
- Audio buffer routing
- Progress tracking
- Service cleanup

#### Part 3: Edge Cases (18 tests)
- Microphone mute/unmute
- Permission denied during recording
- Service failure recovery
- Concurrent operation prevention
- Memory management

### Phase 1 Verification

After completing Phase 1 todos, run:

```bash
./scripts/generate-coverage.sh
```

**Success criteria:**
- ✅ Overall coverage ≥25%
- ✅ AudioCaptureService ≥85%
- ✅ TranscriptionService ≥85%
- ✅ FileOutputService ≥85%
- ✅ RecordingController ≥80%
- ✅ All tests pass

## Phase 2: Controllers & Managers (Target: 45% overall coverage)

**Impact:** +4,300 covered lines

### 2.1 ModelManager Tests (2 parts, ~27 tests)

**Current:** 29.85% (97/325) | **Target:** 85% (276/325)

#### Part 1: Model Discovery (12 tests)
- Available models discovery
- Model selection and persistence
- Model validation
- Default model selection
- Model switching

#### Part 2: Download Management (15 tests)
- Download initiation and progress
- Download cancellation
- Error handling (network failure)
- Retry logic
- Disk space management
- Cache validation

### 2.2 PermissionManager Tests (2 parts, ~22 tests)

**Current:** 17.65% (45/255) | **Target:** 85% (217/255)

#### Part 1: Permission Checking (12 tests)
- Check screen recording permission
- Check microphone permission
- Permission state caching
- Async verification
- State change detection

#### Part 2: Permission Request (10 tests)
- Request permissions
- Handle denied/granted
- Error handling

### 2.3 MicrophoneManager Tests (18 tests)

**Current:** 8.96% (12/134) | **Target:** 85% (114/134)

- Enumerate available microphones
- Device selection by ID
- Device name/UID retrieval
- Hotplug detection (add/remove)
- Handle no devices available

### 2.4 PreferencesManager Tests (18 tests)

**Current:** 55.56% (90/162) | **Target:** 90% (146/162)

Expand existing tests with:
- All preference keys
- Default value verification
- Persistence across restarts
- Migration tests
- Thread safety (expanded)
- Change notifications

### 2.5 MeetingHistoryService Tests (2 parts, ~33 tests)

**Current:** 8.05% (31/385) | **Target:** 80% (308/385)

#### Part 1: Directory Scanning (18 tests)
- Scan recordings directory
- Parse directory structure
- Extract metadata
- Validate directories
- Handle invalid/missing files

#### Part 2: Operations (15 tests)
- Load transcript
- Search meetings
- Filter by date
- Sort (by date/name)
- Delete single/multiple
- Cache management

### Phase 2 Verification

**Success criteria:**
- ✅ Overall coverage ≥45%
- ✅ All Phase 2 services ≥80%
- ✅ All tests pass
- ✅ No regression in Phase 1 coverage

## Phase 3: Coordinators & Supporting Services (Target: 60% overall coverage)

**Impact:** +3,200 covered lines

### 3.1 TranscriptionCoordinator Tests (22 tests)

Expand existing tests with:
- Model state management (notReady/preparing/ready)
- Audio buffering when notReady
- Audio forwarding when ready
- Buffer flush on transition
- State machine validation
- Concurrent audio chunks

### 3.2 RefinementCoordinator Tests (2 parts, ~27 tests)

**Current:** 9.40% (30/319) | **Target:** 80% (255/319)

#### Part 1: Coordination (15 tests)
- Refinement state initialization
- Check availability
- Start refinement
- Toggle original/refined
- Progress tracking

#### Part 2: LLM Integration (12 tests)
- LLM manager coordination
- Cancellation
- Error handling
- Retry logic

### 3.3 TranscriptRefinementService Tests (2 parts, ~33 tests)

**Current:** 1.75% (7/401) | **Target:** 75% (301/401)

#### Part 1: Prompt Generation (18 tests)
- Generate refinement prompt
- Prompt formatting
- API request/response
- Rate limiting
- Retry logic

#### Part 2: Refinement Quality (15 tests)
- Process refined transcript
- Quality validation
- Caching
- Handle empty/malformed responses

### 3.4 LLMManager Tests (2 parts, ~27 tests)

**Current:** 8.83% (28/317) | **Target:** 75% (238/317)

#### Part 1: Model Management (15 tests)
- Model loading/configuration
- Model validation
- Model switching
- Memory management

#### Part 2: Prompt Processing (12 tests)
- Process prompts
- Generate responses
- Streaming responses
- Token limits

### 3.5 TranscriptProcessor Tests (2 parts, ~22 tests)

**Current:** 17.12% (38/222) | **Target:** 80% (178/222)

#### Part 1: Parsing (12 tests)
- Parse WhisperKit segments
- Extract timestamps
- Detect speakers
- Generate blocks

#### Part 2: Processing (10 tests)
- Filter hallucinations
- Clean filler words
- Format validation
- Merge segments

### 3.6 RecordingStateMachine Tests (18 tests)

**Current:** 31.53% (35/111) | **Target:** 85% (94/111)

- All valid state transitions
- Invalid transition rejection
- State callbacks
- Concurrent state access
- Error states
- Reset to initial state

### Phase 3 Verification

**Success criteria:**
- ✅ Overall coverage ≥60%
- ✅ All Phase 3 coordinators ≥75%
- ✅ All tests pass
- ✅ No regression in Phase 1-2 coverage

## Phase 4: Supporting Services & Final Push (Target: 70%+ overall coverage)

**Impact:** +2,154 covered lines

### 4.1 Supporting Services (~39 tests)

#### EchoCancellationService (15 tests)
- AEC initialization
- Process audio buffers
- Echo detection/reduction
- Enable/disable AEC
- Performance metrics

#### UpdateChecker (12 tests)
- Check for updates
- Parse versions
- Compare versions
- Handle network errors
- Update notifications

#### MeetingAppDetector (10 tests)
- Detect running meeting apps
- Zoom/Teams/Meet detection
- Multiple apps running
- App launch/quit detection

#### Utilities (12 tests)
- ClipboardHelper tests
- AudioConfiguration tests
- MuesliError tests
- AppStorageKeys validation

### 4.2 Model Edge Cases (~22 tests)

#### RecordingSession (10 tests)
- Concurrent property access
- Invalid state scenarios
- Large transcript handling
- Time calculations

#### MeetingHistoryItem & TranscriptBlock (12 tests)
- Missing data handling
- Invalid dates/timestamps
- Formatting edge cases
- Computed property validation

### 4.3 UI Logic Tests (~30 tests)

#### MenuBarView (15 tests)
- Recording state rendering
- Idle state rendering
- Menu options based on state
- Error state display

#### OnboardingView (15 tests)
- Welcome screen state
- Permission screen transitions
- Model download logic
- Completion detection
- Skip logic

### Phase 4 Verification

**Success criteria:**
- ✅ Overall coverage ≥70%
- ✅ All critical services ≥80%
- ✅ All managers ≥80%
- ✅ All coordinators ≥75%
- ✅ All tests pass consistently
- ✅ No flaky tests

## Final Verification

### Documentation Updates

Update these files with coverage information:
- `README.md` - Add coverage badge (already done)
- `MuesliTests/README.md` - Update coverage targets
- `AGENTS.md` - Document coverage commands

### Generate Coverage Report

```bash
./scripts/generate-coverage.sh
```

### Create Summary Report

Document:
- Final coverage percentage
- Coverage by module
- Remaining gaps
- Recommendations for future coverage

### Success Criteria

- ✅ Overall coverage ≥70% (14,993+ / 21,419 lines)
- ✅ Critical services ≥80% each
- ✅ Managers ≥80% each
- ✅ Coordinators ≥75% each
- ✅ All ~550 tests pass consistently
- ✅ No test flakiness
- ✅ Documentation updated
- ✅ Coverage tracking in CI/CD
- ✅ Codecov integration active

## Test Patterns to Follow

### 1. Arrange-Act-Assert Structure

```swift
func testExampleBehavior() async throws {
    // Arrange (Given)
    let service = AudioCaptureService()
    await service.setBufferHandler { _, _ in }
    
    // Act (When)
    try await service.startCapture()
    
    // Assert (Then)
    let isRecording = await service.isRecording
    XCTAssertTrue(isRecording)
}
```

### 2. Descriptive Names (Given-When-Then)

```swift
func testGivenServiceNotRecording_WhenStoppingCapture_ThenThrowsError()
func testGivenValidBufferHandler_WhenStartingCapture_ThenBecomesRecording()
```

### 3. One Assertion Per Test (when possible)

```swift
// Good
func testServiceInitializedAsNotRecording() async {
    let isRecording = await service.isRecording
    XCTAssertFalse(isRecording)
}

// Avoid
func testServiceState() async {
    XCTAssertFalse(await service.isRecording)
    XCTAssertNil(await service.stream)
    XCTAssertNil(await service.delegate)
    // Too many assertions - split into separate tests
}
```

### 4. Test Edge Cases

```swift
func testWithNilInput()
func testWithEmptyArray()
func testWithInvalidFormat()
func testWithConcurrentAccess()
```

### 5. Test Error Paths

```swift
func testStartCaptureWithoutBufferHandlerThrowsError()
func testStopCaptureWhenNotRecordingThrowsError()
func testHandleStreamInterruption()
```

## Verification After Each Task

After completing each todo:

```bash
# Run tests
xcodebuild -project Muesli.xcodeproj -scheme Muesli -destination 'platform=macOS' test

# Generate coverage
./scripts/generate-coverage.sh

# Verify coverage increased
grep "OVERALL PROJECT COVERAGE" coverage.json

# Commit changes
git add MuesliTests/
git commit -m "test: Add [component] tests - Part X/Y"
```

## Files Changed Summary

### Created Files (~20 new test files)

**Phase 1:**
- `MuesliTests/AudioCaptureServiceTests.swift` ✅ (completed)
- `MuesliTests/TranscriptionServiceTests.swift`
- `MuesliTests/FileOutputServiceTests.swift`

**Phase 2:**
- `MuesliTests/PermissionManagerTests.swift`
- `MuesliTests/MicrophoneManagerTests.swift`
- `MuesliTests/MeetingHistoryServiceTests.swift`

**Phase 3:**
- `MuesliTests/RefinementCoordinatorTests.swift`
- `MuesliTests/TranscriptRefinementServiceTests.swift`
- `MuesliTests/LLMManagerTests.swift`
- `MuesliTests/TranscriptProcessorTests.swift`
- `MuesliTests/RecordingStateMachineTests.swift`

**Phase 4:**
- `MuesliTests/EchoCancellationServiceTests.swift`
- `MuesliTests/UpdateCheckerTests.swift`
- `MuesliTests/UtilityTests.swift`
- `MuesliTests/MenuBarViewTests.swift`
- `MuesliTests/OnboardingViewTests.swift`

### Expanded Files (~5 test files)

- `MuesliTests/RecordingControllerTests.swift` (expand)
- `MuesliTests/ModelManagerTests.swift` (expand)
- `MuesliTests/PreferencesManagerTests.swift` (expand)
- `MuesliTests/TranscriptionCoordinatorTests.swift` (expand)
- `MuesliTests/MeetingAppDetectorTests.swift` (expand)

### Supporting Files

- `test-coverage-progress.md` ✅ (created)
- `plans/achieve_70_percent_test_coverage.plan.md` (this file)

## Estimated Effort

- **Phase 1:** 175-215 tests (~4-5 days)
- **Phase 2:** 105-135 tests (~2-3 days)
- **Phase 3:** 135-165 tests (~3-4 days)
- **Phase 4:** 90-120 tests (~2-3 days)

**Total:** ~505-635 tests | **Timeline:** ~11-15 days with focused effort

## Progress Tracking

Track progress in `test-coverage-progress.md`:
- Update after each completed todo
- Record coverage percentage
- Note any blockers or challenges
- Document test patterns discovered

## Benefits of 70% Coverage

1. **Reliability** - Catch bugs before production
2. **Refactoring confidence** - Safe to improve code
3. **Documentation** - Tests show how code should work
4. **Regression prevention** - Automated safety net
5. **Code quality** - Forces better design
6. **CI/CD trust** - Confident in automated checks
7. **Review efficiency** - Clear visibility of tested vs untested code

## Next Steps

1. Review this plan for completeness
2. Continue with Phase 1, Part 2 (AudioCaptureService - Stream Lifecycle)
3. Run coverage after each part to track progress
4. Commit frequently with meaningful messages
5. Update todos as work progresses
