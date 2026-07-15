#!/usr/bin/env bash
#
# Local end-to-end test of the Sparkle update flow with the real updater:
#
#   1. Builds the current version as "CopyCat Dev.app", Developer ID signed
#      (required for UpdaterFactory to enable Sparkle), with its feed pointed
#      at a localhost appcast.
#   2. Builds a version-bumped copy, signs it, zips it, and generates a
#      signed appcast for it (requires the Sparkle EdDSA private key in the
#      login Keychain, same as a real release).
#   3. Serves zip + appcast on localhost and launches the old version.
#
# From there: use the menu or Settings window to Check for Updates, click
# Install Update, and watch downloading → preparing → installing → relaunch as
# the bumped version. Ctrl-C stops the server.
#
# Nothing is committed or uploaded; version.env is restored on exit.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PORT="${PORT:-8123}"
FEED="http://localhost:${PORT}/appcast.xml"
INSTALL_PATH="/Applications/CopyCat Dev.app"
DEV_EXEC="${INSTALL_PATH}/Contents/MacOS/CopyCat"
DEV_BUNDLE_ID="${COPYCAT_BUNDLE_ID:-com.copycat.macos.app}.dev"
SIGNING_ID="${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your Developer ID Application identity}"

if ! command -v generate_appcast &>/dev/null; then
    echo "generate_appcast not found. Install: brew install andyhtran/tap/sparkle-tools" >&2
    exit 1
fi

source version.env
SERVE_DIR=$(mktemp -d /tmp/copycat-update-test.XXXXXX)
VERSION_BACKUP=$(mktemp /tmp/copycat-version-env.XXXXXX)
cp version.env "$VERSION_BACKUP"
OLD_BUILD=$(date +%y%m%d%H%M%S)
NEW_BUILD=$((OLD_BUILD + 1))

SERVER_PID=""
cleanup() {
    cp "$VERSION_BACKUP" version.env
    rm -f "$VERSION_BACKUP"
    rm -rf "$SERVE_DIR"
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

quit_dev_app() {
    osascript -e "tell application id \"${DEV_BUNDLE_ID}\" to quit" \
        >/dev/null 2>&1 || true
    sleep 1
    while read -r pid; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < <(pgrep -f "$DEV_EXEC" 2>/dev/null || true)
}

sign_dev_with_developer_id() {
    local app=${1:?usage: sign_dev_with_developer_id <App.app>}
    codesign --force --deep --timestamp --options runtime \
        --sign "$SIGNING_ID" \
        --entitlements "build/CopyCat.entitlements" \
        "$app"
}

echo "==> Building current version (${MARKETING_VERSION}, build ${OLD_BUILD})..."
COPYCAT_BUILD_NUMBER="$OLD_BUILD" \
    SPARKLE_FEED_URL_OVERRIDE="$FEED" bash Scripts/build-app.sh debug
sign_dev_with_developer_id "build/CopyCat.app"

echo "==> Installing to ${INSTALL_PATH}..."
quit_dev_app
rm -rf "$INSTALL_PATH"
cp -R "build/CopyCat.app" "$INSTALL_PATH"

NEW_MARKETING="${MARKETING_VERSION%.*}.$((${MARKETING_VERSION##*.} + 1))"
echo "==> Building update (${NEW_MARKETING}, build ${NEW_BUILD})..."
sed -i '' \
    -e "s/^MARKETING_VERSION=.*/MARKETING_VERSION=${NEW_MARKETING}/" \
    version.env
COPYCAT_BUILD_NUMBER="$NEW_BUILD" \
    SPARKLE_FEED_URL_OVERRIDE="$FEED" bash Scripts/build-app.sh debug
cp "$VERSION_BACKUP" version.env
sign_dev_with_developer_id "build/CopyCat.app"

echo "==> Generating signed appcast..."
/usr/bin/ditto -c -k --keepParent "build/CopyCat.app" \
    "$SERVE_DIR/CopyCat-${NEW_MARKETING}.zip"
rm -rf "build/CopyCat.app"
generate_appcast \
    --download-url-prefix "http://localhost:${PORT}/" \
    --link "$FEED" \
    "$SERVE_DIR"

echo "==> Serving appcast on port ${PORT}..."
python3 -m http.server "$PORT" --directory "$SERVE_DIR" --bind 127.0.0.1 \
    >/dev/null 2>&1 &
SERVER_PID=$!

# The debug-only UpdateSimulator shadows the real updater when its defaults
# key is set; a leftover key from a simulator session would silently turn
# this whole test into a simulation.
defaults delete "$DEV_BUNDLE_ID" "UpdateSimulatorScenario" 2>/dev/null || true

open "$INSTALL_PATH"

cat <<INSTRUCTIONS

Running: CopyCat Dev ${MARKETING_VERSION} (build ${OLD_BUILD})
Update:  ${NEW_MARKETING} (build ${NEW_BUILD}) served at ${FEED}

Try it:
  - Menu → "Check for Updates", or Settings → "Check Now".
  - Expect the menu to show "Install Update ${NEW_MARKETING}" and "Later".
  - Click Install Update, then watch Downloading → Preparing → Installing →
    app relaunches as ${NEW_MARKETING}.
  - Scheduled background checks are enabled too; if you wait instead of
    clicking, discovery arrives as a menu item + notification.

Verify afterwards: Settings → About shows ${NEW_MARKETING}.

Ctrl-C stops the server (version.env already restored).
INSTRUCTIONS

wait "$SERVER_PID"
