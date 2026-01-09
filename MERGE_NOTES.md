# Merge Notes: AEC File Output and Timestamp Fix

**Branch**: `feature/aec-file-output-and-timestamp-fix`  
**Base Commit**: `e823aac` (main)  
**Merge Target**: `main`

## Overview

This branch implements acoustic echo cancellation (AEC) for saved audio files and fixes timestamp matching logic. Previously, AEC only processed audio for transcription, leaving saved files with echo. Now AEC processes microphone audio before saving to files.

## Changes Summary

### Core Changes
1. **EchoCancellationService.swift** - Fixed timestamp matching, added `createSampleBuffer()` helper
2. **MuesliViewModel.swift** - Refactored buffer handler to apply AEC before file output
3. **PreferencesView.swift** - Added AEC toggle in General preferences tab
4. **TranscriptionService.swift** - No functional changes (already had resampling utilities)
5. **project.pbxproj** - Added EchoCancellationService.swift to Xcode project

### Documentation
- `Muesli/notes/aec-implementation-plan.md` - Implementation plan
- `Muesli/notes/aec-research.md` - Research findings
- `Muesli/notes/aec-review-findings.md` - Code review findings

## Potential Merge Conflicts

### 1. `Muesli.xcodeproj/project.pbxproj`

**Conflict Areas:**
- PBXBuildFile entries (around line 20-50)
- PBXFileReference entries (around line 50-90)
- Services group children list (around line 183-195)
- Sources build phase (around line 340-380)

**Resolution Strategy:**
- **PBXBuildFile**: Add entry for `EchoCancellationService.swift`:
  ```
  A10000A0241D1A1D00000027 /* EchoCancellationService.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000A1241D1A1D00000027 /* EchoCancellationService.swift */; };
  ```
- **PBXFileReference**: Add entry:
  ```
  A10000A1241D1A1D00000027 /* EchoCancellationService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = EchoCancellationService.swift; sourceTree = "<group>"; };
  ```
- **Services Group**: Add to children list (alphabetically or at end):
  ```
  A10000A1241D1A1D00000027 /* EchoCancellationService.swift */,
  ```
- **Sources Build Phase**: Add to build file list (alphabetically or at end):
  ```
  A10000A0241D1A1D00000027 /* EchoCancellationService.swift in Sources */,
  ```
- **Worktree Configuration**: If merging to main, REMOVE worktree-specific settings:
  - Change `PRODUCT_BUNDLE_IDENTIFIER` from `com.muesli.app.hve` back to `com.muesli.app`
  - Change `PRODUCT_NAME` from `"Muesli-hve"` back to `Muesli`
  - Update TCC reset script bundle IDs back to `com.muesli.app`

**Note**: UUIDs (like `A10000A0241D1A1D00000027`) may need to be regenerated if they conflict. Use unique UUIDs that don't exist elsewhere in the file.

### 2. `Muesli/ViewModels/MuesliViewModel.swift`

**Conflict Areas:**
- Buffer handler (around line 294-400) - Major refactoring
- `isEchoCancellationEnabled` property (around line 67-75) - Changed to use cached value
- `_isEchoCancellationEnabled` property (around line 264-265) - New thread-safe cache
- `init()` method (around line 280-290) - Added initialization of cached value

**Resolution Strategy:**
- **Buffer Handler**: The entire handler was refactored. Key changes:
  - File output moved AFTER AEC processing for microphone audio
  - System audio storage moved outside transcription mode check
  - Switch statement reorganized to handle system/microphone separately
  - Keep the new structure: `switch type { case .system: ... case .microphone: ... }`
- **AEC State Management**: 
  - Keep the `nonisolated(unsafe) private var _isEchoCancellationEnabled` pattern
  - Keep the computed property `isEchoCancellationEnabled` that reads/writes the cached value
  - Ensure initialization in `init()` loads from UserDefaults
- **Concurrency**: The cached value pattern is required for thread-safe access from audio callback

**Key Code Pattern to Preserve:**
```swift
nonisolated(unsafe) private var _isEchoCancellationEnabled: Bool = false

var isEchoCancellationEnabled: Bool {
    get { _isEchoCancellationEnabled }
    set {
        _isEchoCancellationEnabled = newValue
        UserDefaults.standard.set(newValue, forKey: "echoCancellationEnabled")
    }
}

// In init():
_isEchoCancellationEnabled = UserDefaults.standard.bool(forKey: "echoCancellationEnabled")

// In buffer handler:
let isAECEnabled = self._isEchoCancellationEnabled  // Use cached value, not property
```

### 3. `Muesli/Views/PreferencesView.swift`

**Conflict Areas:**
- `GeneralPreferencesTab` body (around line 104-155) - Added new "Audio" section

**Resolution Strategy:**
- Add the new "Audio" section after the "Transcription" section
- Keep the same structure and styling as other sections
- Ensure proper Divider() separation between sections

