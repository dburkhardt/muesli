# Refactoring Progress: ViewModel God Object → Manager Architecture

## Status: Phase 1 Complete ✅

### Completed Work

#### ✅ 1. Debug Logging Removed
- **File**: `Muesli/ViewModels/MuesliViewModel.swift`
- **Changes**: Removed all `#region agent log` blocks from:
  - `completeOnboarding()` (lines 477-489)
  - `stopRecordingAsync()` (lines 938-946, 953-956)

#### ✅ 2. RefinementCoordinator Added to Environment
- **File**: `Muesli/MuesliApp.swift`
- **Changes**:
  - Created `RefinementCoordinator` instance in app init
  - Injected into environment for all scenes (Menu Bar, Main Window, Completed Meeting Window)
  - Now available via `@Environment(RefinementCoordinator.self)` in views

#### ✅ 3. PreferencesManager Callbacks Wired Up
- **File**: `Muesli/MuesliApp.swift`
- **Changes**:
  - `outputDirectoryDidChange` → calls `FileOutputService.setOutputDirectory()`
  - `transcriptionModeDidChange` → calls `ViewModel.transcriptionMode.setter`
  - Callbacks execute when preferences change

#### ✅ 4. Storage Migration Added
- **File**: `Muesli/Managers/PreferencesManager.swift`
- **Function**: `migrateStorageLocationIfNeeded()`
- **Behavior**:
  - Checks if user has existing recordings in old location (`~/Documents/Meeting Transcripts`)
  - If found and no custom directory set, preserves old location as user preference
  - Prevents data loss from location change
  - Logs migration activity for debugging

#### ✅ 5. Build Verification
- **Result**: BUILD SUCCEEDED
- **Warnings**: Minor (unassigned asset, deprecated API, nonisolated)
- **Errors**: None

---

## Remaining Work (Phase 2)

### Critical Issues Still Present

#### ❗ 1. Duplicate State in MuesliViewModel (MAJOR REFACTOR NEEDED)
**Status**: NOT STARTED
**Complexity**: HIGH
**Estimated Effort**: 4-6 hours

**Problem**: MuesliViewModel (1800 lines) still contains ALL original state despite managers being extracted:

**Duplicate Preferences State**:
```swift
// In MuesliViewModel (lines 68-92):
var isEchoCancellationEnabled: Bool { ... }
var transcriptionMode: TranscriptionService.TranscriptionMode { ... }
var outputDirectory: URL { ... }
var launchAtLogin: Bool { ... }

// Also in PreferencesManager - DUPLICATE!
```

**Duplicate Meeting History State**:
```swift
// In MuesliViewModel (lines 104-126):
var meetingHistory: [MeetingHistoryItem] = []
var groupedHistory: [MeetingHistoryGroup] = []
var selectedMeeting: MeetingHistoryItem?
var selectedMeetingIDs: Set<UUID> = []
var showDeleteConfirmation: Bool = false
var meetingsPendingDeletion: [MeetingHistoryItem] = []
var completedMeetingWindowItem: MeetingHistoryItem?

// Also in MeetingHistoryManager - DUPLICATE!
```

**Duplicate Refinement State**:
```swift
// In MuesliViewModel (lines 139-183):
var showRefineSheet: Bool = false
var showRefinementPrompt: Bool = false
var meetingBeingRefined: MeetingHistoryItem?
var showOriginalTranscriptForMeeting: [String: Bool] = [:]

// Also in RefinementCoordinator - DUPLICATE!
```

**Required Changes**:
1. Update `MuesliViewModel.init()` to accept manager instances
2. Remove duplicate state properties from ViewModel
3. Create computed property accessors that delegate to managers:
   ```swift
   var meetingHistory: [MeetingHistoryItem] {
       historyManager.meetingHistory
   }
   ```
4. Update method implementations to delegate to managers:
   ```swift
   func loadMeetingHistory() {
       historyManager.loadMeetingHistory()
   }
   ```
5. Update `MuesliApp.init()` to pass managers to ViewModel
6. Test thoroughly to ensure nothing breaks

**Files Impacted**:
- `Muesli/ViewModels/MuesliViewModel.swift` (major surgery)
- `Muesli/MuesliApp.swift` (init changes)
- Potentially all view files if they rely on ViewModel state

---

#### ⚠️ 2. Inconsistent View Access Patterns
**Status**: PARTIALLY ADDRESSED
**Complexity**: MEDIUM

**Problem**: Views access state inconsistently:
- Some views use `@Environment(MeetingHistoryManager.self)` (new pattern)
- Some views use `viewModel.meetingHistory` (old pattern)
- Creates confusion about source of truth

**Examples**:
```swift
// MeetingHistorySidebar - uses environment ✅
@Environment(MeetingHistoryManager.self) private var historyManager
ForEach(historyManager.meetingHistory) { meeting in ... }

// Other views - still use ViewModel ❌
ForEach(viewModel.meetingHistory) { meeting in ... }
```

