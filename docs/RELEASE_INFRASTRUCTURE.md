# Release Infrastructure Documentation

This document describes the automated release process for Muesli.

## Overview

Muesli uses GitHub Actions to automate the entire release process:
1. Cache dependencies for faster builds (30-50% speedup)
2. Build the app in Release configuration
3. Create a DMG installer (modern create-dmg tool with legacy fallback)
4. Generate release notes with git-cliff from conventional commits
5. Generate artifact attestation for supply chain security
6. Create a GitHub Release with the DMG
7. Update the website with the new version
8. Deploy to GitHub Pages

## Files

### `.github/workflows/release.yml`
The GitHub Actions workflow that orchestrates the release process. Triggers on:
- **Git tags** matching `v*` (e.g., `v0.1.0`, `v1.2.3`)
- **Manual dispatch** with version input (for testing or special cases)

### `Version.xcconfig`
The single source of truth for the app version. Contains:
- `MARKETING_VERSION`: The user-facing version (e.g., 0.1.0)
- `CURRENT_PROJECT_VERSION`: Build number (incremented per release)

### `scripts/create-dmg-modern.sh`
Modern shell script that builds the app and creates a DMG installer using the `create-dmg` tool. Features:
- Uses community-maintained `create-dmg` tool (5k+ GitHub stars)
- Simpler, more declarative approach
- Better AppleScript handling across macOS versions
- Automatic fallback to legacy script if installation fails
- Requires: `brew install create-dmg`

### `scripts/create-dmg.sh`
Legacy shell script for DMG creation (maintained as fallback). Features:
- Builds in Release configuration
- Uses native hdiutil + AppleScript
- Creates a properly formatted DMG with Applications symlink
- Generates SHA-256 checksum
- Handles errors gracefully
- No external dependencies

### `cliff.toml`
Configuration file for git-cliff changelog generator. Defines:
- Commit message parsing rules (conventional commits)
- Grouping strategy (Features, Bug Fixes, etc.)
- Output format for CHANGELOG.md
- Filters for commits to include/exclude

### `.github/dependabot.yml`
Automated dependency updates configuration. Manages:
- GitHub Actions version updates (weekly)
- Swift Package Manager dependencies
- Groups minor/patch updates to reduce PR noise
- Automatic PR creation with proper labels