**Code to Add:**
```swift
Divider()

Section {
    VStack(alignment: .leading, spacing: 16) {
        Text("Audio")
            .font(.headline)
        
        Toggle(isOn: Binding(
            get: { viewModel.isEchoCancellationEnabled },
            set: { viewModel.isEchoCancellationEnabled = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Echo Cancellation")
                Text("Remove echo from microphone audio caused by speakers. Improves transcription quality and saved audio files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}
.padding()
```

### 4. `Muesli/Services/EchoCancellationService.swift`

**Conflict Areas:**
- `findMatchingSystemAudio()` method (around line 251-280) - Logic changed
- New `createSampleBuffer()` static method (around line 65-200) - Entirely new

**Resolution Strategy:**
- **Timestamp Matching**: Replace the old logic that used `CMTimeAbsoluteValue` with the new filtered approach that only considers past buffers
- **createSampleBuffer()**: This is entirely new - add it to the extension
- Ensure `import CoreAudio` is present at the top of the file

**Key Change in findMatchingSystemAudio():**
```swift
// OLD (incorrect):
for buffer in systemAudioBuffers {
    let timeDiff = CMTimeSubtract(micTimestamp, buffer.timestamp)
    let absTimeDiff = CMTimeAbsoluteValue(timeDiff)  // ❌ Matches future buffers
    ...
}

// NEW (correct):
let validBuffers = systemAudioBuffers.filter { buffer in
    CMTimeCompare(buffer.timestamp, micTimestamp) <= 0  // ✅ Only past/present
}
for buffer in validBuffers {
    let timeDiff = CMTimeSubtract(micTimestamp, buffer.timestamp)
    // timeDiff is now always >= 0, no need for absolute value
    ...
}
```

### 5. `Muesli/Services/TranscriptionService.swift`

**Conflict Areas:**
- Likely minimal - this file already had the resampling utilities we use

**Resolution Strategy:**
- No functional changes were made to this file
- If there are conflicts, they're likely unrelated to AEC work
- Ensure `resampleSamples()` method exists (it's used by `createSampleBuffer()`)

## Testing After Merge

1. **Verify AEC Toggle**: Open Preferences → General → Audio, toggle Echo Cancellation
2. **Test File Output**: Record with AEC enabled, verify saved microphone.caf has reduced echo
3. **Test Transcription**: Verify transcription still works correctly with AEC enabled
4. **Test Both Modes**: Test in both live and post-processing transcription modes
5. **Test Disabled State**: Verify app works correctly when AEC is disabled

## Worktree-Specific Configuration

**⚠️ IMPORTANT**: When merging to main, REMOVE worktree-specific configuration:

1. **project.pbxproj** - Revert these changes:
   - `PRODUCT_BUNDLE_IDENTIFIER = com.muesli.app.hve;` → `com.muesli.app;`
   - `PRODUCT_NAME = "Muesli-hve";` → `Muesli;`
   - TCC reset script: `com.muesli.app.hve` → `com.muesli.app`

2. **Build Commands**: Update to use `Muesli.app` instead of `Muesli-hve.app`

## Files Changed

### New Files
- `Muesli/Services/EchoCancellationService.swift` - Core AEC service
- `Muesli/notes/aec-implementation-plan.md` - Implementation documentation
- `Muesli/notes/aec-research.md` - Research documentation  
- `Muesli/notes/aec-review-findings.md` - Code review findings

### Modified Files
- `Muesli/ViewModels/MuesliViewModel.swift` - Buffer handler refactoring, AEC integration
- `Muesli/Views/PreferencesView.swift` - Added AEC toggle
- `Muesli/Services/EchoCancellationService.swift` - Timestamp matching fix, new helper method
- `Muesli.xcodeproj/project.pbxproj` - Added file to project, worktree config (remove on merge)

### Unchanged But Referenced
- `Muesli/Services/TranscriptionService.swift` - Uses existing `resampleSamples()` method

## Architecture Notes

### Buffer Handler Flow (After Changes)
```
Microphone Buffer Arrives
    ↓
Extract samples at 48kHz
    ↓
Apply AEC (if enabled)
    ↓
Create CMSampleBuffer from processed samples
    ↓
Save to file (processed audio)
    ↓
Resample to 16kHz for transcription (if live mode)
```

### Thread Safety
- Audio callback runs on background thread (cannot access MainActor properties)
- `_isEchoCancellationEnabled` uses `nonisolated(unsafe)` for thread-safe access
- Pattern matches `isMicrophoneMuted` for consistency

## Dependencies

- **CoreAudio**: Added import for `AudioStreamBasicDescription` in EchoCancellationService
- **CoreMedia**: Already imported (used for CMSampleBuffer operations)
- **AVFoundation**: Already imported (used for resampling via TranscriptionService)

## Known Limitations

1. **No Double-Talk Detection**: User's voice may be attenuated if speaking while echo is present
2. **Fixed Filter Length**: May not handle very long echo delays (>100ms)
3. **File Format**: Saved microphone audio is 16kHz Int16 stereo (converted from 48kHz Float32 mono)

## Future Enhancements

- Add double-talk detection
- Apply AEC to system audio files (currently only microphone)
- Adaptive learning rate based on signal characteristics
- AEC quality metrics/logging
