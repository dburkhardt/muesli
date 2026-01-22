# CI Code Signing Workflow Bug

**Date**: 2026-01-22
**Category**: CI/CD

## Problem Description

The v0.1.5-rc1 release failed in CI during the code signing step. The workflow was checking for secrets using `env.VAR_NAME` syntax, but GitHub Actions secrets are not automatically exposed as environment variables—they must be explicitly passed via `env:` blocks.

## Symptoms/Error Messages

Build failed in GitHub Actions with:

```
error: No signing certificate "Mac Development" found: No "Mac Development" 
signing certificate matching team ID "***" with a private key was found.
```

The error occurred because:
1. The workflow condition `if: ${{ env.P12_BASE64 != '' }}` was always false (undefined)
2. The certificate setup step was skipped entirely
3. xcodebuild tried to use automatic signing, which requires a Mac Development certificate not present in CI

## Root Cause Analysis

Two bugs in the workflow conditions:

1. **Line 133** (certificate setup): Checked `env.P12_BASE64` instead of `secrets.DEVELOPER_ID_CERT_P12`
2. **Line 208** (sign and notarize): Checked `env.APPLE_ID` and `env.P12_BASE64` instead of `secrets.APPLE_ID` and `secrets.DEVELOPER_ID_CERT_P12`

GitHub Actions secrets are accessed via `secrets.NAME` context, not `env.NAME`. The `env.NAME` syntax only works for variables explicitly set in `env:` blocks. Since these conditions evaluated to false (empty string), the signing setup was skipped.

**Secondary issue**: The script used deprecated `codesign --deep` flag, which Apple deprecated in macOS 13.0. While not the cause of this failure, it was a code quality issue worth fixing.

## Fix Description

### 1. Fixed workflow conditions
Changed both conditions to use `secrets.*` syntax:
- Line 133: `secrets.DEVELOPER_ID_CERT_P12 != ''`
- Line 208: `secrets.APPLE_ID != '' && secrets.DEVELOPER_ID_CERT_P12 != ''`

### 2. Added preflight secrets check
New step that fails fast with clear error message if any required secrets are missing.

### 3. Added explicit CI build flag
Set `MUESLI_CI_BUILD=1` environment variable in the build step, so the script can detect CI and disable xcodebuild's automatic signing.

### 4. Updated build script for CI mode
When `MUESLI_CI_BUILD=1`:
- Passes `CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` to xcodebuild
- Builds unsigned, then signs manually with Developer ID certificate

### 5. Replaced deprecated --deep flag
Removed `--deep` from codesign command (deprecated in macOS 13.0). Added comprehensive verification with `codesign --verify --deep --strict` and `spctl --assess`.

## Affected Files

- `.github/workflows/release.yml` - Fixed conditions, added preflight check, added CI env var
- `scripts/create-dmg-modern.sh` - Added CI detection, conditional signing flags, removed --deep, added verification

## Code Snippets

### Before (release.yml)

```yaml
- name: Setup code signing certificates
  if: ${{ env.P12_BASE64 != '' && ... }}
```

### After (release.yml)

```yaml
- name: Preflight - Verify signing secrets
  if: ${{ github.event_name != 'workflow_dispatch' || github.event.inputs.skip_notarization != 'true' }}
  run: |
    MISSING=""
    if [ -z "${{ secrets.DEVELOPER_ID_CERT_P12 }}" ]; then MISSING="$MISSING DEVELOPER_ID_CERT_P12"; fi
    # ... check all secrets ...
    if [ -n "$MISSING" ]; then
      echo "::error::Missing required secrets:$MISSING"
      exit 1
    fi

- name: Setup code signing certificates
  if: ${{ secrets.DEVELOPER_ID_CERT_P12 != '' && ... }}
```

### Before (create-dmg-modern.sh)

```bash
if codesign --force --deep --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "${ENTITLEMENTS_PATH}" \
    --timestamp \
    "${APP_PATH}"; then
```

### After (create-dmg-modern.sh)

```bash
# CI detection
IS_CI_BUILD=false
if [ "${MUESLI_CI_BUILD:-}" = "1" ]; then
    IS_CI_BUILD=true
fi

# Conditional xcodebuild signing
SIGNING_FLAGS=""
if [ "$IS_CI_BUILD" = true ]; then
    SIGNING_FLAGS="CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"
fi

# Sign without --deep (deprecated in macOS 13.0)
if codesign --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "${ENTITLEMENTS_PATH}" \
    --timestamp \
    "${APP_PATH}"; then
    # ... verify entitlements ...
    
    # Verify signature integrity
    if ! codesign --verify --deep --strict "${APP_PATH}"; then
        log_error "Signature verification failed"
        exit 1
    fi
    
    # Check Gatekeeper acceptance
    if spctl --assess --type execute "${APP_PATH}" 2>&1; then
        log_success "Gatekeeper assessment passed"
    fi
fi
```

## Prevention/Testing

- **Preflight check**: Workflow now fails fast with clear error if secrets are missing
- **CI flag**: Explicit `MUESLI_CI_BUILD=1` avoids false positives from user environments
- **Verification steps**: `codesign --verify` and `spctl --assess` catch signing issues before notarization

## Related Issues/PRs

- Failed release: v0.1.5-rc1 (tag to be deleted and recreated)
- No GitHub Release was created (workflow failed before that step)

## Notes

- The `--deep` flag is only deprecated for signing, not verification. Using `codesign --verify --deep --strict` is still the correct way to verify nested code.
- The app currently uses static linking (no nested frameworks), but removing `--deep` from signing future-proofs for when we might add dynamic frameworks.
- `spctl --assess` will fail until the app is notarized—this is expected and logged as a warning.
