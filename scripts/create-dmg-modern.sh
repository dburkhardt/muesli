#!/bin/bash

# create-dmg-modern.sh - Build Muesli and create a DMG installer using create-dmg tool
#
# Usage:
#   ./scripts/create-dmg-modern.sh [OPTIONS] [VERSION]
#
# Options:
#   --skip-signing    Skip code signing (useful for local testing)
#
# If VERSION is not provided, it will be extracted from Version.xcconfig
# Output: Muesli-vX.X.X.dmg in the project root
#
# This script uses the create-dmg tool (https://github.com/create-dmg/create-dmg)
# Install with: brew install create-dmg

set -euo pipefail

# Parse command line options
SKIP_SIGNING=false
VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-signing)
            SKIP_SIGNING=true
            shift
            ;;
        *)
            VERSION="$1"
            shift
            ;;
    esac
done

# CI detection - use explicit flag to avoid false positives
IS_CI_BUILD=false
if [ "${MUESLI_CI_BUILD:-}" = "1" ]; then
    IS_CI_BUILD=true
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

log_info "Starting modern DMG creation process..."
log_info "Project root: ${PROJECT_ROOT}"
if [ "$SKIP_SIGNING" = true ]; then
    log_info "Code signing will be skipped (--skip-signing)"
fi
if [ "$IS_CI_BUILD" = true ]; then
    log_info "CI build mode: xcodebuild signing disabled, will sign manually with Developer ID"
fi

# Check for create-dmg tool
if ! command -v create-dmg &> /dev/null; then
    log_error "create-dmg tool not found"
    log_error "Install with: brew install create-dmg"
    exit 1
fi

log_success "create-dmg tool found: $(which create-dmg)"

# Extract version from argument or Version.xcconfig
if [ -n "$VERSION" ]; then
    log_info "Using version from argument: ${VERSION}"
else
    # Extract from Version.xcconfig (required)
    if [ ! -f "Version.xcconfig" ]; then
        log_error "Version.xcconfig file not found"
        log_error "The version must be defined in Version.xcconfig or passed as an argument"
        exit 1
    fi
    
    VERSION=$(grep "MARKETING_VERSION" Version.xcconfig | cut -d '=' -f2 | xargs)
    if [ -n "$VERSION" ]; then
        log_info "Extracted version from Version.xcconfig: ${VERSION}"
    fi
    
    # Error if no version found
    if [ -z "$VERSION" ]; then
        log_error "Could not extract MARKETING_VERSION from Version.xcconfig"
        exit 1
    fi
fi

# Configuration
APP_NAME="Muesli"
SCHEME="Muesli"
PROJECT="Muesli.xcodeproj"
CONFIGURATION="Release"
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
BUILD_DIR="${PROJECT_ROOT}/build"
APP_PATH=""

# Clean up any previous builds
log_info "Cleaning up previous builds..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Build the app in Release configuration
log_info "Building ${APP_NAME} in Release configuration..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BUILD_LOG="${PROJECT_ROOT}/build-release-${TIMESTAMP}.txt"

# In CI mode, disable xcodebuild signing (we sign manually with Developer ID later)
SIGNING_FLAGS=""
if [ "$IS_CI_BUILD" = true ]; then
    SIGNING_FLAGS="CODE_SIGN_IDENTITY= CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"
    log_info "xcodebuild signing disabled for CI build"
fi

# Check if WebRTC framework is available (not checked into git, optional dependency)
WEBRTC_FLAGS=()
WEBRTC_FRAMEWORK_PATH="${PROJECT_ROOT}/Muesli/Frameworks/webrtc_audio_processing.xcframework"
if [ ! -d "${WEBRTC_FRAMEWORK_PATH}" ]; then
    log_warning "WebRTC framework not found at ${WEBRTC_FRAMEWORK_PATH}"
    log_info "Building without WebRTC AEC support (stub implementation)"
    # Override linker flags to remove -lwebrtc-audio-all and strip framework search paths
    # that point to the missing xcframework. Use $(inherited) to keep SPM/system paths.
    WEBRTC_FLAGS=(
        'OTHER_LDFLAGS=$(inherited) -lc++'
        'LIBRARY_SEARCH_PATHS=$(inherited)'
        'HEADER_SEARCH_PATHS=$(inherited)'
        'FRAMEWORK_SEARCH_PATHS=$(inherited)'
    )
fi

if ! xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    $SIGNING_FLAGS \
    "${WEBRTC_FLAGS[@]}" \
    clean build 2>&1 | tee "${BUILD_LOG}"; then
    log_error "Build failed! Check ${BUILD_LOG} for details."
    exit 1
fi

log_success "Build completed successfully"

