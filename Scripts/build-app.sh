#!/usr/bin/env bash
# Build SwiftPM product and package it into a .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/version.env"

# YYMMDDHHMM timestamp — unique, monotonic, debuggable. Avoids manual bumping
# and satisfies the App Store / notarization monotonic-build-number rule.
BUILD_NUMBER="$(date +%y%m%d%H%M)"

APP_NAME="CopyCat"
CONFIG="${1:-debug}"

# Bundle ID is configurable so this app can be forked / rebadged without
# editing source. Falls back to a placeholder; users with their own
# Apple Developer team should set this in env or justfile.
RELEASE_BUNDLE_ID="${COPYCAT_BUNDLE_ID:-com.copycat.macos.app}"

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
  echo "Usage: $0 [debug|release]"
  exit 1
fi

cd "$ROOT"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH="$ROOT/.build/$CONFIG/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  BIN_PATH="$(find "$ROOT/.build" -type f -path "*/$CONFIG/$APP_NAME" -print -quit || true)"
fi
if [[ -z "${BIN_PATH:-}" || ! -x "$BIN_PATH" ]]; then
  echo "Could not locate built binary for $APP_NAME ($CONFIG)."
  exit 1
fi

if [[ "$CONFIG" == "release" ]]; then
  BUNDLE_ID="$RELEASE_BUNDLE_ID"
  DISPLAY_NAME="CopyCat"
else
  BUNDLE_ID="${RELEASE_BUNDLE_ID}.dev"
  DISPLAY_NAME="CopyCat Dev"
fi

APP_BUNDLE="$ROOT/build/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy app icon and menu-bar template image into the bundle's Resources/.
# AppIcon.icns is referenced by CFBundleIconFile; MenuBarIcon.pdf is loaded by
# Bundle.main at runtime and registered as a named template image.
for resource in AppIcon.icns MenuBarIcon.pdf; do
  if [[ -f "$ROOT/Resources/$resource" ]]; then
    cp "$ROOT/Resources/$resource" "$APP_BUNDLE/Contents/Resources/$resource"
  fi
done

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${DISPLAY_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${MARKETING_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Copy entitlements next to the bundle (used by sign-and-notarize, not embedded
# in the bundle itself — codesign reads --entitlements from the build dir).
if [[ -f "$ROOT/Resources/CopyCat.entitlements" ]]; then
  cp "$ROOT/Resources/CopyCat.entitlements" "$ROOT/build/CopyCat.entitlements"
fi

echo "Built app bundle: $APP_BUNDLE"
echo "Bundle ID:        $BUNDLE_ID"
echo "Version:          $MARKETING_VERSION ($BUILD_NUMBER)"
