#!/bin/bash
# Build and launch Muesli with verification to prevent stale build issues
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  BUILD TIME: 5-8 minutes. Run the script and monitor via log file.     │
# │                                                                         │
# │  1. Start:   ./scripts/build-and-launch.sh                              │
# │  2. Running: cat /tmp/muesli-build.lock                                 │
# │  3. Monitor: tail -30 "$(ls -t /tmp/muesli-build-*.log | head -1)"      │
# │  4. Done:    grep "Build & Launch Complete" /tmp/muesli-build-*.log     │
# └─────────────────────────────────────────────────────────────────────────┘
#
# Log files:
# - Script log: /tmp/muesli-build-TIMESTAMP.log (all output, no colors)
# - Build log:  /tmp/muesli-build-TIMESTAMP-xcodebuild.txt (xcodebuild output)
# - Lock file:  /tmp/muesli-build.lock (contains PID while running)
#
# This script addresses common problems where agents launch old app versions:
# - Logs all output to /tmp/muesli-build-TIMESTAMP.log by default
# - Uses deterministic DerivedData path (no wildcards)
# - Prevents parallel builds with a lock file
# - Preserves caches by default for fast rebuilds (~1-2 min vs 5-8 min)
# - Only removes app bundles, keeps DerivedData intermediates
# - TCC permissions persist across builds (use --reset-tcc for onboarding testing)
# - Verifies the app was just built (modification time check)
# - Uses full path with open -a to bypass Launch Services
# - Confirms the correct process is running after launch
#
# Usage:
#   ./scripts/build-and-launch.sh                  # Fast rebuild (default)
#   ./scripts/build-and-launch.sh --deep-clean     # Full cache clear if needed
#   ./scripts/build-and-launch.sh --dry-run        # Show what would happen
#
# NOTE: --build-only exists but should NOT be used by agents. Always build AND
# launch so the user can immediately test and debug changes.

set -e

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SCRIPT_LOG="/tmp/muesli-build-${TIMESTAMP}.log"
BUILD_LOG="/tmp/muesli-build-${TIMESTAMP}-xcodebuild.txt"

# Default options
# NOTE: PRESERVE_CACHES=true by default for faster rebuilds (~1-2 min vs 5-8 min)
# Use --deep-clean if you encounter stale cache issues
ALWAYS_CLEAN=false
DEEP_CLEAN=false
PRESERVE_CACHES=true
BUILD_ONLY=false
DRY_RUN=false
ENABLE_LOGGING=true
RESET_TCC=false

# Lock file for preventing parallel builds
LOCK_FILE="/tmp/muesli-build.lock"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

# Note: print_* functions are defined after logging setup below

# Cleanup function to release lock on exit
cleanup() {
    if [ -n "$LOCK_ACQUIRED" ] && [ "$LOCK_ACQUIRED" = true ]; then
        rm -f "$LOCK_FILE"
    fi
}
trap cleanup EXIT

# ============================================================================
# Parse Arguments
# ============================================================================

for arg in "$@"; do
    case $arg in
        --incremental)
            # Opt-in to incremental builds (NOT recommended, caching causes issues)
            ALWAYS_CLEAN=false
            DEEP_CLEAN=false
            shift
            ;;
        --deep-clean)
            # Force a full cache clear - use when encountering stale cache issues
            DEEP_CLEAN=true
            PRESERVE_CACHES=false
            ALWAYS_CLEAN=true
            shift
            ;;
        --preserve-caches)
            # Legacy flag - now the default behavior
            # Kept for backward compatibility
            shift
            ;;
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-log)
            # Disable logging to file (output to terminal only)
            ENABLE_LOGGING=false
            shift
            ;;
        --reset-tcc)
            # Opt-in to reset TCC permissions (for onboarding testing)
            RESET_TCC=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --deep-clean       Force full cache clear (use if builds behave unexpectedly)"
            echo "  --dry-run          Show what would happen without doing it"
            echo "  --no-log           Disable logging to file (terminal output only)"
            echo "  --reset-tcc        Reset TCC permissions (for onboarding testing)"
            echo "  --help, -h         Show this help message"
            echo ""
            echo "Advanced options (rarely needed):"
            echo "  --incremental      Skip xcodebuild clean (fastest, but may miss some changes)"
            echo ""
            echo "Default behavior (PRESERVE CACHES - fast rebuilds):"
            echo "  - Logs all output to /tmp/muesli-build-TIMESTAMP.log"
            echo "  - Preserves DerivedData intermediates for incremental compilation"
            echo "  - Removes only app bundles to ensure fresh binary"
            echo "  - Runs 'xcodebuild clean build' to recompile changed sources"
            echo "  - TCC permissions persist across builds (use --reset-tcc for onboarding testing)"
            echo "  - Build time: ~1-2 minutes (vs 5-8 min with --deep-clean)"
            echo ""
            echo "Examples:"
            echo "  $0                 # Fast rebuild (default)"
            echo "  $0 --deep-clean    # Full cache clear (use if something seems wrong)"
            echo ""
            echo "Discouraged (avoid unless explicitly asked):"
            echo "  --build-only       Build without launching (prevents testing/debugging)"
            exit 0
            ;;
        --clean)
            # Legacy flag - same as --deep-clean
            DEEP_CLEAN=true
            PRESERVE_CACHES=false
            ALWAYS_CLEAN=true
            shift
            ;;
        *)
            # Unknown option
            ;;
    esac
