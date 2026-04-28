#!/usr/bin/env bash
# Regenerate AppIcon.icns and MenuBarIcon.pdf from the SVG sources.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_ICON_SVG="Icons/AppIcon.svg"
MENU_ICON_SVG="Icons/MenuBarIcon.svg"

ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET" Resources

rsvg-convert -w 16   -h 16   "$APP_ICON_SVG" -o "$ICONSET/icon_16x16.png"
rsvg-convert -w 32   -h 32   "$APP_ICON_SVG" -o "$ICONSET/icon_16x16@2x.png"
rsvg-convert -w 32   -h 32   "$APP_ICON_SVG" -o "$ICONSET/icon_32x32.png"
rsvg-convert -w 64   -h 64   "$APP_ICON_SVG" -o "$ICONSET/icon_32x32@2x.png"
rsvg-convert -w 128  -h 128  "$APP_ICON_SVG" -o "$ICONSET/icon_128x128.png"
rsvg-convert -w 256  -h 256  "$APP_ICON_SVG" -o "$ICONSET/icon_128x128@2x.png"
rsvg-convert -w 256  -h 256  "$APP_ICON_SVG" -o "$ICONSET/icon_256x256.png"
rsvg-convert -w 512  -h 512  "$APP_ICON_SVG" -o "$ICONSET/icon_256x256@2x.png"
rsvg-convert -w 512  -h 512  "$APP_ICON_SVG" -o "$ICONSET/icon_512x512.png"
rsvg-convert -w 1024 -h 1024 "$APP_ICON_SVG" -o "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rsvg-convert -f pdf "$MENU_ICON_SVG" -o Resources/MenuBarIcon.pdf

echo "Generated:"
echo "  Resources/AppIcon.icns"
echo "  Resources/MenuBarIcon.pdf"
