# Release Infrastructure Documentation

This document describes the automated release process for Muesli.

## Overview

Muesli uses GitHub Actions to automate the entire release process:
1. Build the app in Release configuration
2. Create a DMG installer
3. Generate release notes
4. Create a GitHub Release with the DMG
5. Update the website with the new version
6. Deploy to GitHub Pages

## Files

### `.github/workflows/release.yml`
The GitHub Actions workflow that orchestrates the release process. Triggers on:
- **Git tags** matching `v*` (e.g., `v0.1.0`, `v1.2.3`)
- **Manual dispatch** with version input (for testing or special cases)

### `Version.xcconfig`
The single source of truth for the app version. Contains:
- `MARKETING_VERSION`: The user-facing version (e.g., 0.1.0)
- `CURRENT_PROJECT_VERSION`: Build number (incremented per release)

### `scripts/create-dmg.sh`
Shell script that builds the app and creates a DMG installer. Features:
- Builds in Release configuration
- Creates a properly formatted DMG with Applications symlink
- Generates SHA-256 checksum
- Handles errors gracefully

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
```

This triggers the workflow automatically.

### Trigger: Manual Dispatch

For testing or special cases:

1. Go to GitHub → Actions → Release workflow
2. Click "Run workflow"
3. Enter version number (e.g., `0.2.0` without the `v` prefix)
4. Select branch (usually `main`)
5. Click "Run workflow"

### Workflow Steps

1. **Checkout code**: Full git history for changelog generation
2. **Set up Xcode**: Uses Xcode 15.2 on macOS 14
3. **Extract version**: From tag (`v0.2.0` → `0.2.0`) or manual input
4. **Update Version.xcconfig**: Ensures version matches the tag
5. **Build and create DMG**: Runs `scripts/create-dmg.sh`
6. **Generate release notes**: 
   - For subsequent releases: git log since last tag
   - For first release: content from CHANGELOG.md
7. **Create GitHub Release**:
   - Tag and release name
   - Release notes with installation instructions
   - DMG file as asset
   - SHA-256 checksum in notes
   - Marked as pre-release if version contains `-` (e.g., `0.2.0-beta.1`)
8. **Update website**: Update version in `docs/download.html`
9. **Deploy to GitHub Pages**: Push changes to `main` branch

### Release Notes Format

Generated release notes include:
- **What's Changed**: Git commit log since last tag
- **Installation**: Step-by-step instructions
- **System Requirements**: macOS version, chip, RAM
- **Verification**: SHA-256 checksum for download verification
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
1. Test build locally first: `./scripts/create-dmg.sh`
2. Check for compilation errors in the code
3. Verify all dependencies resolve: Check Package.resolved
4. Ensure Xcode version matches (15.2)

### DMG Not Created

**Symptoms**: Workflow succeeds but no DMG file found

**Solutions**:
1. Check `scripts/create-dmg.sh` is executable: `chmod +x scripts/create-dmg.sh`
2. Verify Version.xcconfig has valid version
3. Check disk space in CI (unlikely but possible)
4. Review build logs for errors

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

1. **Always test locally first**: Run `./scripts/create-dmg.sh` before pushing tags
2. **Use pre-release versions for testing**: Append `-alpha`, `-beta`, or `-test`
3. **Update CHANGELOG.md**: Keep it current so release notes are accurate
4. **Tag from main**: Always create releases from the main branch
5. **One release at a time**: Wait for workflow to complete before creating another
6. **Verify installations**: Download and test the DMG on a clean machine
7. **Document breaking changes**: Update CHANGELOG.md with migration guides

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

## Future Enhancements

Potential improvements to the release infrastructure:

1. **Code signing**: Sign with Apple Developer certificate
2. **Notarization**: Notarize the app with Apple
3. **Auto-update metadata**: Generate appcast.xml for Sparkle
4. **Release notes automation**: Parse commits for conventional commit format
5. **Homebrew formula**: Auto-update Homebrew Cask formula
6. **Version bump automation**: Script to update Version.xcconfig and create tag
7. **Build artifacts**: Archive build logs and symbols for debugging
8. **Cross-version testing**: Test upgrades from previous versions

## References

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [Apple Code Signing Guide](https://developer.apple.com/support/code-signing/)
- [hdiutil man page](https://ss64.com/osx/hdiutil.html)
