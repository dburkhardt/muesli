#!/bin/bash

# create-dmg.sh - Build Muesli and create a DMG installer
#
# Usage:
#   ./scripts/create-dmg.sh [VERSION]
#
# If VERSION is not provided, it will be extracted from Version.xcconfig (MARKETING_VERSION)
# with fallback to project.pbxproj
# Output: Muesli-vX.X.X.dmg in the project root

set -euo pipefail

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

log_info "Starting DMG creation process..."
log_info "Project root: ${PROJECT_ROOT}"

# Extract version from argument or Version.xcconfig
if [ $# -ge 1 ]; then
    VERSION="$1"
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
TEMP_DMG_DIR="${BUILD_DIR}/dmg-temp"
APP_PATH=""

# Clean up any previous builds
log_info "Cleaning up previous builds..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${TEMP_DMG_DIR}"

# CI detection - use explicit flag to avoid false positives
IS_CI_BUILD=false
if [ "${MUESLI_CI_BUILD:-}" = "1" ]; then
    IS_CI_BUILD=true
fi

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
    # Create a stub library to satisfy the -lwebrtc-audio-all linker flag.
    STUB_DIR="${BUILD_DIR}/webrtc-stub"
    mkdir -p "${STUB_DIR}"
    echo "void __webrtc_stub(void) {}" > "${STUB_DIR}/stub.c"
    clang -c -arch arm64 "${STUB_DIR}/stub.c" -o "${STUB_DIR}/stub_arm64.o"
    clang -c -arch x86_64 "${STUB_DIR}/stub.c" -o "${STUB_DIR}/stub_x86_64.o"
    ar rcs "${STUB_DIR}/libwebrtc-audio-all_arm64.a" "${STUB_DIR}/stub_arm64.o"
    ar rcs "${STUB_DIR}/libwebrtc-audio-all_x86_64.a" "${STUB_DIR}/stub_x86_64.o"
    lipo -create "${STUB_DIR}/libwebrtc-audio-all_arm64.a" "${STUB_DIR}/libwebrtc-audio-all_x86_64.a" \
        -output "${STUB_DIR}/libwebrtc-audio-all.a"
    FRAMEWORK_STUB_DIR="${PROJECT_ROOT}/Muesli/Frameworks/webrtc_audio_processing.xcframework/macos-arm64_x86_64"
    mkdir -p "${FRAMEWORK_STUB_DIR}"
    cp "${STUB_DIR}/libwebrtc-audio-all.a" "${FRAMEWORK_STUB_DIR}/"
    log_info "Created universal stub libwebrtc-audio-all.a"
    WEBRTC_FLAGS=()
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

# Verify app is signed (even if ad-hoc)
log_info "Verifying app signature..."
if ! codesign -dv "${APP_PATH}" 2>&1 | grep -q "Signature"; then
    log_warning "App does not appear to be signed. This may cause issues on other machines."
else
    log_success "App signature verified"
fi

# Copy app to temp DMG directory
log_info "Preparing DMG contents..."
cp -R "${APP_PATH}" "${TEMP_DMG_DIR}/"

# Create Applications symlink for drag-and-drop installation
ln -s /Applications "${TEMP_DMG_DIR}/Applications"

# Create a background image with installation instructions
# We'll use a simple text file approach for now (can be enhanced with an actual image later)
cat > "${TEMP_DMG_DIR}/.background.txt" << 'EOF'
Drag Muesli to the Applications folder to install.
EOF

# Create .DS_Store configuration for icon positioning
# This creates a proper layout: App icon on left, Applications folder on right
python3 - << 'EOF'
import sys
import struct
import os

def create_ds_store():
    """
    Creates a basic .DS_Store file for DMG layout.
    This positions the app icon and Applications symlink.
    """
    # For a proper .DS_Store, we'd need a library like ds_store
    # For now, we'll rely on hdiutil's automatic layout
    pass

create_ds_store()
EOF

# Calculate appropriate DMG size
log_info "Calculating DMG size..."
TEMP_SIZE=$(du -sm "${TEMP_DMG_DIR}" | cut -f1)
DMG_SIZE=$((TEMP_SIZE + 50)) # Add 50MB headroom

log_info "Creating temporary DMG (${DMG_SIZE}MB)..."
TEMP_DMG="${BUILD_DIR}/${APP_NAME}-temp.dmg"

# Create temporary DMG
if ! hdiutil create \
    -srcfolder "${TEMP_DMG_DIR}" \
    -volname "${APP_NAME}" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size ${DMG_SIZE}m \
    "${TEMP_DMG}"; then
    log_error "Failed to create temporary DMG"
    exit 1
fi

log_success "Temporary DMG created"

# Mount the temporary DMG
log_info "Mounting temporary DMG for customization..."
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "${TEMP_DMG}" 2>&1)
MOUNT_DIR=$(echo "${MOUNT_OUTPUT}" | grep -E '/Volumes/' | tail -1 | sed 's/.*\(\/Volumes\/.*\)/\1/')

if [ -z "${MOUNT_DIR}" ]; then
    log_error "Failed to mount temporary DMG"
    log_error "Mount output: ${MOUNT_OUTPUT}"
    exit 1
fi

log_info "Mounted at: ${MOUNT_DIR}"

# Configure the DMG window appearance using AppleScript
log_info "Configuring DMG window appearance..."
cat > /tmp/dmg_setup.applescript << EOF
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 940, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 120
        
        -- Position app icon (left) and Applications symlink (right)
        -- Window is 540x380, so centering items at y=190 vertically
        set position of item "${APP_NAME}.app" of container window to {140, 190}
        set position of item "Applications" of container window to {400, 190}
        
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# Note: AppleScript DMG customization requires GUI access
# For automated builds, we'll skip this and use simpler layout
if [ -n "${CI:-}" ]; then
    log_warning "CI environment detected, skipping AppleScript customization"
else
    # Try to run AppleScript customization (may fail in non-GUI environments)
    if osascript /tmp/dmg_setup.applescript 2>/dev/null; then
        log_success "DMG window customization applied"
    else
        log_warning "Could not apply AppleScript customization (GUI required)"
    fi
fi

# Set custom icon positioning using SetFile if available
if command -v SetFile &> /dev/null; then
    log_info "Setting custom icon attributes..."
    SetFile -a C "${MOUNT_DIR}"
else
    log_warning "SetFile not found, skipping custom attributes"
fi

# Unmount the temporary DMG
log_info "Unmounting temporary DMG..."
sync
if ! hdiutil detach "${MOUNT_DIR}"; then
    log_error "Failed to unmount temporary DMG"
    exit 1
fi

sleep 2

# Convert to compressed final DMG
log_info "Creating final compressed DMG..."
FINAL_DMG="${PROJECT_ROOT}/${DMG_NAME}"

if [ -f "${FINAL_DMG}" ]; then
    log_warning "Removing existing DMG: ${FINAL_DMG}"
    rm -f "${FINAL_DMG}"
fi

if ! hdiutil convert \
    "${TEMP_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${FINAL_DMG}"; then
    log_error "Failed to create final DMG"
    exit 1
fi

# Clean up temporary files
log_info "Cleaning up temporary files..."
rm -rf "${BUILD_DIR}"
rm -f /tmp/dmg_setup.applescript

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