done

# ============================================================================
# Setup Logging
# ============================================================================

cd "$PROJECT_DIR"

# Initialize log file if logging is enabled
if [ "$ENABLE_LOGGING" = true ]; then
    # Create/truncate log file
    echo "Muesli Build & Launch Log" > "$SCRIPT_LOG"
    echo "=========================" >> "$SCRIPT_LOG"
    echo "Started at: $(date)" >> "$SCRIPT_LOG"
    echo "Working directory: $PROJECT_DIR" >> "$SCRIPT_LOG"
    echo "" >> "$SCRIPT_LOG"
fi

# Logging wrapper - outputs to terminal and optionally to log file
log() {
    echo -e "$@"
    if [ "$ENABLE_LOGGING" = true ]; then
        # Strip ANSI color codes when writing to log file
        echo -e "$@" | sed 's/\x1b\[[0-9;]*m//g' >> "$SCRIPT_LOG"
    fi
}

# Override print functions to use logging
print_header() {
    log ""
    log "════════════════════════════════════════════════════════════"
    log "  $1"
    log "════════════════════════════════════════════════════════════"
    log ""
}

print_step() {
    log "${BLUE}▶${NC} $1"
}

print_success() {
    log "${GREEN}✓${NC} $1"
}

print_warning() {
    log "${YELLOW}⚠${NC} $1"
}

print_error() {
    log "${RED}✗${NC} $1"
}

print_info() {
    log "  $1"
}

# ============================================================================
# Detect Configuration
# ============================================================================

print_header "Muesli Build & Launch"

# ============================================================================
# Acquire Build Lock (prevent parallel builds)
# ============================================================================

print_step "Checking for concurrent builds..."

if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would acquire lock: $LOCK_FILE"
else
    # Check if another build is running
    if [ -f "$LOCK_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
            print_error "Another build is already running (PID: $LOCK_PID)"
            print_info "If you believe this is stale, remove: rm $LOCK_FILE"
            exit 1
        else
            # Stale lock file - remove it
            print_info "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Acquire lock
    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED=true
    print_success "Build lock acquired"
fi

log ""

# ============================================================================
# Configuration
# ============================================================================

PRODUCT_NAME="Muesli"
BUNDLE_ID="com.muesli.app"
print_step "Configuration: $PRODUCT_NAME ($BUNDLE_ID)"

# Define paths
DERIVED_DATA="$PROJECT_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/${PRODUCT_NAME}.app"

log ""

# ============================================================================
# Pre-Build Checks
# ============================================================================

print_step "Running pre-build checks..."

# Check for /Applications conflict
if [ -d "/Applications/Muesli.app" ] || [ -d "/Applications/${PRODUCT_NAME}.app" ]; then
    print_warning "Found app in /Applications - this may cause confusion"
    print_info "macOS Launch Services prefers /Applications over DerivedData"
    print_info "Consider removing: rm -rf /Applications/Muesli.app"
fi

# Check for multiple DerivedData folders in standard location
STALE_DD_COUNT=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "Muesli-*" -type d 2>/dev/null | wc -l | tr -d ' ')
if [ "$STALE_DD_COUNT" -gt 0 ]; then
    if [ "$DEEP_CLEAN" = true ]; then
        print_info "Found $STALE_DD_COUNT stale Muesli folder(s) in Xcode DerivedData (will be cleaned)"
    else
        print_warning "Found $STALE_DD_COUNT stale Muesli folder(s) in ~/Library/Developer/Xcode/DerivedData"
        print_info "These may contain old builds. This run will NOT clean them."
    fi
