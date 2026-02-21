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

# Pin exact upstream commit for reproducible builds.
# v2.1 tag resolves to this commit in freedesktop/webrtc-audio-processing.
WEBRTC_VERSION="v2.1"
WEBRTC_COMMIT="846fe90a289f58b7c9303a635142aa2c7caa93e5"
WEBRTC_REPO="https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git"
BUILD_DIR="/tmp/webrtc-audio-processing-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/../Muesli/Frameworks"

# macOS deployment target
MACOS_MIN_VERSION="13.0"

echo "=== WebRTC Audio Processing Build Script ==="
echo "Version: $WEBRTC_VERSION"
echo "Commit:  $WEBRTC_COMMIT"
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

# 2. Clone pinned source commit (clean checkout every run)
echo ""
echo "Cloning webrtc-audio-processing $WEBRTC_VERSION at pinned commit..."
rm -rf "$BUILD_DIR"
git clone --branch "$WEBRTC_VERSION" --depth 1 "$WEBRTC_REPO" "$BUILD_DIR"

cd "$BUILD_DIR"

ACTUAL_COMMIT="$(git rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$WEBRTC_COMMIT" ]; then
    echo "ERROR: Expected commit $WEBRTC_COMMIT but got $ACTUAL_COMMIT"
    exit 1
fi
echo "Using pinned commit: $ACTUAL_COMMIT"

# Encourage reproducible archive metadata.
export LC_ALL=C
export ZERO_AR_DATE=1
SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$WEBRTC_COMMIT")"
export SOURCE_DATE_EPOCH
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

# 2.1 Patch: force external delay estimator for AEC3
# The public API doesn't expose EchoCanceller3Config, so we patch the
# AudioProcessingImpl default config to enable external delay estimation.
PATCH_TARGET="$BUILD_DIR/webrtc/modules/audio_processing/audio_processing_impl.cc"
python3 - << 'PY'
from pathlib import Path

path = Path("/tmp/webrtc-audio-processing-build/webrtc/modules/audio_processing/audio_processing_impl.cc")
text = path.read_text()

marker = "EchoCanceller3Config config;"
literal_insertion = "EchoCanceller3Config config;\\n      config.delay.use_external_delay_estimator = true;\\n"
insertion = "EchoCanceller3Config config;\\n      config.delay.use_external_delay_estimator = true;\\n".encode("utf-8").decode("unicode_escape")

# Fix accidental literal "\n" insertion from earlier script runs.
if literal_insertion in text:
    text = text.replace(literal_insertion, insertion)
    path.write_text(text)
    print("Fixed external delay estimator patch formatting.")
    raise SystemExit(0)

if insertion.strip() in text:
    print("External delay estimator patch already applied.")
else:
    if marker not in text:
        raise SystemExit("ERROR: Expected EchoCanceller3Config config marker not found.")
    text = text.replace(marker, insertion, 1)
    path.write_text(text)
    print("Applied external delay estimator patch.")
PY

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
STATIC_LIB_LIST="$BUILD_DIR/static-libs.txt"
find universal/lib -maxdepth 1 -name "*.a" ! -name "libwebrtc-audio-all.a" -print | sort > "$STATIC_LIB_LIST"
if [ ! -s "$STATIC_LIB_LIST" ]; then
    echo "ERROR: No static libraries found to merge"
    exit 1
fi
xargs libtool -static -o universal/lib/libwebrtc-audio-all.a < "$STATIC_LIB_LIST"

echo ""
echo "Creating XCFramework..."
rm -rf webrtc_audio_processing.xcframework

# Stage headers so "api/..." and "absl/..." resolve from one include root.
HEADER_ROOT="universal/include"
STAGED_HEADERS="$BUILD_DIR/headers-stage"
rm -rf "$STAGED_HEADERS"
mkdir -p "$STAGED_HEADERS"
cp -R "$HEADER_ROOT/webrtc-audio-processing-2/"* "$STAGED_HEADERS/"
cp -R "$HEADER_ROOT/absl" "$STAGED_HEADERS/"

xcodebuild -create-xcframework \
    -library "universal/lib/libwebrtc-audio-all.a" \
    -headers "$STAGED_HEADERS" \
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