**Required Changes**:
1. Audit all views for state access
2. Migrate to consistent pattern (environment for state, ViewModel for coordination)
3. Update bindings to use managers

**Files to Review**:
- `Muesli/Views/RecordingDetailView.swift`
- `Muesli/Views/UnifiedHistoryView.swift`
- `Muesli/Views/MenuBarView.swift`
- All other views in `Muesli/Views/`

---

#### ⚠️ 3. RefinementCoordinator File I/O Responsibility
**Status**: NOT ADDRESSED
**Complexity**: MEDIUM

**Problem**: RefinementCoordinator:267-322 contains file writing logic:
```swift
private func saveRefinedTranscript(_ meeting: MeetingHistoryItem, blocks: [TranscriptBlock]) {
    // Direct file I/O - should be in FileOutputService
    try fileOutputService.saveTranscriptBlocks(...)
}
```

**Design Issue**: Coordinators should coordinate, not perform I/O. File operations belong in services.

**Required Changes**:
1. Move `saveRefinedTranscript()` logic to `FileOutputService`
2. Add methods to FileOutputService:
   - `saveOriginalTranscript(meeting, blocks/text)`
   - `saveRefinedTranscript(meeting, blocks/text)`
3. Update RefinementCoordinator to call service methods

**Files Impacted**:
- `Muesli/Managers/RefinementCoordinator.swift`
- `Muesli/Services/FileOutputService.swift`

---

#### ⚠️ 4. MeetingHistoryManager Direct FileManager Access
**Status**: NOT ADDRESSED
**Complexity**: LOW

**Problem**: MeetingHistoryManager:224-230 directly uses FileManager for deletion:
```swift
private func deleteMeetingFromDisk(_ meeting: MeetingHistoryItem) {
    let fileManager = FileManager.default
    try fileManager.removeItem(at: meeting.directory)
}
```

**Design Issue**: Should delegate to service for consistency.

**Required Changes**:
1. Add `deleteMeeting(at: URL)` to `MeetingHistoryService` or `FileOutputService`
2. Update MeetingHistoryManager to call service method

**Files Impacted**:
- `Muesli/Managers/MeetingHistoryManager.swift`
- `Muesli/Services/MeetingHistoryService.swift` or `Muesli/Services/FileOutputService.swift`

---

#### ⚠️ 5. Test Suite Issues
**Status**: NOT ADDRESSED
**Complexity**: HIGH

**Problems**:
1. **Wrong test target**: `MuesliTests/MuesliViewModelTests.swift` has product name `Muesli_vmr`
2. **Tests verify wrong code**: Tests call `viewModel.groupMeetingsByDate()` which should now be `historyManager.groupMeetingsByDate()`
3. **Missing manager tests**: No tests for PreferencesManager, MeetingHistoryManager, RefinementCoordinator
4. **Mocks don't match**: Test mocks don't inject managers

**Required Changes**:
1. Fix product name in project.pbxproj
2. Create separate test files for each manager:
   - `PreferencesManagerTests.swift`
   - `MeetingHistoryManagerTests.swift`
   - `RefinementCoordinatorTests.swift`
3. Update existing ViewModel tests to inject managers
4. Add integration tests for manager→service flows

**Files Impacted**:
- `Muesli.xcodeproj/project.pbxproj`
- All files in `MuesliTests/`
- May need new test files

---

#### ⚠️ 6. PermissionManager Created But Unused
**Status**: NOT ADDRESSED
**Complexity**: LOW

**Problem**:
- `PermissionManager` is created in MuesliApp and injected into MainWindowView
- But it's never actually used - MuesliViewModel still has its own PermissionManager
- Unclear which is source of truth

**Required Changes**:
1. Decide on single PermissionManager instance
2. Either:
   - Make ViewModel use the app-level instance, OR
   - Remove the app-level instance and keep ViewModel's
3. Update any views that expect environment injection

**Files Impacted**:
- `Muesli/MuesliApp.swift`
- `Muesli/ViewModels/MuesliViewModel.swift`
- `Muesli/Views/MainWindowView.swift`

---

## Implementation Strategy for Phase 2

### Recommended Approach: Incremental Migration

**Step 1: Add Manager References to ViewModel (No Removal)**
```swift
final class MuesliViewModel {
    // NEW: Manager references
    private let preferencesManager: PreferencesManager
    private let historyManager: MeetingHistoryManager
    private let refinementCoordinator: RefinementCoordinator

    // OLD: Keep existing properties temporarily
    var meetingHistory: [MeetingHistoryItem] = []  // Still here
    var outputDirectory: URL { ... }  // Still here

    init(preferencesManager: PreferencesManager,
         historyManager: MeetingHistoryManager,
         refinementCoordinator: RefinementCoordinator) {
        self.preferencesManager = preferencesManager
        self.historyManager = historyManager
        self.refinementCoordinator = refinementCoordinator
        // ... rest of init
    }
}
```

**Step 2: Create Computed Properties That Delegate**
```swift
// Replace stored property with computed property
var meetingHistory: [MeetingHistoryItem] {
    get { historyManager.meetingHistory }
    set { historyManager.meetingHistory = newValue }
}
```

