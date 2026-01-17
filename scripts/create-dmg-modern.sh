#!/bin/bash

# create-dmg-modern.sh - Build Muesli and create a DMG installer using create-dmg tool
#
# Usage:
#   ./scripts/create-dmg-modern.sh [VERSION]
#
# If VERSION is not provided, it will be extracted from Version.xcconfig
# Output: Muesli-vX.X.X.dmg in the project root
#
# This script uses the create-dmg tool (https://github.com/create-dmg/create-dmg)
# Install with: brew install create-dmg

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

log_info "Starting modern DMG creation process..."
log_info "Project root: ${PROJECT_ROOT}"

# Check for create-dmg tool
if ! command -v create-dmg &> /dev/null; then
    log_error "create-dmg tool not found"
    log_error "Install with: brew install create-dmg"
    exit 1
fi

log_success "create-dmg tool found: $(which create-dmg)"

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
APP_PATH=""

# Clean up any previous builds
log_info "Cleaning up previous builds..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Build the app in Release configuration
log_info "Building ${APP_NAME} in Release configuration..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BUILD_LOG="${PROJECT_ROOT}/build-release-${TIMESTAMP}.txt"

if ! xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
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

# Sign the app if Developer ID certificate is available
log_info "Checking for code signing certificate..."
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -n 1 | awk '{print $2}')

if [ -n "$SIGNING_IDENTITY" ]; then
    log_info "Found Developer ID certificate: ${SIGNING_IDENTITY}"
    log_info "Signing app with hardened runtime..."
    
    if codesign --force --deep --options runtime \
        --sign "$SIGNING_IDENTITY" \
        --timestamp \
        "${APP_PATH}"; then
        log_success "App signed successfully with Developer ID"
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

# Remove any existing DMG
FINAL_DMG="${PROJECT_ROOT}/${DMG_NAME}"
if [ -f "${FINAL_DMG}" ]; then
    log_warning "Removing existing DMG: ${FINAL_DMG}"
    rm -f "${FINAL_DMG}"
fi

# Create DMG using create-dmg tool
log_info "Creating DMG with create-dmg tool..."

# Note: create-dmg expects the source app to be in a temporary directory
# It will create the DMG in the current directory
TEMP_APP_DIR="${BUILD_DIR}/app-for-dmg"
mkdir -p "${TEMP_APP_DIR}"
cp -R "${APP_PATH}" "${TEMP_APP_DIR}/"

# Create DMG with custom settings
if create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 200 190 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 600 185 \
    --no-internet-enable \
    "${FINAL_DMG}" \
    "${TEMP_APP_DIR}"; then
    log_success "DMG created successfully"
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
