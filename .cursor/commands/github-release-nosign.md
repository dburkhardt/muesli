# GitHub Release (No Signing)

Create an unsigned development release via GitHub Actions. This commits all changes, pushes to the current branch, and triggers the release workflow with `skip_notarization=true`.

## Instructions

1. **Check for uncommitted changes** and commit them with an appropriate message
2. **Push** the current branch to origin
3. **Trigger the release workflow** with:
   - `--ref` set to the current branch
   - `-f version=` set to the version from `Version.xcconfig` (MARKETING_VERSION)
   - `-f skip_notarization=true`
4. **Report the workflow URL** so the user can monitor progress

## Commands

```bash
# Get current branch
git branch --show-current

# Get version from Version.xcconfig
grep MARKETING_VERSION Version.xcconfig | cut -d'=' -f2 | tr -d ' '

# Commit all changes (if any)
git add -A && git commit -m "chore: Prepare release" || echo "Nothing to commit"

# Push to origin
git push origin HEAD

# Trigger workflow
gh workflow run release.yml --ref $(git branch --show-current) -f version=$(grep MARKETING_VERSION Version.xcconfig | cut -d'=' -f2 | tr -d ' ') -f skip_notarization=true

# Get workflow run URL
gh run list --workflow=release.yml --limit=1 --json databaseId,url --jq '.[0]'
```

## After Release

The DMG will be available at:
`https://github.com/dburkhardt/muesli/releases/tag/v{VERSION}-unsigned`

To run the unsigned app:
```bash
xattr -d com.apple.quarantine /Applications/Muesli.app
```
