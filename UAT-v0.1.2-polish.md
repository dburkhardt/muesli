# User Acceptance Testing - v0.1.2 Polish Release

**Branch:** `release/v0.1.2-polish`  
**Date:** January 18, 2026  
**Build:** Debug configuration from DerivedData

---

## Pre-Testing Checklist

- [ ] App launched successfully from fresh build
- [ ] Menu bar icon appears in system tray
- [ ] No crash on startup

---

## 1. Instant Permission Updates (Onboarding)

**What changed:** Permissions now update automatically within ~1 second of being granted.

### Test Steps:
1. Reset permissions (if needed): 
   ```bash
   tccutil reset ScreenCapture com.muesli.app
   tccutil reset Microphone com.muesli.app
   ```
2. Launch app fresh to trigger onboarding
3. On the **Screen Recording permission** screen:
   - Click "Open System Settings"
   - Toggle ON screen recording permission for Muesli
   - **Expected:** Onboarding advances automatically within 1-2 seconds (no "Check Again" needed)
4. On the **Microphone permission** screen:
   - Grant microphone access when prompted (or via System Settings)
   - **Expected:** Onboarding advances automatically

### Pass Criteria:
- [ ] Screen recording permission auto-detected
- [ ] Microphone permission auto-detected
- [ ] No manual refresh needed

---

## 2. Copy Transcript to Clipboard

**What changed:** New copy button with Plain Text and Markdown format options.

### Test Steps:
1. Open a past meeting from the history list (single-click)
2. Locate the **copy button** (clipboard icon) in the transcript toolbar
3. Click and select **"Copy as Plain Text"**
   - **Expected:** Shows "Copied!" feedback for ~1.5 seconds
   - Paste into a text editor: should show `[MM:SS] Speaker: text` format
4. Click and select **"Copy as Markdown"**
   - Paste into a Markdown editor: should show `**[MM:SS]** **Speaker**: text` format
5. Double-click a meeting to open **popout window**
6. Verify copy button works the same way in popout

### Pass Criteria:
- [ ] Copy button visible in main view
- [ ] Copy button visible in popout window
- [ ] Plain text format correct
- [ ] Markdown format correct
- [ ] Visual feedback ("Copied!") appears

---

## 3. Configurable Audio Chunk Duration

**What changed:** New slider in Preferences to adjust transcription chunk size (2-10 seconds).

### Test Steps:
1. Open **Preferences** (from menu bar → Preferences, or ⌘,)
2. Navigate to the **General** tab
3. Find **"Audio Chunk Duration"** slider
4. Drag slider to different values (e.g., 3s, 5s, 8s)
   - **Expected:** Value updates in real-time, shows current seconds
5. Note the help text explaining tradeoffs
6. Start a new recording and observe transcription timing
   - Shorter chunks → faster but potentially less accurate
   - Longer chunks → slower but potentially more accurate

### Pass Criteria:
- [ ] Slider appears in Preferences → General
- [ ] Value updates smoothly (2-10 second range)
- [ ] Help text visible
- [ ] Changes persist after closing Preferences

---

## 4. Hallucination Filtering

**What changed:** Whisper hallucinations (common artifacts on silence) are now filtered out.

### Test Steps:
1. Start a recording
2. Leave 10-15 seconds of silence (no speech)
3. Stop recording
4. Check transcript for common hallucinations:
   - "Thank you for watching"
   - "Please subscribe"
   - "Bye-bye"
   - Repetitive phrases

### Pass Criteria:
- [ ] No "thank you for watching" type artifacts
- [ ] Silent periods don't produce phantom text
- [ ] Legitimate speech still transcribed correctly

---

## 5. Export Service (Folder Integration)

**What changed:** Automatic export of meetings to structured folder for external tools.

### Test Steps:
1. Open **Preferences** → scroll to find export settings
2. Enable **"Automatic Export"** if not already on
3. Note the export directory path
4. Complete a recording (can be short test recording)
5. Check export folder:
   ```bash
   ls -la ~/Library/Application\ Support/Muesli/Exports/
   ```
6. Verify folder structure:
   - `manifest.json` (global index)
   - `version.txt` (format version)
   - Meeting subfolders with `metadata.json` and `transcript.md`
7. Try **"Export All Now"** button in Preferences
   - **Expected:** All past meetings exported

### Pass Criteria:
- [ ] Export preference toggle works
- [ ] Auto-export creates files after recording
- [ ] manifest.json contains meeting index
- [ ] Per-meeting metadata.json is valid JSON
- [ ] transcript.md is readable Markdown

---

## 6. Core Recording Functionality (Regression)

**Verify existing features still work:**

### Test Steps:
1. Click "Start Recording" from menu bar
2. Play audio from a meeting app (Zoom/Teams/Meet) or system audio
3. Speak into microphone
4. Verify:
   - [ ] Recording timer increments
   - [ ] Live transcript appears
   - [ ] Waveform visualization active
5. Stop recording
6. Verify:
   - [ ] Meeting appears in history
   - [ ] Transcript saved correctly
   - [ ] Audio files exist (audio.caf, microphone.caf)

---

## 7. Meeting History (Regression)

### Test Steps:
1. View meeting history list
2. Single-click a meeting → transcript shows in split view
3. Double-click a meeting → opens in dedicated popout window
4. Use search to filter meetings
5. Try "Reprocess Transcript" on a past meeting

### Pass Criteria:
- [ ] History list loads correctly
- [ ] Single-click shows transcript
- [ ] Double-click opens popout
- [ ] Search filters correctly
- [ ] Reprocess completes without error

---

## 8. Model Management (Regression)

### Test Steps:
1. Open Preferences → Models tab
2. View available Whisper models
3. Try downloading a different model size (if not all downloaded)
4. Switch between models
5. Verify selected model persists after restart

### Pass Criteria:
- [ ] Model list displays correctly
- [ ] Download progress shows
- [ ] Model switching works
- [ ] Selection persists

---

## 9. UI Polish Check

### Visual Inspection:
- [ ] Menu bar icon displays correctly
- [ ] Windows resize properly
- [ ] Dark mode works correctly (if applicable)
- [ ] No visual glitches or layout issues
- [ ] Loading states and feedback visible

---

## Issues Found

| # | Severity | Description | Steps to Reproduce |
|---|----------|-------------|-------------------|
| 1 |          |             |                   |
| 2 |          |             |                   |
| 3 |          |             |                   |

---

## Sign-Off

**Tester:** ___________________  
**Date:** ___________________  
**Result:** ☐ Pass  ☐ Pass with Issues  ☐ Fail

**Notes:**




