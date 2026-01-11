# Prompt for Agent Handling Merge to Main

You are tasked with merging the `feature/transcript-enhancement` branch into `main`. This branch contains a complete transcript refinement system implementation that has been tested and is ready for production.

## Your Task

1. **Merge `feature/transcript-enhancement` into `main`**
2. **Resolve all merge conflicts by accepting the feature branch version**
3. **Verify the merge completes successfully**
4. **Ensure the bundle ID is correct** (`com.muesli.app`, not worktree-specific)

## Important: Conflict Resolution Strategy

**For ALL merge conflicts, accept the feature branch version (`feature/transcript-enhancement`).**

The feature branch is the source of truth and contains:
- Complete, tested implementation
- Cleaned-up worktree-specific values (reverted to base bundle ID)
- Comprehensive documentation updates
- All new features (refinement, mute, auto-enable)

## Step-by-Step Instructions

### Step 1: Prepare Your Environment

```bash
# Ensure you're on main branch
git checkout main

# Pull latest changes
git pull origin main

# Fetch the feature branch
git fetch origin feature/transcript-enhancement
```

### Step 2: Start the Merge

```bash
git merge origin/feature/transcript-enhancement
```

### Step 3: Resolve Conflicts

When conflicts occur, you'll see output like:
```
Auto-merging Muesli.xcodeproj/project.pbxproj
CONFLICT (content): Merge conflict in Muesli.xcodeproj/project.pbxproj
Auto-merging AGENTS.md
CONFLICT (content): Merge conflict in AGENTS.md
...
```

**For each conflicted file:**

1. Open the file in your editor
2. Look for conflict markers:
   ```
   <<<<<<< HEAD (main branch)
   [main branch content]
   =======
   [feature branch content]
   >>>>>>> origin/feature/transcript-enhancement
   ```

3. **Accept the feature branch version** (the content between `=======` and `>>>>>>>`)

4. Remove all conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)

5. Save the file

### Step 4: Critical File-Specific Guidance

#### `Muesli.xcodeproj/project.pbxproj` ⚠️ MOST IMPORTANT

**What to look for:**
- `PRODUCT_BUNDLE_IDENTIFIER` should be `com.muesli.app` (NOT `com.muesli.app.lir` or any suffix)
- `PRODUCT_NAME` should be `Muesli` (NOT `Muesli-lir` or any suffix)
- TCC reset script should use `com.muesli.app` (NOT `com.muesli.app.lir`)

**Action:** Accept feature branch version - it has the correct base bundle ID.

#### `AGENTS.md`

**Action:** Accept feature branch version - it has comprehensive documentation updates including new sections on LLM stitching, refinement patterns, and UI patterns.

#### All Swift Source Files

**Action:** Accept feature branch version - these contain new features:
- `MuesliViewModel.swift` - Refinement functionality, mute, auto-refinement
- `RecordingDetailView.swift` - Floating refinement control pane UI
- `LLMManager.swift` - Auto-enable LLM stitching
- `PreferencesView.swift` - Simplified structure
- All other Swift files - Feature additions

### Step 5: Stage Resolved Files

After resolving all conflicts:

```bash
# Stage all resolved files
git add .

# Verify what will be committed
git status
```

### Step 6: Complete the Merge

```bash
git commit -m "Merge feature/transcript-enhancement: Add transcript refinement system

- Add floating refinement toggle control pane with loading indicator
- Implement automatic transcript refinement after recording stops
- Auto-enable LLM stitching when models are downloaded
- Add microphone mute functionality during recording
- Add toggle between original/refined transcript views
- Update documentation with refinement patterns and UI guidelines
- Clean up worktree-specific bundle IDs"
```

### Step 7: Verify the Merge

**Check bundle ID is correct:**
```bash
grep "PRODUCT_BUNDLE_IDENTIFIER" Muesli.xcodeproj/project.pbxproj | head -2
```

Should show `com.muesli.app` (not `.lir` or any other suffix).

**Verify build succeeds:**
```bash
killall Muesli 2>/dev/null; xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet
```

Should complete with `** BUILD SUCCEEDED **`

**Check for new files:**
```bash
ls Muesli/Services/TranscriptRefinementService.swift
ls Muesli/Views/Components/RefineTranscriptSheet.swift
```

Both should exist.

**Check deleted files are gone:**
```bash
ls Muesli/Utilities/WorkTreeIdentifier.swift 2>&1
ls Muesli/Views/Components/WorkTreeBadge.swift 2>&1
```

Both should show "No such file" (they were intentionally removed).

### Step 8: Push to Main (if ready)

```bash
git push origin main
```

## Reference Documents

If you need more detailed information, refer to:
- `MERGE_GUIDANCE.md` - Detailed technical analysis of each conflict
- `AGENT_MESSAGE.md` - Additional context and testing checklist

Both documents are in the feature branch root.

## What This Merge Adds

- ✅ Floating refinement toggle control pane (pill-shaped, matches recording control bar)
- ✅ Automatic transcript refinement when meeting stops (if LLM model available)
- ✅ Loading indicator during refinement (animated magic wand with pulsating opacity and rotation)
- ✅ Toggle switch to view original vs refined transcripts
- ✅ LLM stitching automatically enables when models are downloaded
- ✅ Microphone mute functionality during recording
- ✅ Comprehensive documentation updates

## Troubleshooting

**If merge fails with "refusing to merge unrelated histories":**
```bash
git merge origin/feature/transcript-enhancement --allow-unrelated-histories
```

**If you see worktree-specific bundle IDs after merge:**
- Check `project.pbxproj` for `com.muesli.app.lir` or similar
- Replace with `com.muesli.app` (feature branch version)
- Also update TCC reset script

**If build fails:**
- Check that all new files are present (`TranscriptRefinementService.swift`, `RefineTranscriptSheet.swift`)
- Verify bundle ID is `com.muesli.app`
- Check for any remaining conflict markers in files

## Success Criteria

- [ ] Merge completes without errors
- [ ] Bundle ID is `com.muesli.app` (base, not worktree-specific)
- [ ] Build succeeds
- [ ] All new files are present
- [ ] Deleted files are removed
- [ ] No conflict markers remain in any files

## Questions?

If you encounter unexpected conflicts or issues not covered here, refer to `MERGE_GUIDANCE.md` for detailed analysis of each file, or check the commit history in the feature branch to understand the changes.
