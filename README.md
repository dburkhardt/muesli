# Muesli Project Setup

This folder contains the specification documents for building Muesli, a local-first meeting transcription app for macOS.

## Files

- **CLAUDE.md** - The main context file for Claude Code. This is automatically loaded and provides project structure, build commands, code style, and key decisions.

- **SPEC.md** - Detailed software design specification with UX flows, technical architecture, and phased implementation plan.

## Getting Started with Claude Code

### 1. Create the Xcode Project

Open a terminal and navigate to where you want the project:

```bash
cd ~/Projects  # or your preferred location
```

### 2. Start Claude Code

```bash
claude
```

### 3. Copy These Files

Copy `CLAUDE.md` and `SPEC.md` to your project directory. Claude Code will automatically read `CLAUDE.md` when it starts.

### 4. Begin Phase 0

Tell Claude Code:

```
I'm building Muesli, a meeting transcription app. Please read SPEC.md and start with Phase 0: create the Xcode project with the correct configuration and add the WhisperKit dependency.
```

### 5. Work Through Phases

After each phase checkpoint is verified, move to the next:

```
Phase 0 is complete - the project builds. Let's start Phase 1: create the menu bar and main window structure.
```

## Tips for Working with Claude Code

1. **Verify each checkpoint** before moving on. Run the app and confirm the expected behavior.

2. **If something breaks**, give Claude Code the error message. It can often fix issues if it can build and see the output.

3. **Keep sessions focused** - if context gets long, start a new session and tell Claude to read CLAUDE.md and continue from the current phase.

4. **Take screenshots** if UI doesn't look right - you can paste them into Claude Code.

## Reference Projects

These open-source projects demonstrate patterns used in Muesli:

- **Azayaka** (menu bar + ScreenCaptureKit): https://github.com/Mnpn/Azayaka
- **WhisperKit Sample** (transcription): https://github.com/rudrankriyam/WhisperKit-Sample
- **Apple ScreenCaptureKit Sample**: https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- Apple Silicon Mac (M1/M2/M3)
- Claude Code with active subscription
