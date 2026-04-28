#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_NAME="CopyCat"
ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"
TAP_DIR="${TAP_DIR:?Set TAP_DIR to your local homebrew-tap checkout}"
CASK_FILE="$TAP_DIR/Casks/copycat.rb"

if [[ ! -f "$ZIP_NAME" ]]; then
    echo "ERROR: $ZIP_NAME not found. Run 'just sign-and-notarize' first." >&2
    exit 1
fi

SHA=$(shasum -a 256 "$ZIP_NAME" | cut -d' ' -f1)

echo "==> Updating cask: version=$MARKETING_VERSION sha256=$SHA"

echo "==> Syncing homebrew-tap..."
cd "$TAP_DIR"
# Pull before writing — other projects push to this repo from CI,
# so the local clone can fall behind. Pulling after writing would
# fail because rebase refuses to run with unstaged changes.
git pull --rebase

echo "==> Updating cask file..."
cd "$ROOT"
mkdir -p "$TAP_DIR/Casks"
cat > "$CASK_FILE" << RUBY
cask "copycat" do
  version "${MARKETING_VERSION}"
  sha256 "${SHA}"

  url "https://github.com/andyhtran/CopyCat/releases/download/v#{version}/CopyCat-#{version}.zip"
  name "CopyCat"
  desc "Image-paste menu bar app for terminals"
  homepage "https://github.com/andyhtran/CopyCat"

  depends_on macos: ">= :sonoma"

  app "CopyCat.app"

  zap trash: [
    "~/Library/Preferences/com.copycat.macos.app.plist",
    "~/Library/Application Support/CopyCat",
    "~/.cache/copycat",
  ]
end
RUBY

echo "==> Committing to homebrew-tap..."
cd "$TAP_DIR"
git add "Casks/copycat.rb"
git commit -m "copycat ${MARKETING_VERSION}"
git push

echo "Done: cask updated to ${MARKETING_VERSION}"
