#!/usr/bin/env bash
# Sign the CopyCat .app bundle.
#
# Cert resolution order:
#   1. $COPYCAT_SIGNING_CERT (explicit override)
#   2. First "Apple Development:" identity in the keychain
#   3. Ad-hoc ("-") with a loud warning
#
# Apple Development / Developer ID signatures key Accessibility grants on
# (TeamID, bundle ID), so the grant survives every rebuild. Ad-hoc keys the
# grant on cdhash, which changes on every rebuild — so plain `just dev`
# without a real cert means re-granting Accessibility every cycle.
set -euo pipefail

APP="${1:?usage: sign-app.sh <path/to/App.app>}"

CERT="${COPYCAT_SIGNING_CERT:-}"

if [[ -z "$CERT" ]]; then
  CERT="$(security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'"' '/"Apple Development:/ {print $2; exit}')"
fi

if [[ -z "$CERT" || "$CERT" == "-" ]]; then
  cat >&2 <<'WARN'
⚠️  No Apple Development cert found — using ad-hoc signature.
   Accessibility grants will be REVOKED on every rebuild.
   Fix: install an Apple Development cert, or set
        export COPYCAT_SIGNING_CERT="Apple Development: Your Name (TEAMID)"
WARN
  CERT="-"
fi

echo "Signing $APP"
echo "    cert: $CERT"
codesign --force --deep --sign "$CERT" "$APP"
