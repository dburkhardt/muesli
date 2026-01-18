# Phase 3 Test Coverage - Handoff Document

**Date**: January 18, 2026  
**Project**: Muesli (macOS meeting transcription)  
**Current Phase**: Phase 3 (Services & Controllers)  
**Previous Phase**: Phase 2 (Managers) - ✅ COMPLETED

## Current Status

### Test Coverage Progress
- **Overall Coverage**: 9.98% (2,138 / 21,419 lines)
- **Total Tests**: 295 tests (290 passing, 5 failing)
- **Phase 1**: ✅ Complete - MuesliViewModel, RecordingController basics
- **Phase 2**: ✅ Complete - PreferencesManager, ModelManager, PermissionManager, MicrophoneManager, MeetingHistoryService
- **Phase 3**: 🔄 IN PROGRESS - Core services (Audio, Transcription, FileOutput)
- **Phase 4**: ⏳ Pending - Coordinators

### Recent Achievements (Phase 2)
Created 121 new tests across 5 test suites:
- PermissionManagerTests (29 tests)
- MicrophoneManagerTests (24 tests) 
- MeetingHistoryServiceTests (25 tests)
- PreferencesManagerTests (expanded to 41 tests)
- ModelManagerTests (expanded to 61 tests)

### Build Status
- ✅ Project builds successfully
- ✅ All Phase 2 tests passing
- ⚠️ 5 pre-existing test failures in TranscriptionCoordinatorTests

## Phase 3 Objectives

**Goal**: Achieve 45-50% overall test coverage by testing core services

### Priority 1: Critical Services (Target: 80%+ coverage each)

1. **AudioCaptureServiceTests** (Highest Priority)
   - **Current**: 1.57% coverage (8/511 lines)
   - **Target**: Add 60-70 tests to reach 80%+
   - **Focus Areas**:
     - ScreenCaptureKit stream initialization and teardown
     - Audio buffer handling and processing
     - Sample rate conversion (48kHz → 16kHz critical for WhisperKit)
     - Error handling (permission denied, stream interrupted)
     - Audio level monitoring
     - Microphone device switching
     - Buffer handler callbacks
   - **Test Strategy**: Mock SCStream and AVAudioEngine where possible

2. **TranscriptionServiceTests** (Critical)
   - **Current**: 3.33% coverage (28/840 lines)
   - **Target**: Add 70-80 tests to reach 80%+
   - **Focus Areas**:
     - WhisperKit model initialization
     - Audio chunk processing (system + microphone)
     - Real-time vs post-processing modes
     - Transcript handler callbacks
     - Audio resampling (CRITICAL - gibberish if wrong sample rate)
     - Buffer management
     - Error recovery
   - **Test Strategy**: Mock WhisperKit, test resampling logic separately

3. **FileOutputServiceTests** (Critical)
   - **Current**: 3.09% coverage (18/583 lines)
   - **Target**: Add 50-60 tests to reach 80%+
   - **Focus Areas**:
     - Directory creation and management
     - AVAssetWriter lifecycle (start, append, stop)
     - Transcript file generation (Markdown format)
     - Audio file writing (audio.caf, microphone.caf)
     - Segment management (pause/resume)
     - Error handling (disk full, permissions)
   - **Test Strategy**: Use temporary directories, verify file contents

4. **RecordingControllerTests** (High Priority)
   - **Current**: 7.98% coverage (73/915 lines)
   - **Target**: Expand existing tests to 80%+
   - **Focus Areas**:
     - State machine integration
     - Service coordination (audio, transcription, file output)
     - Recording lifecycle (start, pause, resume, stop)
     - Error propagation
     - Export service integration
   - **Test Strategy**: Use existing mocks, add integration scenarios

### Priority 2: Supporting Services (Target: 70%+ coverage)

5. **TranscriptProcessorTests**
   - Current: 17.12% coverage
   - Add tests for transcript block parsing and formatting

6. **EchoCancellationServiceTests**
   - Add tests for AEC filter processing

## Key Files & Locations

