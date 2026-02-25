# Git Workflow (Modified Git Flow)

**Philosophy**: `main` = production (stable releases only). `develop` = integration branch for features and release candidates. Feature branches merge to `develop`; stable releases tag from `main` after RC validation.

## Branch Model

| Branch | Purpose |
|--------|---------|
| `main` | Production. Only stable releases. Tag `vX.Y.Z` from `main` after RC validation. |
| `develop` | Integration. Feature branches merge here. Cut `vX.Y.Z-rc.N` from `develop` for testing. |

## For AI Agents: Natural Language Commands

When the user asks you to work on features or fixes, follow this pattern:

### Start new work
- User says: *"Create a feature branch for X"*
- You: Create branch `feature/descriptive-name` from `develop`

### Work in progress
- User says: *"Commit this work"*
- You: Stage changes, commit with descriptive message
- User says: *"Push changes"*
- You: `git push -u origin <branch>` (sets up tracking automatically)

### Ready to merge
- User says: *"Create a PR"* or *"Open pull request"*
- You: `gh pr create --fill` (base: `develop` for features, `main` for hotfixes)
- User says: *"Merge the PR"*
- You: `gh pr merge --squash --delete-branch` (cleans up automatically)

### Create release candidate
- User says: *"Create RC v0.6.2-rc.1"*
- You: On `develop`, update `Version.xcconfig` to `X.Y.Z-rc.N`, commit, then `git tag vX.Y.Z-rc.N && git push origin vX.Y.Z-rc.N`
- GitHub Actions builds and creates a **prerelease** (not a stable release)

### Create stable release
- User says: *"Create release v0.6.2"*
- You: After RC is validated, merge `develop` → `main`, update `Version.xcconfig` to `X.Y.Z`, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`
- **WARNING**: Never create a tag without first verifying `Version.xcconfig` matches. See [AGENTS.md Versioning](../AGENTS.md#versioning-critical-for-agents).

### Emergency fixes
- User says: *"Hotfix for X"*
- You: Branch from `main` as `hotfix/short-description`, fix, PR to `main`, merge, tag patch version, then merge `main` back into `develop`

## Key Commands for Agents

```bash
# Create feature branch (from develop)
git checkout develop && git pull && git checkout -b feature/name

# Create PR to develop
gh pr create --base develop --fill

# Create PR (custom)
gh pr create --base develop --title "Title" --body "Description"

# Merge and cleanup
gh pr merge --squash --delete-branch

# Release candidate (from develop)
git checkout develop && git pull
# Edit Version.xcconfig: MARKETING_VERSION = 0.6.2-rc.1
git add Version.xcconfig && git commit -m "chore: Bump version to 0.6.2-rc.1"
git tag v0.6.2-rc.1 && git push origin develop v0.6.2-rc.1

# Stable release (after merging develop → main)
git checkout main && git pull
# Edit Version.xcconfig: MARKETING_VERSION = 0.6.2
git add Version.xcconfig && git commit -m "chore: Bump version to 0.6.2"
git tag v0.6.2 && git push origin main v0.6.2

# View PR status
gh pr status

# Check current branch
git branch --show-current
```

## Branch Naming Conventions

- Features: `feature/descriptive-name`
- Bug fixes: `bugfix/issue-description` or `fix/short-name`
- Hotfixes: `hotfix/critical-fix`
- Refactors: `refactor/what-changed`

## Release Process

**CRITICAL**: Version.xcconfig MUST be updated and committed BEFORE creating any tag.
See [AGENTS.md Versioning](../AGENTS.md#versioning-critical-for-agents) for full details.

### Release candidate (from develop)

1. Ensure `develop` has the features you want to test
2. **Update version in `Version.xcconfig`** to `X.Y.Z-rc.N` (e.g. `0.6.2-rc.1`)
3. Commit and push: `git add Version.xcconfig && git commit -m "chore: Bump version to X.Y.Z-rc.N" && git push origin develop`
4. Tag and push: `git tag vX.Y.Z-rc.N && git push origin vX.Y.Z-rc.N`
5. GitHub Actions creates a **prerelease** (not a stable release). Users see it under "Pre-releases" on the Releases page.

### Stable release (after RC validation)

1. Merge `develop` → `main` via PR
2. **Update version in `Version.xcconfig`** to `X.Y.Z` (remove `-rc.N` suffix)
3. Commit and push to `main`
4. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`
5. GitHub Actions builds DMG, creates stable release, and notarizes

### Hotfix (production bug)

1. Create hotfix branch from `main`: `git checkout main && git pull && git checkout -b hotfix/critical-fix`
2. Fix the bug, test thoroughly
3. **Update version in `Version.xcconfig`** (bump patch: 0.6.0 → 0.6.1)
4. Create PR to `main`, merge
5. Tag the release: `git tag v0.6.1 && git push origin v0.6.1`
6. Merge `main` back into `develop` to keep branches in sync

## GitHub Pages Deployment

- Website deploys automatically from `main` branch, `/docs` folder
- Changes to `docs/` go live within 1-2 minutes after merge to `main`
- Download statistics updated daily via GitHub Actions (`.github/workflows/update-download-stats.yml`)
- Configure at: https://github.com/dburkhardt/muesli/settings/pages

## Tools

- **GitHub CLI** (`gh`): Required for PR management from command line
- **Git**: Standard git commands for branching, committing, tagging
- **Xcode**: Build and test commands via `xcodebuild`

## Why This Model?

- **main stays stable**: Production users only see stable releases
- **develop bundles features**: Merge multiple features before cutting an RC
- **Clear release stages**: Pre-releases (RC) vs stable releases are visually distinct on GitHub
- **Simple CI**: CI runs on `main` and tags; no extra workflows for `develop`