# Find the built app
APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
if [ ! -d "${APP_PATH}" ]; then
    log_error "Could not find built app at ${APP_PATH}"
    exit 1
fi

log_info "Built app found at: ${APP_PATH}"

# Sign the app if Developer ID certificate is available (skip if --skip-signing)
if [ "$SKIP_SIGNING" = true ]; then
    log_warning "Skipping code signing (--skip-signing flag set)"
else
    log_info "Checking for code signing certificate..."
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -n 1 | awk '{print $2}')

    if [ -n "$SIGNING_IDENTITY" ]; then
        log_info "Found Developer ID certificate: ${SIGNING_IDENTITY}"
        log_info "Signing app with hardened runtime..."
        
        # CRITICAL: Include entitlements for hardened runtime
        # Without --entitlements, microphone permission prompt won't appear
        # See: https://developer.apple.com/documentation/security/hardened_runtime
        ENTITLEMENTS_PATH="${PROJECT_ROOT}/Muesli/Muesli.entitlements"
        
        if [ ! -f "${ENTITLEMENTS_PATH}" ]; then
            log_error "Entitlements file not found: ${ENTITLEMENTS_PATH}"
            log_error "Hardened runtime requires entitlements for microphone access"
            exit 1
        fi
        
        log_info "Using entitlements: ${ENTITLEMENTS_PATH}"
        
        # Sign without --deep (deprecated in macOS 13.0)
        # App uses static linking so no nested frameworks to sign separately
        if codesign --force --options runtime \
            --sign "$SIGNING_IDENTITY" \
            --entitlements "${ENTITLEMENTS_PATH}" \
            --timestamp \
            "${APP_PATH}"; then
            log_success "App signed successfully with Developer ID"
            
            # Verify entitlements were embedded
            log_info "Verifying entitlements..."
            if codesign -d --entitlements - "${APP_PATH}" 2>&1 | grep -q "audio-input"; then
                log_success "Entitlements verified: com.apple.security.device.audio-input present"
            else
                log_error "CRITICAL: audio-input entitlement NOT found after signing!"
                log_error "Microphone permission prompt will not appear with hardened runtime"
                exit 1
            fi
            
            # Verify signature integrity (--deep is fine for verification, just not signing)
            log_info "Verifying signature integrity..."
            if ! codesign --verify --deep --strict "${APP_PATH}"; then
                log_error "Signature verification failed"
                exit 1
            fi
            log_success "Signature verification passed"
            
            # Check Gatekeeper acceptance
            log_info "Checking Gatekeeper assessment..."
            if spctl --assess --type execute "${APP_PATH}" 2>&1; then
                log_success "Gatekeeper assessment passed"
            else
                log_warning "Gatekeeper assessment failed (expected if not notarized yet)"
            fi
        else
            log_warning "Code signing failed, continuing with unsigned app"
        fi
    else
        log_warning "No Developer ID certificate found"
        log_warning "App will be signed ad-hoc (users will see warnings)"
    fi

    # Verify app is signed (even if ad-hoc)
    log_info "Verifying app signature..."
    if ! codesign -dv "${APP_PATH}" 2>&1 | grep -q "Signature"; then
        log_warning "App does not appear to be signed. This may cause issues on other machines."
    else
        log_success "App signature verified"
        codesign -dv --verbose=2 "${APP_PATH}" 2>&1 | head -n 5
    fi
fi

# Remove any existing DMG
FINAL_DMG="${PROJECT_ROOT}/${DMG_NAME}"
if [ -f "${FINAL_DMG}" ]; then
    log_warning "Removing existing DMG: ${FINAL_DMG}"
    rm -f "${FINAL_DMG}"
fi

# Check for custom background image
BACKGROUND_IMAGE="${PROJECT_ROOT}/assets/dmg-background.png"
BACKGROUND_ARG=""

if [ -f "${BACKGROUND_IMAGE}" ]; then
    log_info "Using custom background image: ${BACKGROUND_IMAGE}"
    BACKGROUND_ARG="--background ${BACKGROUND_IMAGE}"
elif [ -f "${PROJECT_ROOT}/assets/dmg-background.svg" ]; then
    log_info "Found SVG background, attempting to convert to PNG..."
    # Try to convert SVG to PNG using available tools
    if command -v rsvg-convert &> /dev/null; then
        rsvg-convert -w 1280 -h 720 "${PROJECT_ROOT}/assets/dmg-background.svg" > "${BACKGROUND_IMAGE}"
        log_success "Converted SVG to PNG"
        BACKGROUND_ARG="--background ${BACKGROUND_IMAGE}"
    elif command -v convert &> /dev/null; then
        convert -density 300 -background none "${PROJECT_ROOT}/assets/dmg-background.svg" -resize 1280x720 "${BACKGROUND_IMAGE}"
        log_success "Converted SVG to PNG with ImageMagick"
        BACKGROUND_ARG="--background ${BACKGROUND_IMAGE}"
    else
        log_warning "No tool found to convert SVG. Install rsvg-convert or ImageMagick for custom background."
    fi
