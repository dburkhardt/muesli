# Muesli

[![codecov](https://codecov.io/gh/dburkhardt/muesli/branch/main/graph/badge.svg)](https://codecov.io/gh/dburkhardt/muesli)

**Local-first meeting transcription for macOS.** Capture and transcribe Zoom, Teams, and Google Meet meetings with complete privacy. Everything runs on your Mac—no cloud, no subscriptions, no data sharing.

## Download

🔗 **[Download from our website](https://dburkhardt.github.io/muesli)**

The latest release is available as a DMG installer from our [GitHub releases page](https://github.com/dburkhardt/muesli/releases/latest).

**Note:** Muesli is currently unsigned. When you first open it, macOS will show a security warning. Right-click the app in your Applications folder and choose "Open" to bypass Gatekeeper. See our [installation guide](https://dburkhardt.github.io/muesli/download.html) for detailed instructions.

**Requirements:**
- macOS 14.0+ (Sonoma)
- Apple Silicon Mac (M1/M2/M3/M4)

## Building from Source

Developers can build Muesli from source using Xcode:

```bash
# Clone the repository
git clone https://github.com/dburkhardt/muesli.git
cd muesli

# Build and launch
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
killall Muesli 2>/dev/null
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build 2>&1 | tee ".logs/build-${TIMESTAMP}.txt"
open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli.app
```

**Requirements:**
- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- Apple Silicon Mac (M1/M2/M3/M4)

**Architecture and Technical Details:**
- See [AGENTS.md](AGENTS.md) for architecture, build commands, and common pitfalls
- See [SPEC.md](SPEC.md) for product specification and implementation phases

## For Cursor Users

If you're developing Muesli with Cursor's AI agent:

1. **Read [AGENTS.md](AGENTS.md) first** - Contains working rules, architecture, and conventions
2. **Follow the phased plan in [SPEC.md](SPEC.md)** - Work through one phase at a time
3. **Verify checkpoints** - Confirm each phase works before proceeding

The agent rules in `AGENTS.md` will automatically guide AI assistants through the codebase.

## License

Muesli is free and open source software. See [LICENSE](LICENSE) for details.
