# Muesli

[![codecov](https://codecov.io/gh/dburkhardt/muesli/branch/main/graph/badge.svg)](https://codecov.io/gh/dburkhardt/muesli)

**Local-first meeting transcription for macOS.** Capture and transcribe Zoom, Teams, and Google Meet meetings with complete privacy. Everything runs on your Mac—no cloud, no subscriptions, no data sharing.

## Download

🔗 **[Download from our website](https://dburkhardt.github.io/muesli)**

The latest release is available as a DMG installer from our [GitHub releases page](https://github.com/dburkhardt/muesli/releases/latest). Stable releases come from `main`; release candidates (for testing) appear under "Pre-releases" on the same page.

**Note:** Muesli is signed with a Developer ID certificate and notarized by Apple. It should open without any Gatekeeper warnings on macOS.

**Requirements:**
- macOS 26 or newer
- Apple Silicon Mac (M1/M2/M3/M4)

## Building from Source

Developers can build Muesli from source using Xcode:

```bash
# Clone the repository
git clone https://github.com/dburkhardt/muesli.git
cd muesli

# Build and launch
./scripts/build-and-launch.sh
```

The build script handles all complexity automatically: deterministic build paths, stale build detection, and process verification. Use `--clean` for a fresh build or `--help` for all options.

**Requirements:**
- macOS 26 or newer
- Xcode 26.0+
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
