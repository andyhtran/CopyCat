# CopyCat — image-paste menu bar app for terminals.

app_name := "CopyCat"
bundle_id := "com.copycat.macos.app"
install_path := "/Applications/CopyCat Dev.app"

# `Scripts/sign-app.sh` resolves the signing cert in this order:
#   1. $COPYCAT_SIGNING_CERT (explicit override)
#   2. First "Apple Development:" identity in the keychain
#   3. Ad-hoc, with a loud warning

default:
    @just --list --unsorted

# Kill, rebuild, sign, install, launch — full dev cycle.
[group('dev')]
dev:
    -pkill -x "{{app_name}}" 2>/dev/null || true
    @sleep 0.3
    bash Scripts/build-app.sh debug
    bash Scripts/sign-app.sh "build/{{app_name}}.app"
    rm -rf "{{install_path}}"
    cp -R "build/{{app_name}}.app" "{{install_path}}"
    open "{{install_path}}"

# Wipe stale Accessibility grants for the dev and release bundle IDs.
# After running, relaunch CopyCat — you'll get one fresh prompt to approve.
[group('dev')]
reset-grants:
    -tccutil reset Accessibility {{bundle_id}}.dev || true
    -tccutil reset Accessibility {{bundle_id}} || true
    @echo "Done — relaunch CopyCat and re-approve once."

[group('dev')]
clean:
    swift package clean
    rm -rf build *.zip *.dmg

# Sign + notarize the release bundle (requires CODESIGN_IDENTITY).
[group('release')]
sign-and-notarize:
    bash Scripts/sign-and-notarize.sh

# Wrap the signed app in a styled DMG (requires `brew install create-dmg`).
[group('release')]
create-dmg: sign-and-notarize
    bash Scripts/create-dmg.sh

# Tag, push, and create a GitHub release with the zip + dmg attached.
[group('release')]
github-release: sign-and-notarize create-dmg
    #!/usr/bin/env bash
    set -euo pipefail
    source version.env
    TAG="v${MARKETING_VERSION}"
    ZIP="CopyCat-${MARKETING_VERSION}.zip"
    DMG="CopyCat.dmg"
    git tag -f "$TAG"
    git push -f origin "$TAG"
    gh release create "$TAG" "$ZIP" "$DMG" \
        --title "CopyCat ${MARKETING_VERSION}" \
        --generate-notes

# Update the homebrew tap cask (requires TAP_DIR env var).
[group('release')]
update-tap:
    bash Scripts/update-tap.sh

# Full release: sign + notarize, GitHub release, update tap.
[group('release')]
publish: github-release update-tap
    @echo "Release complete!"
