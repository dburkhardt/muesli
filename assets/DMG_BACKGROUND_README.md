# DMG Background

This directory contains the background image for the DMG installer.

## Files

- `dmg-background.png` - **Primary background image** (1280x720px) - Create this file directly
- `dmg-background.svg` - Legacy SVG source (optional, scripts will convert if PNG not found)

## Creating the Background Image

**Preferred method**: Create `dmg-background.png` directly using your preferred graphics tool (Figma, Sketch, Photoshop, etc.)

**Specifications:**
- **Size**: 1280x720 pixels
- **Format**: PNG (with transparency if needed)
- **Location**: `assets/dmg-background.png`

The DMG creation scripts will automatically use this PNG file. If it doesn't exist, they will attempt to convert `dmg-background.svg` to PNG as a fallback.

## Converting SVG to PNG (Fallback)

If you need to convert the SVG to PNG, use one of these methods:

### Using ImageMagick (recommended for high quality):
```bash
convert -density 300 -background none dmg-background.svg -resize 1280x720 dmg-background.png
```

### Using rsvg-convert (alternative):
```bash
rsvg-convert -w 1280 -h 720 dmg-background.svg > dmg-background.png
```

### Using macOS qlmanage (built-in):
```bash
qlmanage -t -s 1280 -o . dmg-background.svg
mv dmg-background.svg.png dmg-background.png
```

### Using CairoSVG (Python):
```bash
pip install cairosvg
cairosvg dmg-background.svg -o dmg-background.png -W 1280 -H 720
```

## Design Notes

The background is a clean gradient design. **Do not include** app icons, arrows, or text - these are automatically handled by the DMG creation script:
- App icon is automatically placed at x=200, y=190
- Applications folder icon is automatically placed at x=600, y=185
- Window title and other UI elements are handled by macOS

**Color Palette** (matching app branding):
- **Base**: #FFF8F0 (cream) - warm, inviting background
- **Gradient accent**: #E86A34 to #F9C66B (orange-to-gold gradient) - matches app icon
- Keep it minimal and clean - a beautiful gradient background is all that's needed

**Window Layout:**
- DMG window size: 800x400 pixels
- Background image: 1280x720 pixels (scales automatically to fit window)