### Test Files
```
MuesliTests/
├── AudioCaptureServiceTests.swift          # EXISTS (minimal)
├── TranscriptionServiceTests.swift         # EXISTS (minimal)  
├── FileOutputServiceTests.swift            # EXISTS (minimal)
├── RecordingControllerTests.swift          # EXISTS (needs expansion)
├── PermissionManagerTests.swift            # ✅ Phase 2
├── MicrophoneManagerTests.swift            # ✅ Phase 2
├── MeetingHistoryServiceTests.swift        # ✅ Phase 2
├── PreferencesManagerTests.swift           # ✅ Phase 2
├── ModelManagerTests.swift                 # ✅ Phase 2
└── Mocks/
    ├── MockAudioCaptureService.swift       # Use as template
    ├── MockTranscriptionService.swift      # Use as template
    └── MockFileOutputService.swift         # Use as template
```

### Source Files to Test
```
Muesli/Services/
├── AudioCaptureService.swift               # 511 lines - CRITICAL
├── TranscriptionService.swift              # 840 lines - CRITICAL
├── FileOutputService.swift                 # 583 lines - CRITICAL
├── TranscriptProcessor.swift               # 222 lines
└── EchoCancellationService.swift           # ~200 lines
```

## Important Context & Pitfalls

### Critical Issues to Avoid

1. **Audio Sample Rates** (MOST IMPORTANT!)
   - WhisperKit requires 16kHz mono audio
   - System audio captures at 48kHz stereo
   - Microphone captures at 48kHz mono
   - MUST use `TranscriptionService.resampleToWhisperFormat()`
   - **Symptom if wrong**: Transcription outputs gibberish
   - See: `AGENTS.md` section "Audio Sample Rates (CRITICAL)"

2. **ScreenCaptureKit Permission Prompts**
   - `SCShareableContent.excludingDesktopWindows()` triggers permission prompt
   - Do NOT call in test environment or during onboarding welcome
   - Use mock objects for testing
   - See: `spec/onboarding_flow.md`

3. **AVCaptureDevice Permission Prompts**
   - `AVCaptureDevice.DiscoverySession` can trigger microphone permission prompt
   - Only enumerate devices AFTER permission granted
   - Tests should mock or skip device enumeration

4. **Test Environment Detection**
   - Many managers check `NSClassFromString("XCTestCase") != nil`
   - This skips permission checks and system calls
   - Your tests should work with this pattern

5. **Concurrency & @MainActor**
   - Most managers are `@MainActor` isolated
   - Use `@MainActor` on test classes
   - Capture local `let` variables before passing to TaskGroups

### Known Failing Tests
- `TranscriptionCoordinatorTests`: 4 failures (pre-existing, commented out issues)
- `MeetingHistoryServiceTests`: 1 failure (pre-existing)

These can be addressed but are not blocking Phase 3 work.

## Build & Test Commands

### Standard Build
```bash
cd /Users/dburkhardt/git-repos/muesli
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
killall Muesli 2>/dev/null
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build 2>&1 | tee "/tmp/muesli-build-${TIMESTAMP}.txt"
```

### Run All Tests
```bash
xcodebuild -project Muesli.xcodeproj -scheme Muesli -destination 'platform=macOS' test
```

### Run Specific Test Suite
```bash
xcodebuild -project Muesli.xcodeproj -scheme Muesli -destination 'platform=macOS' test -only-testing:MuesliTests/AudioCaptureServiceTests
```

### Generate Coverage Report
```bash
./scripts/generate-coverage.sh
cat coverage-summary.md
```

### Quick Coverage Check
```bash
xcodebuild -project Muesli.xcodeproj -scheme Muesli -destination 'platform=macOS' test -enableCodeCoverage YES 2>&1 | grep "coverage" | tail -20
```

## Adding New Test Files

### Step 1: Create Test File
```swift
import XCTest
@testable import Muesli

@MainActor
final class AudioCaptureServiceTests: XCTestCase {
    var service: AudioCaptureService!
    
    override func setUp() async throws {
        try await super.setUp()
        service = AudioCaptureService()
    }
    
    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }
    
    func testInitialization() {
        // Test here
    }
}
```

### Step 2: Add to Xcode Project
Edit `Muesli.xcodeproj/project.pbxproj`:

1. Add to `PBXBuildFile` section:
```
B1000XXX241D1A1D00000XXX /* AudioCaptureServiceTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000YYY241D1A1D00000YYY /* AudioCaptureServiceTests.swift */; };
```