fi

print_success "Pre-build checks complete"
log ""

# ============================================================================
# Kill Running Processes
# ============================================================================

print_step "Stopping running Muesli processes..."

if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would kill: pkill -f 'Muesli'"
else
    # Kill all Muesli variants (handles branch-specific names like Muesli-xxx)
    pkill -f "Muesli" 2>/dev/null || true
    sleep 0.5
    
    # Verify no processes remain
    if pgrep -f "Muesli" > /dev/null 2>&1; then
        print_warning "Some Muesli processes may still be running"
    else
        print_success "No Muesli processes running"
    fi
fi

log ""

# ============================================================================
# Deep Clean (if requested) - Nuclear option for stubborn caching issues
# ============================================================================

if [ "$DEEP_CLEAN" = true ]; then
    print_step "Deep cleaning all caches..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would remove: $DERIVED_DATA"
        print_info "[DRY RUN] Would remove: ~/Library/Developer/Xcode/DerivedData/Muesli-*"
        print_info "[DRY RUN] Would preserve: Swift PM cache (MLX, WhisperKit, etc.)"
        print_info "[DRY RUN] Would remove: Xcode module caches"
        print_info "[DRY RUN] Would clear Launch Services for: $BUNDLE_ID"
    else
        # Remove local DerivedData
        if [ -d "$DERIVED_DATA" ]; then
            rm -rf "$DERIVED_DATA"
            print_success "Removed local DerivedData"
        else
            print_info "No local DerivedData to remove"
        fi
        
        # Remove stale builds from standard Xcode DerivedData location
        STALE_FOLDERS=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "Muesli-*" -type d 2>/dev/null || true)
        if [ -n "$STALE_FOLDERS" ]; then
            STALE_COUNT=$(echo "$STALE_FOLDERS" | wc -l | tr -d ' ')
            rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*
            print_success "Removed $STALE_COUNT stale Muesli folder(s) from Xcode DerivedData"
        fi
        
        # Swift Package Manager cache is preserved by default
        # This cache contains expensive-to-build dependencies like MLX that rarely change
        # To force a full SPM rebuild, manually run: rm -rf ~/Library/Caches/org.swift.swiftpm
        print_info "Swift Package Manager cache preserved (MLX, WhisperKit, etc.)"
        
        # Clear Xcode's module cache for this project
        if [ -d ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex ]; then
            rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex
            print_success "Cleared Xcode module cache"
        fi
        
        # Clear Launch Services cache
        print_info "Clearing Launch Services cache..."
        
        # Find lsregister
        LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        
        if [ -x "$LSREGISTER" ]; then
            # Unregister any old app copies
            "$LSREGISTER" -u "$APP_PATH" 2>/dev/null || true
            "$LSREGISTER" -u "/Applications/Muesli.app" 2>/dev/null || true
            "$LSREGISTER" -u "/Applications/${PRODUCT_NAME}.app" 2>/dev/null || true
            print_success "Cleared Launch Services entries"
        else
            print_warning "lsregister not found - skipping Launch Services cleanup"
        fi
    fi
    echo ""
fi

# ============================================================================
# Preserve caches cleanup (opt-in via --preserve-caches)
# ============================================================================

