#!/bin/bash
#
# Submits a zip, dmg or pkg to Apple's notary service and waits for the
# verdict; prints Apple's log and fails when it is not accepted.
#
# Usage: Scripts/notarize.sh <file>
# Environment: NOTARY_APPLE_ID, NOTARY_PASSWORD (an app-specific password),
# TEAM_ID (defaults to DEVELOPMENT_TEAM in project.yml).

set -euo pipefail

FILE="${1:?usage: notarize.sh <file>}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
TEAM_ID="${TEAM_ID:-$(awk '$1 == "DEVELOPMENT_TEAM:" { gsub(/"/, "", $2); print $2; exit }' "$SCRIPT_DIR/../project.yml")}"
: "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID is not set}"
: "${NOTARY_PASSWORD:?NOTARY_PASSWORD is not set}"
[[ -n "$TEAM_ID" ]] || { echo "No team ID (set TEAM_ID or DEVELOPMENT_TEAM in project.yml)" >&2; exit 1; }

credentials=(--apple-id "$NOTARY_APPLE_ID" --team-id "$TEAM_ID" --password "$NOTARY_PASSWORD")

echo "Notarizing $(basename "$FILE")..."
result="$(xcrun notarytool submit "$FILE" "${credentials[@]}" --wait --timeout 30m --output-format json)"
echo "$result"
status="$(printf '%s' "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))')"
submission="$(printf '%s' "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))')"

if [[ "$status" != "Accepted" ]]; then
    echo "::error::Notarization of $(basename "$FILE") ended with status '$status'"
    [[ -n "$submission" ]] && xcrun notarytool log "$submission" "${credentials[@]}" || true
    exit 1
fi
echo "Notarized: $(basename "$FILE")"
