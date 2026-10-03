#!/bin/bash
#
# Builds the installer DMG: the app and an Applications link, large icons on
# a background that shows dragging one onto the other. The layout is in
# Packaging/dmg/settings.py; the DMG is not signed here.
#
# Usage: Scripts/make-dmg.sh <LocalDesktop.app> <output.dmg> [volume name]

set -euo pipefail

usage="usage: make-dmg.sh <LocalDesktop.app> <output.dmg> [volume name]"
APP="${1:?$usage}"
DMG="${2:?$usage}"
VOLUME_NAME="${3:-LocalDesktop}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PACKAGING="$SCRIPT_DIR/../Packaging/dmg"

[[ -d "$APP" ]] || { echo "No app at $APP" >&2; exit 1; }

# dmgbuild writes Finder's layout file itself instead of scripting Finder,
# which CI runners can't do reliably. Its packages are pinned by hash: in the
# release workflow it runs while the signing keychain is unlocked.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes \
    -r "$PACKAGING/requirements.txt"

rm -f "$DMG"
# hdiutil occasionally fails with "Resource busy" on CI runners.
for attempt in 1 2 3; do
    "$work/venv/bin/dmgbuild" -s "$PACKAGING/settings.py" \
        -D app="$APP" -D background="$PACKAGING/background.png" \
        "$VOLUME_NAME" "$DMG" && break
    [[ $attempt -eq 3 ]] && exit 1
    rm -f "$DMG"
    sleep 10
done
echo "Built $DMG"
