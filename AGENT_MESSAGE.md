# Message for Agent Handling Merge to Main

## Task
Merge `feature/transcript-enhancement` branch into `main`. This branch contains the complete transcript refinement system implementation.

## Critical Information

**This feature branch is the source of truth** - it contains the most current, tested implementation. For all merge conflicts, **accept the feature branch version**.

## Expected Conflicts and Resolution

### 1. `Muesli.xcodeproj/project.pbxproj` ⚠️ CRITICAL
**Conflict:** Bundle identifier differences
- **main has:** `com.muesli.app.lir` / `Muesli-lir` (worktree-specific, should be removed)
- **feature branch has:** `com.muesli.app` / `Muesli` (base values, correct)

**Action:** **ACCEPT FEATURE BRANCH** - The feature branch has been cleaned up to use base bundle ID. Main's worktree-specific values should be replaced.

**Also check:**
- TCC reset script should use `com.muesli.app` (feature branch version)
- Remove any worktree-specific file references if they exist

### 2. `AGENTS.md`
**Conflict:** Documentation updates
- **Action:** **ACCEPT FEATURE BRANCH** - Contains comprehensive updates including:
  - New "LLM Stitching & Refinement" section
  - New "UI Patterns" section  
  - Enhanced worktree cleanup instructions
  - Critical debugging information

### 3. All Swift Source Files
**Action:** **ACCEPT FEATURE BRANCH** - These contain new features:
- `MuesliViewModel.swift` - Refinement state management, auto-refinement, mute functionality
- `RecordingDetailView.swift` - Floating refinement control pane UI
- `LLMManager.swift` - Auto-enable LLM stitching behavior
- `PreferencesView.swift` - Simplified structure (feature branch is cleaner)
- All other Swift files - Feature additions and improvements

### 4. New Files to Add
- `Muesli/Services/TranscriptRefinementService.swift`
- `Muesli/Views/Components/RefineTranscriptSheet.swift`

### 5. Files to Remove (if they exist in main)
- `Muesli/Utilities/WorkTreeIdentifier.swift`
- `Muesli/Views/Components/WorkTreeBadge.swift`
- `Muesli/Views/AboutView.swift` (if exists)

## Merge Steps

1. **Checkout main and ensure it's up to date:**
   ```bash
   git checkout main
   git pull origin main
   ```

2. **Start merge:**
   ```bash
   git merge feature/transcript-enhancement
   ```

3. **For each conflict file:**
   - Open the file
   - Look for `<<<<<<<`, `=======`, `>>>>>>>` markers
   - **Accept feature branch version** (the `=======` to `>>>>>>>` section)
   - Remove conflict markers

4. **After resolving conflicts:**
   ```bash
   git add .
   git commit -m "Merge feature/transcript-enhancement: Add transcript refinement system"
   ```

5. **Verify build:**
   ```bash
   xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet
   ```

6. **Verify bundle ID:**
   ```bash
   grep "PRODUCT_BUNDLE_IDENTIFIER" Muesli.xcodeproj/project.pbxproj | head -2
   ```
   Should show `com.muesli.app` (not `.lir` or any other suffix)

## What This Branch Adds

- ✅ Floating refinement toggle control pane (pill-shaped, matches recording control bar)
- ✅ Automatic transcript refinement when meeting stops
- ✅ Loading indicator during refinement (animated magic wand)
- ✅ Toggle between original/refined transcripts
- ✅ LLM stitching auto-enables when models downloaded
- ✅ Microphone mute functionality
- ✅ Comprehensive documentation updates

## Testing After Merge

- [ ] Build succeeds
- [ ] Bundle ID is `com.muesli.app` (base, not worktree-specific)
- [ ] App launches
- [ ] Refinement features work (if LLM model downloaded)

## Questions?

Refer to `MERGE_GUIDANCE.md` in the feature branch for detailed conflict analysis.
