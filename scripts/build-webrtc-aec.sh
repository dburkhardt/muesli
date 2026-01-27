#!/bin/bash
# Build WebRTC Audio Processing v1.3 XCFramework for Muesli
# 
# This script builds the FreeDesktop webrtc-audio-processing library as a static
# XCFramework for macOS (arm64 + x86_64). The library provides WebRTC's AEC3
# echo cancellation algorithm.
#
# Prerequisites:
#   brew install meson ninja pkg-config
#
# Usage:
#   ./scripts/build-webrtc-aec.sh
#
set -euo pipefail

WEBRTC_VERSION="v1.3"
WEBRTC_REPO="https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git"
BUILD_DIR="/tmp/webrtc-audio-processing-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/../Muesli/Frameworks"

# macOS deployment target
MACOS_MIN_VERSION="13.0"

echo "=== WebRTC Audio Processing Build Script ==="
echo "Version: $WEBRTC_VERSION"
echo "Output:  $OUTPUT_DIR"
echo ""

# 1. Check dependencies
echo "Checking dependencies..."
MISSING_DEPS=""
for cmd in meson ninja pkg-config lipo xcodebuild; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_DEPS="$MISSING_DEPS $cmd"
    fi
done

if [ -n "$MISSING_DEPS" ]; then
    echo "ERROR: Missing dependencies:$MISSING_DEPS"
    echo ""
    echo "Install with: brew install meson ninja pkg-config"
    exit 1
fi

echo "All dependencies found."

# 2. Clone if needed
if [ ! -d "$BUILD_DIR" ]; then
    echo ""
    echo "Cloning webrtc-audio-processing $WEBRTC_VERSION..."
    git clone --branch "$WEBRTC_VERSION" --depth 1 "$WEBRTC_REPO" "$BUILD_DIR"
else
    echo ""
    echo "Using existing source at $BUILD_DIR"
fi

cd "$BUILD_DIR"

# 3. Create cross-compilation files for macOS
echo ""
echo "Creating cross-compilation files..."

cat > cross_arm64.txt << 'EOF'
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
strip = 'strip'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
cpp_args = ['-arch', 'arm64', '-mmacosx-version-min=13.0', '-stdlib=libc++']
cpp_link_args = ['-arch', 'arm64', '-mmacosx-version-min=13.0']
c_args = ['-arch', 'arm64', '-mmacosx-version-min=13.0']
c_link_args = ['-arch', 'arm64', '-mmacosx-version-min=13.0']
EOF

cat > cross_x86_64.txt << 'EOF'
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
strip = 'strip'

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[built-in options]
cpp_args = ['-arch', 'x86_64', '-mmacosx-version-min=13.0', '-stdlib=libc++']
cpp_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=13.0']
c_args = ['-arch', 'x86_64', '-mmacosx-version-min=13.0']
c_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=13.0']
EOF

# 4. Build arm64
echo ""
echo "Building for arm64..."
rm -rf build_arm64 install_arm64
meson setup build_arm64 \
    --cross-file cross_arm64.txt \
    -Dprefix="$PWD/install_arm64" \
    -Ddefault_library=static \
    -Dbuildtype=release
meson compile -C build_arm64
meson install -C build_arm64

# 5. Build x86_64
echo ""
echo "Building for x86_64..."
rm -rf build_x86_64 install_x86_64
meson setup build_x86_64 \
    --cross-file cross_x86_64.txt \
    -Dprefix="$PWD/install_x86_64" \
    -Ddefault_library=static \
    -Dbuildtype=release
meson compile -C build_x86_64
meson install -C build_x86_64

# 6. Create universal binaries for BOTH libraries
echo ""
echo "Creating universal binaries..."
mkdir -p universal/lib universal/include

# Find ALL static libraries
for lib_file in install_arm64/lib/*.a; do
    LIB_NAME=$(basename "$lib_file")
    ARM64_LIB="install_arm64/lib/$LIB_NAME"
    X86_64_LIB="install_x86_64/lib/$LIB_NAME"
    
    if [ -f "$ARM64_LIB" ] && [ -f "$X86_64_LIB" ]; then
        echo "Creating universal binary for: $LIB_NAME"
        lipo -create \
            "$ARM64_LIB" \
            "$X86_64_LIB" \
            -output "universal/lib/$LIB_NAME"
    else
        echo "WARNING: Missing architecture for $LIB_NAME"
    fi
done

# List all libraries created
echo ""
echo "Universal libraries created:"
ls -la universal/lib/

# Copy headers (same for both architectures)
cp -R install_arm64/include/* universal/include/

# 7. Create XCFramework with merged library
# Merge all .a files into a single archive for XCFramework
echo ""
echo "Merging libraries into single archive..."
libtool -static -o universal/lib/libwebrtc-audio-all.a universal/lib/*.a

echo ""
echo "Creating XCFramework..."
rm -rf webrtc_audio_processing.xcframework

xcodebuild -create-xcframework \
    -library "universal/lib/libwebrtc-audio-all.a" \
    -headers universal/include \
    -output webrtc_audio_processing.xcframework

# 8. Verify build
echo ""
echo "Verifying build..."
FRAMEWORK_LIB=$(find webrtc_audio_processing.xcframework -name "*.a" -type f | head -1)

if [ -z "$FRAMEWORK_LIB" ]; then
    echo "ERROR: XCFramework library not found"
    exit 1
fi

echo "Library architectures:"
lipo -info "$FRAMEWORK_LIB"

# Check for required symbols
if nm "$FRAMEWORK_LIB" | grep -q "AudioProcessing"; then
    echo "AudioProcessing symbols found."
else
    echo "WARNING: AudioProcessing symbols not found - library may not work correctly"
fi

# 9. Copy to project
echo ""
echo "Copying to project..."
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/webrtc_audio_processing.xcframework"
cp -R webrtc_audio_processing.xcframework "$OUTPUT_DIR/"

# 10. Generate checksum
shasum -a 256 "$FRAMEWORK_LIB" > "$OUTPUT_DIR/webrtc_audio_processing.sha256"

echo ""
echo "=== Build Complete ==="
echo "XCFramework: $OUTPUT_DIR/webrtc_audio_processing.xcframework"
echo "Checksum:    $OUTPUT_DIR/webrtc_audio_processing.sha256"
echo ""
echo "Next steps:"
echo "1. Add the XCFramework to your Xcode project"
echo "2. Link against the Accelerate framework"
echo "3. Build and test the WebRTC AEC integration"
