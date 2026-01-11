# Merge Guidance for feature/transcript-enhancement → main

## Overview
This branch (`feature/transcript-enhancement`) contains the complete transcript refinement system implementation, including:
- Floating refinement toggle control pane
- Automatic transcript refinement
- LLM stitching auto-enable functionality
- Microphone mute feature
- Original/refined transcript toggle
- Updated documentation

**This branch is the most current and should take precedence for all conflicts.**

## Expected Merge Conflicts

### 1. `Muesli.xcodeproj/project.pbxproj`

**Conflict:** Bundle identifier and product name differences
- **main branch has:** `com.muesli.app.lir` / `Muesli-lir` (from another worktree)
- **feature branch has:** `com.muesli.app` / `Muesli` (base values, correct for main)

**Resolution:** **USE FEATURE BRANCH VERSION** (`com.muesli.app` / `Muesli`)
- The feature branch has been cleaned up to use base values (no worktree suffix)
- Main currently has worktree-specific values that should be reverted
- TCC reset script should also use `com.muesli.app` (feature branch version)

**Additional changes in feature branch:**
- Removed `WorkTreeIdentifier.swift` and `WorkTreeBadge.swift` references
- Added `TranscriptRefinementService.swift` and `RefineTranscriptSheet.swift` references
- Removed `AboutView.swift` reference (if it exists in main)

### 2. `AGENTS.md`

**Conflict:** Documentation updates and reorganization
- **main branch:** May have different worktree documentation structure
- **feature branch:** Comprehensive updates including:
  - Enhanced worktree cleanup instructions
  - New "LLM Stitching & Refinement" section
  - New "UI Patterns" section
  - Updated "Audio Sample Rate Debugging" section
  - Updated UI interaction patterns

**Resolution:** **USE FEATURE BRANCH VERSION** (it's more comprehensive and current)
- Feature branch has the latest documentation with all learnings
- Includes critical debugging information (sample rate issues, refinement patterns)
- Better organized worktree cleanup instructions

### 3. `Muesli/ViewModels/MuesliViewModel.swift`

**Conflict:** Significant refactoring and new functionality
- **feature branch adds:**
  - Refinement state management (`meetingBeingRefined`, `refinementCancelled`)
  - Automatic refinement trigger after recording stops
  - Microphone mute state management
  - Original transcript toggle state (`showOriginalTranscriptForMeeting`)
  - Refinement methods (`refineTranscript`, `refineTranscriptAsync`, etc.)
  - Transcript loading before refinement

**Resolution:** **USE FEATURE BRANCH VERSION** (contains all new functionality)
- This is a feature addition, not a conflict with existing code
- All new methods are additive
- State management is properly integrated

### 4. `Muesli/Views/PreferencesView.swift`

**Conflict:** Significant simplification
- **main branch:** May have more complex structure
- **feature branch:** Simplified to remove redundant code, better integration with `ModelManagementView`

**Resolution:** **USE FEATURE BRANCH VERSION** (simplified and cleaner)
- Feature branch has cleaner separation of concerns
- Better integration with model management

### 5. `Muesli/Views/RecordingDetailView.swift`

**Conflict:** Major UI changes
- **feature branch adds:**
  - Floating refinement control pane (loading indicator + toggle)
  - Pill-shaped control styling (Capsule)
  - Conditional display logic for refinement states
  - Improved historical meeting view structure

**Resolution:** **USE FEATURE BRANCH VERSION** (contains new UI features)
- This is the core feature implementation
- All UI changes are intentional and tested

### 6. `Muesli/Utilities/LLMManager.swift`

**Conflict:** Auto-enable behavior changes
- **feature branch changes:**
  - `isLLMStitchingEnabled` now auto-enables when `hasModel` is true
  - Auto-enable on model download
  - Auto-enable on scan for downloaded models
  - Auto-disable when all models deleted

**Resolution:** **USE FEATURE BRANCH VERSION** (intentional behavior change)
- This is a feature requirement (auto-enable when models available)
- Properly implemented with fallback to UserDefaults

### 7. New Files (No Conflicts Expected)

These files are new and should be added:
- `Muesli/Services/TranscriptRefinementService.swift`
- `Muesli/Views/Components/RefineTranscriptSheet.swift`

These files were deleted and should be removed:
- `Muesli/Utilities/WorkTreeIdentifier.swift` (if exists in main)
- `Muesli/Views/Components/WorkTreeBadge.swift` (if exists in main)

## Merge Strategy

1. **Start merge:** `git merge feature/transcript-enhancement` (or create PR)

2. **For each conflict:**
   - **project.pbxproj:** Accept feature branch (base bundle ID)
   - **AGENTS.md:** Accept feature branch (more comprehensive)
   - **All Swift files:** Accept feature branch (contains new features)

3. **Verify after merge:**
   - Build succeeds: `xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build`
   - Bundle ID is `com.muesli.app` (not worktree-specific)
   - All new files are included
   - Deleted files are removed

## Key Points

- **This branch is the source of truth** - it contains the complete, tested implementation
- **Worktree-specific values have been cleaned up** - bundle ID reverted to base
- **Documentation is comprehensive** - includes all debugging learnings
- **All features are complete** - refinement, toggle, mute, auto-enable all working

## Testing Checklist After Merge

- [ ] Build succeeds without errors
- [ ] App launches correctly
- [ ] Refinement toggle appears after recording stops (if LLM model downloaded)
- [ ] Loading indicator shows during refinement
- [ ] Toggle switches between original/refined views
- [ ] Microphone mute works during recording
- [ ] LLM stitching auto-enables when model downloaded
- [ ] Documentation is up to date
