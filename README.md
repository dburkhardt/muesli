# Muesli

A local-first meeting transcription app for macOS. Captures meeting audio (Zoom/Teams/Meet via browser) + microphone, provides real-time on-device transcription via WhisperKit, and saves audio files + transcript to a local folder.

## Documentation

- **AGENTS.md** - Working rules, architecture, build commands, conventions, and common pitfalls
- **SPEC.md** - Detailed software design specification with UX flows, technical architecture, and phased implementation plan

## Getting Started with Cursor

### 1. Clone the Repository

```bash
git clone https://github.com/dburkhardt/muesli.git
cd muesli
```

### 2. Open in Cursor

Open the project folder in Cursor. The agent rules in `AGENTS.md` and `.cursorrules` will automatically guide AI assistants.

### 3. Build the Project

```bash
# Fast build (with -quiet flag - critical for speed)
killall Muesli 2>/dev/null; xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet && open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli.app
```

### 4. Working with AI Agents

When working with Cursor's AI agent:

1. **Follow the phase plan** - Work through phases defined in `SPEC.md` one at a time
2. **Verify checkpoints** - Confirm each phase's checkpoint before moving to the next
3. **Use branches for parallel work** - Create separate branches for different agents/features

Example prompt to start:
```
I'm building Muesli, a meeting transcription app. Please read SPEC.md and continue from the current phase.
```

### 5. Using Multiple Agents

You can use different branches for different Cursor agents:

```bash
# Create a branch for specific work
git checkout -b agent-feature-name
git push -u origin agent-feature-name
```

## Tips for AI-Assisted Development

1. **Verify each checkpoint** before moving on. Run the app and confirm the expected behavior.

2. **If something breaks**, provide the error message. The AI can often fix issues if it can see the build output.

3. **Keep sessions focused** - if context gets long, start a new session and point the agent to read `AGENTS.md` and continue from the current phase.

4. **Take screenshots** if UI doesn't look right - you can paste them into Cursor.

## Reference Projects

These open-source projects demonstrate patterns used in Muesli:

- **Azayaka** (menu bar + ScreenCaptureKit): https://github.com/Mnpn/Azayaka
- **WhisperKit Sample** (transcription): https://github.com/rudrankriyam/WhisperKit-Sample
- **Apple ScreenCaptureKit Sample**: https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- Apple Silicon Mac (M1/M2/M3)
- Cursor IDE
