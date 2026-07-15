#!/usr/bin/env bash
# Build SwiftPM product and package it into a .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/version.env"

# YYMMDDHHMM timestamp — unique, monotonic, debuggable. Avoids manual bumping
# and satisfies the App Store / notarization monotonic-build-number rule.
# Local Sparkle tests build old and new apps back-to-back, so they inject
# distinct build numbers instead of waiting for the next minute.
BUILD_NUMBER="${COPYCAT_BUILD_NUMBER:-$(date +%y%m%d%H%M)}"

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

BUILD_DIR="$ROOT/.build/$CONFIG"
BIN_PATH="$BUILD_DIR/$APP_NAME"
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
  FEED_URL="https://raw.githubusercontent.com/andyhtran/CopyCat/main/appcast.xml"
  AUTO_CHECKS=true
else
  BUNDLE_ID="${RELEASE_BUNDLE_ID}.dev"
  DISPLAY_NAME="CopyCat Dev"
  FEED_URL=""
  AUTO_CHECKS=false
fi

if [[ -n "${SPARKLE_FEED_URL_OVERRIDE:-}" ]]; then
  if [[ "$CONFIG" != "debug" ]]; then
    echo "SPARKLE_FEED_URL_OVERRIDE is only allowed for debug builds." >&2
    exit 1
  fi
  # Local update-flow testing points the feed at a localhost appcast.
  FEED_URL="$SPARKLE_FEED_URL_OVERRIDE"
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

# Embed Sparkle.framework.
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
if [[ -d "$BUILD_DIR/Sparkle.framework" ]]; then
  mkdir -p "$FRAMEWORKS_DIR"
  cp -R "$BUILD_DIR/Sparkle.framework" "$FRAMEWORKS_DIR/"
  chmod -R a+rX "$FRAMEWORKS_DIR/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

  SPARKLE_FW="$FRAMEWORKS_DIR/Sparkle.framework"

  if [[ "$CONFIG" == "debug" ]]; then
    CODESIGN_ARGS=(--force --sign "-")
  else
    CODESIGN_ARGS=(--force --timestamp --options runtime --sign "${CODESIGN_IDENTITY:--}")
  fi

  resign() { codesign "${CODESIGN_ARGS[@]}" "$1"; }

  resign "$SPARKLE_FW/Versions/B/Sparkle"
  resign "$SPARKLE_FW/Versions/B/Autoupdate"
  resign "$SPARKLE_FW/Versions/B/Updater.app/Contents/MacOS/Updater"
  resign "$SPARKLE_FW/Versions/B/Updater.app"
  resign "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  resign "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
  resign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  resign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
  resign "$SPARKLE_FW/Versions/B"
  resign "$SPARKLE_FW"
fi

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
  <key>SUFeedURL</key>
  <string>${FEED_URL}</string>
  <key>SUPublicEDKey</key>
  <string>${SU_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key>
  <${AUTO_CHECKS}/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUAllowsAutomaticUpdates</key>
  <false/>
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