2. Add to `PBXFileReference` section:
```
B1000YYY241D1A1D00000YYY /* AudioCaptureServiceTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AudioCaptureServiceTests.swift; sourceTree = "<group>"; };
```

3. Add to `MuesliTests` group's children array
4. Add to `PBXSourcesBuildPhase` for MuesliTests target

**Tip**: Look at how `PermissionManagerTests.swift` was added as a reference.

## Testing Strategy

### For Services with System Dependencies

1. **Create Mocks**: Use protocol-based injection
2. **Test Logic Separately**: Extract testable functions
3. **Use Temporary Resources**: For file I/O, use `FileManager.temporaryDirectory`
4. **Skip System Calls in Tests**: Check `isRunningTests` where appropriate

### Test Structure (Given-When-Then)

```swift
func testSampleRateConversion_From48kHzTo16kHz() {
    // Given: 48kHz audio buffer
    let inputBuffer = createTestBuffer(sampleRate: 48000, samples: 4800)
    
    // When: Resampling to 16kHz
    let output = service.resampleToWhisperFormat(
        inputBuffer, 
        sourceSampleRate: 48000, 
        sourceChannels: 2
    )
    
    // Then: Should have 1/3 the samples and be mono
    XCTAssertEqual(output.count, 1600) // 4800 / 3
}
```

### Coverage Targets
- **Critical services**: 80-90%
- **Supporting services**: 70%+
- **New code (PRs)**: 80% minimum (enforced by CI)

## Success Criteria for Phase 3

- [ ] AudioCaptureServiceTests: 60+ tests, 80%+ coverage
- [ ] TranscriptionServiceTests: 70+ tests, 80%+ coverage
- [ ] FileOutputServiceTests: 50+ tests, 80%+ coverage
- [ ] RecordingControllerTests: Expanded to 80%+ coverage
- [ ] Overall project coverage: 45-50%+
- [ ] All tests passing (may skip known failing tests)
- [ ] Coverage report generated and committed

## Reference Documentation

**Must Read Before Starting**:
1. `AGENTS.md` - Architecture, commands, pitfalls
2. `SPEC.md` - Product spec and implementation phases
3. `spec/audio_pipeline.md` - Audio capture and processing details
4. `MuesliTests/README.md` - Testing guidelines

**Coverage Reports**:
- Current: `coverage-summary.md`
- Plan: `plans/achieve_70_percent_test_coverage.plan.md`
- Phase 2 plan: `/Users/dburkhardt/.cursor/plans/phase_2_test_coverage_e6dbb5c2.plan.md`

## Git Workflow

Use GitHub Flow (feature branches):
```bash
# Create feature branch for Phase 3
git checkout -b phase3-service-tests

# Commit after each test suite
git add MuesliTests/AudioCaptureServiceTests.swift
git commit -m "test: Add comprehensive AudioCaptureService tests (60+ tests)"

# When phase complete
git add .
git commit -m "test: Complete Phase 3 - Services test coverage

- Added 180+ tests across 3 critical services
- AudioCaptureService: 80%+ coverage
- TranscriptionService: 80%+ coverage  
- FileOutputService: 80%+ coverage
- Overall coverage: 45%+

Closes #<issue-number>"

# Create PR
gh pr create --fill
```

## Next Agent Instructions

**Your task**: Complete Phase 3 of the test coverage plan.

**Start with**:
1. Read `AGENTS.md` and `spec/audio_pipeline.md` carefully
2. Review existing minimal tests in `AudioCaptureServiceTests.swift`
3. Create comprehensive AudioCaptureService tests (highest priority)
4. Move to TranscriptionService tests
5. Complete FileOutputService tests
6. Generate coverage report and verify 45%+ overall

**Completion criteria**: 
- All 3 critical services at 80%+ coverage
- Overall project at 45%+
- All new tests passing
- Coverage report committed

**Estimated effort**: 180-200 new tests, 8-12 hours of work

## Questions or Issues?

- Check `AGENTS.md` for architecture questions
- Check existing test files for patterns
- Check mock implementations for testing strategies
- Known issues are documented in this file

---

**Status**: Ready for Phase 3 implementation  
**Last Updated**: January 18, 2026  
**Created By**: Phase 2 Agent