else
    log_warning "No custom background found, using default"
fi

# Check for volume icon (use app icon from built app)
VOLICON_PATH="${APP_PATH}/Contents/Resources/AppIcon.icns"
VOLICON_ARG=""

if [ -f "${VOLICON_PATH}" ]; then
    log_info "Using app icon for DMG volume: ${VOLICON_PATH}"
    VOLICON_ARG="--volicon ${VOLICON_PATH}"
else
    log_warning "No volume icon found at ${VOLICON_PATH}, using default"
fi

# Create DMG using create-dmg tool
log_info "Creating DMG with create-dmg tool..."

# Note: create-dmg expects the source app to be in a temporary directory
# It will create the DMG in the current directory
TEMP_APP_DIR="${BUILD_DIR}/app-for-dmg"
mkdir -p "${TEMP_APP_DIR}"
cp -R "${APP_PATH}" "${TEMP_APP_DIR}/"

# Build create-dmg command with optional background
CREATE_DMG_CMD="create-dmg \
    --volname \"${APP_NAME}\" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 128 \
    --icon \"${APP_NAME}.app\" 200 190 \
    --hide-extension \"${APP_NAME}.app\" \
    --app-drop-link 600 185 \
    --no-internet-enable"

# Add background if available
if [ -n "${BACKGROUND_ARG}" ]; then
    CREATE_DMG_CMD="${CREATE_DMG_CMD} ${BACKGROUND_ARG}"
fi

# Add volume icon if available
if [ -n "${VOLICON_ARG}" ]; then
    CREATE_DMG_CMD="${CREATE_DMG_CMD} ${VOLICON_ARG}"
fi

# Add output path and source
CREATE_DMG_CMD="${CREATE_DMG_CMD} \"${FINAL_DMG}\" \"${TEMP_APP_DIR}\""

# Execute create-dmg
if eval ${CREATE_DMG_CMD}; then
    log_success "DMG created successfully"
    
    # Set DMG file icon (requires fileicon tool)
    if [ -f "${VOLICON_PATH}" ]; then
        if command -v fileicon &> /dev/null; then
            log_info "Setting DMG file icon..."
            if fileicon set "${FINAL_DMG}" "${VOLICON_PATH}"; then
                log_success "DMG file icon set successfully"
            else
                log_warning "Failed to set DMG file icon"
            fi
        else
            log_warning "fileicon tool not found. Install with: brew install fileicon"
            log_warning "DMG file will use default icon (volume icon is still set)"
        fi
    fi
else
    log_error "Failed to create DMG with create-dmg"
    log_info "Attempting fallback to legacy script..."
    
    # Clean up and try legacy script
    rm -rf "${BUILD_DIR}"
    
    # Check if legacy script exists
    if [ -f "${SCRIPT_DIR}/create-dmg.sh" ]; then
        log_info "Running legacy create-dmg.sh script..."
        exec "${SCRIPT_DIR}/create-dmg.sh" "${VERSION}"
    else
        log_error "Legacy script not found, cannot fallback"
        exit 1
    fi
fi

# Clean up temporary files
log_info "Cleaning up temporary files..."
rm -rf "${BUILD_DIR}"

# Verify final DMG
log_info "Verifying final DMG..."
if [ ! -f "${FINAL_DMG}" ]; then
    log_error "Final DMG not found at ${FINAL_DMG}"
    exit 1
fi

DMG_SIZE_MB=$(du -m "${FINAL_DMG}" | cut -f1)
log_success "Final DMG created: ${FINAL_DMG} (${DMG_SIZE_MB}MB)"

# Display checksum for verification
log_info "Calculating checksum..."
if command -v shasum &> /dev/null; then
    CHECKSUM=$(shasum -a 256 "${FINAL_DMG}" | awk '{print $1}')
    log_info "SHA-256: ${CHECKSUM}"
fi

# Final instructions
echo ""
log_success "✨ DMG creation completed successfully!"
echo ""
log_info "Next steps:"
echo "  1. Test the DMG:"
echo "     open ${FINAL_DMG}"
echo "  2. Verify installation:"
echo "     - Drag Muesli.app to Applications"
echo "     - Launch from Applications folder"
echo "     - Verify all features work correctly"
echo "  3. Upload for distribution"
echo ""
log_info "DMG location: ${FINAL_DMG}"
echo ""