if [ "$PRESERVE_CACHES" = true ]; then
    print_step "Preserving caches (removing app bundles only)..."

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would keep: $DERIVED_DATA/Build/Intermediates.noindex"
        print_info "[DRY RUN] Would remove: $DERIVED_DATA/Build/Products/Debug/*.app"
        print_info "[DRY RUN] Would preserve: Swift PM cache and Xcode module cache"
    else
        # Keep DerivedData intermediates for fast rebuilds
        if [ -d "$DERIVED_DATA/Build/Products/Debug" ]; then
            rm -rf "$DERIVED_DATA/Build/Products/Debug"/*.app 2>/dev/null || true
            print_success "Removed app bundles from Build/Products/Debug"
        else
            print_info "No Build/Products/Debug directory to clean"
        fi
        print_info "DerivedData intermediates preserved for incremental builds"
    fi
    echo ""
fi

# ============================================================================
# Build
# ============================================================================

print_step "Building ${PRODUCT_NAME}..."
print_info "Configuration: Debug"
print_info "DerivedData: $DERIVED_DATA"
print_info "Build log: $BUILD_LOG"

# Determine build action based on ALWAYS_CLEAN flag
if [ "$ALWAYS_CLEAN" = true ]; then
    BUILD_ACTION="clean build"
    print_info "Build mode: CLEAN BUILD (default - ensures all code changes are compiled)"
else
    BUILD_ACTION="build"
    print_warning "Build mode: INCREMENTAL (may miss code changes!)"
fi
log ""

if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would run: xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug -derivedDataPath ./DerivedData $BUILD_ACTION"
else
    # Ensure DerivedData directory exists
    mkdir -p "$DERIVED_DATA"
    
    # Log the build start
    if [ "$ENABLE_LOGGING" = true ]; then
        echo "" >> "$SCRIPT_LOG"
        echo "xcodebuild started at: $(date)" >> "$SCRIPT_LOG"
        echo "Full xcodebuild output: $BUILD_LOG" >> "$SCRIPT_LOG"
    fi
    
    # Build with deterministic path
    # Use pipefail to capture xcodebuild exit code through the pipe
    BUILD_START=$(date +%s)
    
    set -o pipefail
    # NOTE: Using "clean build" action sequence to ALWAYS recompile everything
    # This prevents stale object files from being linked into the final binary
    if xcodebuild \
        -project Muesli.xcodeproj \
        -scheme Muesli \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        $BUILD_ACTION 2>&1 | tee "$BUILD_LOG" | grep -E "^(Build|Compile|Link|Sign|Copy|===|error:|\*\* BUILD)" ; then
        BUILD_END=$(date +%s)
        BUILD_DURATION=$((BUILD_END - BUILD_START))
        log ""
        # Double-check by looking for BUILD SUCCEEDED in the log
        if grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
            print_success "Build succeeded in ${BUILD_DURATION}s"
        else
            log ""
            print_error "Build failed (check log for errors)"
            print_info "Full build log: $BUILD_LOG"
            # Show the actual errors
            log ""
            print_info "Errors found:"
            grep -E "error:" "$BUILD_LOG" | head -10
            set +o pipefail
            exit 1
        fi
    else
        BUILD_END=$(date +%s)
        BUILD_DURATION=$((BUILD_END - BUILD_START))
        log ""
        print_error "Build failed after ${BUILD_DURATION}s"
        print_info "Full build log: $BUILD_LOG"
        # Show the actual errors
        log ""
        print_info "Errors found:"
        grep -E "error:" "$BUILD_LOG" | head -10
        set +o pipefail
        exit 1
    fi
    set +o pipefail
fi

log ""

# ============================================================================
# Verify Build
# ============================================================================

print_step "Verifying build output..."

if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would verify: $APP_PATH"
else
    # Check app bundle exists
    if [ ! -d "$APP_PATH" ]; then
        print_error "App bundle not found at expected location"
        print_info "Expected: $APP_PATH"
        print_info "Check build log: $BUILD_LOG"
        exit 1
    fi
    print_success "App bundle exists"
    
    # Check modification time (should be within last 2 minutes)
    if [[ $(find "$APP_PATH" -maxdepth 0 -mmin -2 2>/dev/null) ]]; then
        print_success "App was built within the last 2 minutes (fresh build confirmed)"
    else
        print_warning "App modification time is older than 2 minutes"
        print_info "This may indicate the build was cached or incremental"
        print_info "Run without --preserve-caches for a guaranteed fresh build"
    fi
    
    # Show app info
    if [ -f "$APP_PATH/Contents/Info.plist" ]; then
        APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "unknown")
        APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "unknown")
        print_info "Version: $APP_VERSION ($APP_BUILD)"
    fi
fi

log ""

# ============================================================================
# Reset TCC Permissions (OPTIONAL - only when --reset-tcc flag provided)
# ============================================================================
# With stable code signing (DEVELOPMENT_TEAM), TCC permissions persist across builds.
# Resetting is only needed when testing the onboarding flow.

if [ "$RESET_TCC" = true ]; then
    print_step "Resetting system permissions for ${BUNDLE_ID}..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would reset: tccutil reset ScreenCapture $BUNDLE_ID"
        print_info "[DRY RUN] Would reset: tccutil reset Microphone $BUNDLE_ID"
        print_info "[DRY RUN] Would reset: tccutil reset ListenEvent $BUNDLE_ID"
    else
        # Register the app with Launch Services first (so tccutil can find it)
        LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        if [ -x "$LSREGISTER" ] && [ -d "$APP_PATH" ]; then
            "$LSREGISTER" -f "$APP_PATH" 2>/dev/null || true
        fi
        
        # Temporarily disable exit-on-error for tccutil commands
        # tccutil may return non-zero if no entries exist (which is fine)
        set +e
        
        # Reset Screen Recording permission
        tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null
        SCREEN_EXIT=$?
        if [ $SCREEN_EXIT -eq 0 ]; then
            print_success "Reset Screen Recording permission"
        else
            print_info "Screen Recording: no entries to reset"
        fi
        
        # Reset Microphone permission
        tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null
        MIC_EXIT=$?
        if [ $MIC_EXIT -eq 0 ]; then
            print_success "Reset Microphone permission"
        else
            print_info "Microphone: no entries to reset"
        fi

        # Reset System Audio Capture permission (Core Audio taps)
        tccutil reset ListenEvent "$BUNDLE_ID" 2>/dev/null
        LISTEN_EXIT=$?
        if [ $LISTEN_EXIT -eq 0 ]; then
            print_success "Reset System Audio Capture permission"
        else
            print_info "System Audio Capture: no entries to reset"
        fi

        # Re-enable exit-on-error
        set -e
        
        print_info "You will need to re-grant permissions on first launch"
    fi
else
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would skip TCC reset (permissions persist with stable signing)"
    else
        print_info "TCC reset skipped (permissions persist with stable signing)"
    fi
fi

log ""

# ============================================================================
# Launch (unless --build-only)
# ============================================================================

if [ "$BUILD_ONLY" = true ]; then
    print_header "Build Complete (--build-only)"
    print_info "App location: $APP_PATH"
    if [ "$ENABLE_LOGGING" = true ]; then
        print_info "Script log: $SCRIPT_LOG"
    fi
    print_info "xcodebuild log: $BUILD_LOG"
    if [ "$ENABLE_LOGGING" = true ]; then
        log ""
        log "Finished at: $(date)"
    fi
    exit 0
fi

print_step "Launching ${PRODUCT_NAME}..."

if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would launch: open -a \"$APP_PATH\""
else
    # Use full path with -a to bypass Launch Services default selection
    open -a "$APP_PATH"
    
    # Wait for app to start
    sleep 1.5
    
    print_success "App launched"
fi

log ""

# ============================================================================
# Post-Launch Verification
# ============================================================================

print_step "Verifying running process..."

if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would verify process path contains 'DerivedData'"
else
    # Get running process info
    RUNNING_PID=$(pgrep -f "${PRODUCT_NAME}.app/Contents/MacOS" | head -1 || true)
    
    if [ -z "$RUNNING_PID" ]; then
        print_warning "Could not find running ${PRODUCT_NAME} process"
        print_info "The app may still be starting up, or crashed on launch"
    else
        # Get the full path of the running process
        RUNNING_PATH=$(ps -p "$RUNNING_PID" -o command= 2>/dev/null || true)
        
        print_info "PID: $RUNNING_PID"
        print_info "Path: $RUNNING_PATH"
        
        # Verify it's running from our DerivedData
        if [[ "$RUNNING_PATH" == *"DerivedData"* ]]; then
            print_success "VERIFIED: Running from local DerivedData (correct build)"
        elif [[ "$RUNNING_PATH" == *"/Applications/"* ]]; then
            print_error "WARNING: Running from /Applications (WRONG VERSION!)"
            print_info "The app in /Applications is being used instead of the fresh build"
            print_info "Fix: rm -rf /Applications/Muesli.app && ./scripts/build-and-launch.sh"
        else
            print_warning "Process path does not contain expected location"
            print_info "Verify manually that this is the correct build"
        fi
    fi
fi

# ============================================================================
# Summary
# ============================================================================

print_header "Build & Launch Complete"

log "Summary:"
log "  Product:        ${PRODUCT_NAME}"
log "  App Path:       $APP_PATH"
if [ "$ENABLE_LOGGING" = true ]; then
    log "  Script Log:     $SCRIPT_LOG"
fi
log "  xcodebuild Log: $BUILD_LOG"
if [ "$RUNNING_PID" ]; then
    log "  Process ID:     $RUNNING_PID"
fi
log ""

if [ "$DRY_RUN" = true ]; then
    print_info "This was a dry run - no changes were made"
fi

if [ "$ENABLE_LOGGING" = true ]; then
    log "Finished at: $(date)"
fi