**Step 3: Update Method Implementations to Delegate**
```swift
func loadMeetingHistory() {
    historyManager.loadMeetingHistory()  // Delegate to manager
}
```

**Step 4: Update MuesliApp to Pass Managers**
```swift
let vm = MuesliViewModel(
    preferencesManager: prefs,
    historyManager: historyMgr,
    refinementCoordinator: refinementCoord
)
```

**Step 5: Test After Each Change**
- Build and run after each property migration
- Verify UI still works
- Check recordings, preferences, history all function

**Step 6: Remove Old Properties Once All Migrated**
- Only after ALL computed properties work
- Only after ALL methods delegate
- Only after ALL tests pass

### Risk Mitigation

**Before Starting**:
- [ ] Commit current working state
- [ ] Create branch: `refactor/viewmodel-cleanup-phase2`
- [ ] Document expected behavior for manual testing

**During Refactoring**:
- [ ] Build after every 10-20 line change
- [ ] Keep app buildable at all times
- [ ] Test critical flows (record, save, playback, delete)

**After Completion**:
- [ ] Full regression testing
- [ ] Check for memory leaks (instruments)
- [ ] Verify all callbacks fire correctly
- [ ] Test edge cases (no permissions, no model, etc.)

---

## Current Architecture State

```
┌─────────────────────────────────────────────────────────────┐
│                        MuesliApp                             │
│  - Creates ALL managers                                      │
│  - Wires callbacks                                           │
│  - Injects via environment                                   │
└──────┬───────────────────────────┬────────────┬─────────────┘
       │                           │            │
       ▼                           ▼            ▼
┌──────────────┐          ┌────────────┐  ┌─────────────────┐
│ Preferences  │          │  Meeting   │  │  Refinement     │
│   Manager    │          │  History   │  │  Coordinator    │
│              │          │  Manager   │  │                 │
│ - output dir │          │ - history  │  │ - refinement    │
│ - launch     │          │ - selected │  │ - show sheet    │
│ - transc mode│          │ - deletion │  │ - toggle orig   │
│ - echo canc  │◄─┐       └────────────┘  └─────────────────┘
└──────────────┘  │              ▲                  ▲
       │          │              │                  │
       │     Observes       Calls methods      Coordinates
       │          │              │                  │
       ▼          │              │                  │
┌──────────────┐  │       ┌─────────────────────────────────┐
│ FileOutput   │  │       │      MuesliViewModel            │
│  Service     │  │       │  ❌ STILL HAS DUPLICATE STATE   │
│              │  │       │  ❌ 1800 lines, not cleaned up  │
│              │  └───────┤  ✅ Owns services               │
└──────────────┘          │  ✅ Coordinates recording       │
                          │  ⚠️  Should delegate to managers│
                          └─────────────────────────────────┘
                                    │
                                    │ Used by
                                    ▼
                          ┌─────────────────┐
                          │     Views       │
                          │  ⚠️  Mixed usage│
                          │  - Some use env │
                          │  - Some use VM  │
                          └─────────────────┘
```

---

## Testing Checklist for Phase 2

### Unit Tests
- [ ] PreferencesManager persistence/loading
- [ ] MeetingHistoryManager selection logic
- [ ] RefinementCoordinator state management
- [ ] Manager→Service callback execution

### Integration Tests
- [ ] Preference change → Service update
- [ ] Recording complete → History refresh → Selection
- [ ] Refinement complete → File save → UI update

### Manual Testing
- [ ] Start/stop recording
- [ ] Change output directory
- [ ] Toggle echo cancellation
- [ ] Change transcription mode
- [ ] Select meeting from history
- [ ] Delete meeting
- [ ] Refine transcript
- [ ] Toggle original/refined view
- [ ] Launch at login setting
- [ ] Storage migration (fresh install vs upgrade)

---

## Documentation Updates Needed

After Phase 2 completion:
- [ ] Update AGENTS.md with final architecture
- [ ] Update SPEC.md with manager responsibilities
- [ ] Add architecture diagram to docs
- [ ] Update .cursorrules with manager patterns
- [ ] Document manager injection pattern for future features

---

## Estimated Timeline

- **Phase 2**: 8-12 hours of focused work
  - ViewModel refactoring: 4-6 hours
  - View updates: 2-3 hours
  - Test updates: 2-3 hours
  - Integration testing: 1-2 hours

**Total Refactoring**: Phase 1 (complete) + Phase 2 (pending) = ~12-16 hours

---

## Notes

- Phase 1 fixes critical bugs and adds missing infrastructure
- Phase 2 completes the architectural refactoring
- Both phases are necessary for clean, maintainable code
- Current code WORKS but has duplicate state (tech debt)
- Recommend completing Phase 2 before adding new features

---

**Last Updated**: 2026-01-10
**Branch**: refactor/viewmodel-god-object (vmr worktree)
**Build Status**: ✅ BUILD SUCCEEDED
