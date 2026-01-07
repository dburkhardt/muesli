#!/bin/bash
# Updates menu bar icons from assets/ to the Xcode asset catalog

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

SOURCE_DIR="$REPO_ROOT/assets"
DEST_DIR="$REPO_ROOT/Muesli/Assets.xcassets/MenuBarIcon.imageset"

# Check source files exist
ICONS=("MenuBarIcon.png" "MenuBarIcon@2x.png" "MenuBarIcon@3x.png")

echo "Updating menu bar icons..."

for icon in "${ICONS[@]}"; do
    if [[ -f "$SOURCE_DIR/$icon" ]]; then
        cp "$SOURCE_DIR/$icon" "$DEST_DIR/$icon"
        echo "  ✓ $icon"
    else
        echo "  ✗ $icon not found in assets/"
        exit 1
    fi
done

echo ""
echo "Done! Icons copied to:"
echo "  $DEST_DIR"
echo ""
echo "Rebuild the app to see your changes:"
echo "  xcodebuild -scheme Muesli -configuration Debug build"
