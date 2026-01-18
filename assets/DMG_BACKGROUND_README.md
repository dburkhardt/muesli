# DMG Background

This directory contains the background image for the DMG installer.

## Files

- `dmg-background.svg` - Source SVG file (scalable vector format)
- `dmg-background.png` - Generated PNG for DMG (1280x720px)

## Generating PNG from SVG

To convert the SVG to PNG for use in the DMG:

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

The background features:
- Clean, minimal macOS-style design
- App icon on the left (with shadow)
- Arrow pointing to Applications folder on the right
- Applications folder icon
- Product tagline
- Installation instructions

Colors match macOS Big Sur+ design language:
- Background: #f5f5f7 (light gray)
- Primary: #007AFF (blue)
- Secondary: #5AC8FA (cyan for folder)
- Text: #1d1d1f, #6e6e73, #86868b (grays)
