#!/bin/bash
# Updates app icons from assets/AppIcon.png to the Xcode asset catalog
# Generates all required sizes (16x16 through 1024x1024 at 1x and 2x scales)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

SOURCE_FILE="$REPO_ROOT/assets/AppIcon.png"
DEST_DIR="$REPO_ROOT/Muesli/Assets.xcassets/AppIcon.appiconset"

# Check source file exists
if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "Error: Source icon not found: $SOURCE_FILE"
    exit 1
fi

# Verify source is 1024x1024 (warn if different)
SOURCE_SIZE=$(sips -g pixelWidth -g pixelHeight "$SOURCE_FILE" 2>/dev/null | grep -E "pixelWidth|pixelHeight" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
if [[ "$SOURCE_SIZE" != "1024x1024" ]]; then
    echo "Warning: Source icon is ${SOURCE_SIZE}, expected 1024x1024"
fi

echo "Updating app icons from $SOURCE_FILE..."

# Ensure destination directory exists
mkdir -p "$DEST_DIR"

# Generate all required icon sizes
# 16x16 (1x and 2x)
sips -z 16 16 "$SOURCE_FILE" --out "$DEST_DIR/icon_16x16.png" > /dev/null 2>&1
sips -z 32 32 "$SOURCE_FILE" --out "$DEST_DIR/icon_16x16@2x.png" > /dev/null 2>&1
echo "  ✓ Generated 16x16 icons"

# 32x32 (1x and 2x)
sips -z 32 32 "$SOURCE_FILE" --out "$DEST_DIR/icon_32x32.png" > /dev/null 2>&1
sips -z 64 64 "$SOURCE_FILE" --out "$DEST_DIR/icon_32x32@2x.png" > /dev/null 2>&1
echo "  ✓ Generated 32x32 icons"

# 128x128 (1x and 2x)
sips -z 128 128 "$SOURCE_FILE" --out "$DEST_DIR/icon_128x128.png" > /dev/null 2>&1
sips -z 256 256 "$SOURCE_FILE" --out "$DEST_DIR/icon_128x128@2x.png" > /dev/null 2>&1
echo "  ✓ Generated 128x128 icons"

# 256x256 (1x and 2x)
sips -z 256 256 "$SOURCE_FILE" --out "$DEST_DIR/icon_256x256.png" > /dev/null 2>&1
sips -z 512 512 "$SOURCE_FILE" --out "$DEST_DIR/icon_256x256@2x.png" > /dev/null 2>&1
echo "  ✓ Generated 256x256 icons"

# 512x512 (1x and 2x)
sips -z 512 512 "$SOURCE_FILE" --out "$DEST_DIR/icon_512x512.png" > /dev/null 2>&1
sips -z 1024 1024 "$SOURCE_FILE" --out "$DEST_DIR/icon_512x512@2x.png" > /dev/null 2>&1
echo "  ✓ Generated 512x512 icons"

# Generate Contents.json
cat > "$DEST_DIR/Contents.json" << 'EOF'
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "  ✓ Updated Contents.json"

echo ""
echo "Done! App icons updated in:"
echo "  $DEST_DIR"
echo ""
echo "All 10 icon sizes generated successfully."