### `CHANGELOG.md`
Human-readable version history following [Keep a Changelog](https://keepachangelog.com/) format.
Used by the release workflow to generate release notes for the first release.

### `docs/download.html`
The download page on the website. Automatically updated by the release workflow with the new version number.

## Workflow Details

### Trigger: Git Tags

The primary way to create a release:

```bash
# Update version if needed
vim Version.xcconfig  # Set MARKETING_VERSION = 0.2.0
git add Version.xcconfig
git commit -m "chore: Bump version to 0.2.0"
git push origin main

# Create and push tag
git tag v0.2.0
git push origin v0.2.0

# Watch the release build (optional but recommended)
./scripts/watch-release.sh
```

This triggers the workflow automatically. The `watch-release.sh` script monitors the build progress in real-time, showing both the GitHub runner time and how long you've been watching. It updates every 0.8 seconds and will automatically exit when the build completes (success or failure) or after 10 minutes with an option to continue watching.

### Trigger: Manual Dispatch

For testing or special cases:

1. Go to GitHub → Actions → Release workflow
2. Click "Run workflow"
3. Enter version number (e.g., `0.2.0` without the `v` prefix)
4. Select branch (usually `main`)
5. Click "Run workflow"

### Workflow Steps

1. **Checkout code**: Full git history for changelog generation
2. **Set up Xcode**: Uses latest stable Xcode on macOS 14
3. **Cache dependencies**: 
   - Homebrew packages (create-dmg)
   - Swift Package Manager dependencies
   - Xcode DerivedData
4. **Install create-dmg**: Via Homebrew (cached for speed)
5. **Extract version**: From tag (`v0.2.0` → `0.2.0`) or manual input
6. **Update Version.xcconfig**: Ensures version matches the tag
7. **Build and create DMG**: Tries modern script first, falls back to legacy
8. **Generate changelog with git-cliff**: Parses conventional commits into structured notes
9. **Generate release notes**: 
   - Uses git-cliff output for "What's Changed"
   - Falls back to git log if git-cliff unavailable
   - Adds installation instructions, system requirements, checksum
10. **Generate artifact attestation**: Creates cryptographic proof of build provenance
11. **Create GitHub Release**:
    - Tag and release name
    - Release notes with installation instructions
    - DMG file as asset with attestation
    - SHA-256 checksum in notes
    - Marked as pre-release if version contains `-` (e.g., `0.2.0-beta.1`)
12. **Update website**: Update version in `docs/download.html`
13. **Deploy to GitHub Pages**: Push changes to `main` branch

### Release Notes Format

Generated release notes include:
- **What's Changed**: Organized by type (Features, Bug Fixes, etc.) via git-cliff
  - Parses conventional commits (`feat:`, `fix:`, etc.)
  - Groups changes semantically
  - Links to commit hashes
- **Installation**: Step-by-step instructions
- **System Requirements**: macOS version, chip, RAM
- **Verification**: SHA-256 checksum for download verification
  - Artifact attestation available: `gh attestation verify Muesli-vX.Y.Z.dmg --owner dburkhardt`
- **Links**: Full changelog comparison, website

## Testing the Workflow

### Local Testing

Before pushing a tag, test the DMG creation locally:

```bash
# Build and create DMG
./scripts/create-dmg.sh

# Verify DMG exists
ls -lh Muesli-v*.dmg

# Test installation
open Muesli-v*.dmg
# Drag app to Applications, launch it

# Clean up
rm Muesli-v*.dmg
```

### Testing with a Test Tag

To test the full workflow without creating an official release:

```bash
# Create a test tag (include -test or -rc suffix)
git tag v0.1.0-test
git push origin v0.1.0-test

# Monitor workflow in GitHub Actions
# The release will be marked as "pre-release"

# Clean up after testing
git tag -d v0.1.0-test  # Delete locally
git push origin :refs/tags/v0.1.0-test  # Delete remotely
gh release delete v0.1.0-test --yes  # Delete release
```

### Testing Manual Dispatch

1. Go to GitHub → Actions → Release workflow
2. Click "Run workflow"
3. Enter a test version like `0.1.0-test`
4. Select `feature/release-infrastructure` branch (or wherever you're testing)
5. Monitor the workflow run
6. Verify the release is created correctly
7. Delete the test release when done

## Required GitHub Permissions

The workflow requires the following permissions (already configured in the workflow):

- **contents: write** - For creating releases, pushing commits, and uploading assets
- **GITHUB_TOKEN** - Automatically provided by GitHub Actions

No additional secrets or configuration needed!

## Version Numbering

Follow [Semantic Versioning](https://semver.org/):

- **MAJOR.MINOR.PATCH** (e.g., 1.0.0)
  - MAJOR: Breaking changes, incompatible API changes
  - MINOR: New features, backward compatible
  - PATCH: Bug fixes, backward compatible

- **Pre-release versions** (e.g., 0.2.0-alpha.1, 0.2.0-beta.2, 0.2.0-rc.1)
  - `-alpha`: Early development, unstable
  - `-beta`: Feature complete, testing
  - `-rc`: Release candidate, final testing

## Troubleshooting

### Workflow Fails at Build Step

**Symptoms**: `xcodebuild` fails or DMG creation fails

**Solutions**:
1. Test build locally first: `./scripts/create-dmg-modern.sh` or `./scripts/create-dmg.sh`
2. Check for compilation errors in the code
3. Verify all dependencies resolve: Check Package.resolved
4. Clear cache if stale: Delete Actions cache and re-run
5. Ensure Xcode version matches (latest-stable)

### DMG Not Created

**Symptoms**: Workflow succeeds but no DMG file found

**Solutions**:
1. Check both scripts are executable: `chmod +x scripts/create-dmg*.sh`
2. Verify create-dmg tool is installed: `brew install create-dmg`
3. Check if modern script failed and fallback succeeded (review logs)
4. Verify Version.xcconfig has valid version
5. Check disk space in CI (unlikely but possible)
6. Review build logs for errors

### git-cliff Fails to Generate Changelog

**Symptoms**: Release notes missing "What's Changed" section or using fallback

**Solutions**:
1. Verify commits follow conventional commits format (`feat:`, `fix:`, etc.)
2. Check cliff.toml configuration is valid
3. Ensure git history is available (fetch-depth: 0 in workflow)
4. Workflow automatically falls back to git log if git-cliff fails

### Artifact Attestation Fails

**Symptoms**: Warning about attestation generation failure

**Solutions**:
1. Verify workflow has `attestations: write` and `id-token: write` permissions
2. Check DMG file exists before attestation step
3. Attestation is non-critical - release will still succeed
4. Review GitHub Actions logs for specific error

### Cache Not Working

**Symptoms**: Builds still slow despite caching

**Solutions**:
1. Check cache hit/miss in workflow logs
2. Verify cache keys match (Package.resolved hash, workflow file hash)
3. Clear cache manually in repo Settings → Actions → Caches
4. Ensure dependencies haven't changed significantly

### Website Not Updated

**Symptoms**: Release created but `docs/download.html` not updated

**Solutions**:
1. Check if there's a version reference to update in `docs/download.html`
2. Verify GitHub Pages is enabled (Settings → Pages → Source: main/docs)
3. Check for merge conflicts
4. Verify workflow has push permissions

### Release Not Created

**Symptoms**: Workflow runs but no release appears

**Solutions**:
1. Check workflow permissions (contents: write)
2. Verify GITHUB_TOKEN is available
3. Check for API rate limits (unlikely)
4. Look for errors in the "Create GitHub Release" step

### Wrong Version in DMG

**Symptoms**: DMG has incorrect version number

**Solutions**:
1. Ensure Version.xcconfig is committed before tagging
2. The workflow updates Version.xcconfig, so the tag version takes precedence
3. Check `MARKETING_VERSION` in Version.xcconfig after workflow runs

## Best Practices

1. **Always test locally first**: Run `./scripts/create-dmg-modern.sh` or `./scripts/create-dmg.sh` before pushing tags
2. **Use conventional commits**: Format commits as `feat:`, `fix:`, `docs:` etc. for better changelogs
3. **Use pre-release versions for testing**: Append `-alpha`, `-beta`, or `-test`
4. **Review Dependabot PRs**: Keep actions and dependencies up to date
5. **Tag from main**: Always create releases from the main branch
6. **One release at a time**: Wait for workflow to complete before creating another
7. **Verify installations**: Download and test the DMG on a clean machine
8. **Verify attestations**: Use `gh attestation verify` to check build provenance
9. **Document breaking changes**: Update CHANGELOG.md with migration guides
10. **Monitor cache efficiency**: Check workflow logs for cache hit rates

## Release Checklist

Copy this to your release PR or issue:

```markdown
## Pre-Release Checklist

### Code
- [ ] All tests pass locally
- [ ] No linter warnings or errors
- [ ] Version.xcconfig updated (if needed)
- [ ] CHANGELOG.md updated with changes

### Testing
- [ ] DMG builds locally: `./scripts/create-dmg.sh`
- [ ] App installs and launches
- [ ] Core features work (record, transcribe, history)
- [ ] Permissions work (screen recording, microphone)
- [ ] Update checker shows new version (after release)

### Release
- [ ] Create and push tag: `git tag vX.Y.Z && git push origin vX.Y.Z`
- [ ] Monitor GitHub Actions workflow
- [ ] Verify GitHub Release created
- [ ] Download and test DMG from release
- [ ] Verify website updated with new version

### Post-Release
- [ ] Announce release (if applicable)
- [ ] Monitor for issues
- [ ] Update TODO.md with next version plans
```

## Modern Tooling (2026)

The release infrastructure uses modern, generally-adopted tools:

### Build Caching
- **Actions Cache v4**: Caches DerivedData, Swift packages, and Homebrew installations
- **Impact**: 30-50% faster builds on cache hits
- **Configuration**: Automatic invalidation when dependencies change

### DMG Creation
- **create-dmg**: Community-maintained tool (5k+ stars) for DMG packaging
- **Fallback**: Legacy hdiutil-based script for reliability
- **Benefits**: Simpler code, better AppleScript handling, declarative API

### Changelog Generation
- **git-cliff**: Rust-based changelog generator with conventional commits support
- **Configuration**: `cliff.toml` defines grouping, formatting, filtering
- **Output**: Structured release notes by category (Features, Bug Fixes, etc.)
- **Fallback**: Manual git log parsing if git-cliff unavailable

### Dependency Management
- **Dependabot**: Automated dependency updates for GitHub Actions and Swift packages
- **Configuration**: `.github/dependabot.yml`
- **Schedule**: Weekly checks with grouped minor/patch updates

### Supply Chain Security
- **Artifact Attestations**: Cryptographic proof of build provenance
- **Verification**: Users can verify DMGs with `gh attestation verify`
- **Standard**: GitHub's built-in attestation system

### Action Versions
- **softprops/action-gh-release@v2**: Latest release action (v1 → v2)
- **actions/cache@v4**: Modern caching with better performance
- **orhun/git-cliff-action@v3**: Official git-cliff GitHub Action

## Future Enhancements

Potential improvements to the release infrastructure:

1. **Code signing**: Sign with Apple Developer certificate
2. **Notarization**: Notarize the app with Apple
3. **Auto-update metadata**: Generate appcast.xml for Sparkle
4. **Homebrew formula**: Auto-update Homebrew Cask formula
5. **Version bump automation**: Script to update Version.xcconfig and create tag
6. **Build artifacts**: Archive build logs and symbols for debugging
7. **Cross-version testing**: Test upgrades from previous versions
8. **Release-please integration**: Fully automated releases from conventional commits

## References

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Semantic Versioning](https://semver.org/)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [git-cliff Documentation](https://git-cliff.org/)
- [create-dmg GitHub](https://github.com/create-dmg/create-dmg)
- [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations)
- [Apple Code Signing Guide](https://developer.apple.com/support/code-signing/)
- [hdiutil man page](https://ss64.com/osx/hdiutil.html)
