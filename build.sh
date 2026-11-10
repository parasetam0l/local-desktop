#!/bin/bash
# Builds and installs LocalDesktop (macOS) and LocalDesktopClient (iOS).
#
# Usage:
#   ./build.sh                 Builds both macOS Host and iOS Client
#   ./build.sh --host          Builds macOS Host only
#   ./build.sh --client        Builds iOS Client only
#   ./build.sh --install       Builds and installs (Host -> /Applications, Client -> cabled iPhone/iPad;
#                              DEVICE=<UDID> picks another)
#   ./build.sh --test          Runs the protocol unit tests and exits
#   ./build.sh --team ABCDE12345
#                              Signs the iOS app with this Apple Developer Team ID instead of the
#                              one in project.yml (the DEVELOPMENT_TEAM environment variable works
#                              too). The Mac app is pinned to a Developer ID certificate in project.yml.

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="Release"
BUILD_HOST=1
BUILD_CLIENT=1
INSTALL=0
RUN_TESTS=0
TEAM="${DEVELOPMENT_TEAM:-}"
# Build products go inside the repo (ignored by git) so their paths are predictable.
DERIVED_DATA="build"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            BUILD_HOST=1
            BUILD_CLIENT=0
            ;;
        --client)
            BUILD_HOST=0
            BUILD_CLIENT=1
            ;;
        --all)
            BUILD_HOST=1
            BUILD_CLIENT=1
            ;;
        --install)
            INSTALL=1
            ;;
        --test)
            RUN_TESTS=1
            ;;
        --team)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "--team needs a Team ID"
                exit 1
            fi
            TEAM="$2"
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: ./build.sh [--host | --client | --all] [--install] [--test] [--team TEAM_ID]"
            exit 1
            ;;
    esac
    shift
done

SIGNING_ARGS=()
if [[ -n "$TEAM" ]]; then
    SIGNING_ARGS=("DEVELOPMENT_TEAM=$TEAM")
    echo "==> Signing the iOS app with team $TEAM"
fi

echo "==> Regenerating Xcode project with xcodegen..."
xcodegen generate

if [[ "$RUN_TESTS" -eq 1 ]]; then
    echo "==> Running unit tests..."
    xcodebuild -project LocalDesktop.xcodeproj \
        -scheme LocalDesktopTests \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        test -quiet
    echo "==> Tests passed."
    exit 0
fi

if [[ "$BUILD_HOST" -eq 1 ]]; then
    echo "==> Building LocalDesktop for Mac ($CONFIG)..."
    xcodebuild -project LocalDesktop.xcodeproj \
        -scheme LocalDesktopHost \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        build -quiet

    HOST_APP="$DERIVED_DATA/Build/Products/$CONFIG/LocalDesktop.app"
    echo "==> Built Host: $HOST_APP"

    if [[ "$INSTALL" -eq 1 ]]; then
        echo "==> Installing LocalDesktop to /Applications..."
        # Stop the supervisor first so it doesn't relaunch the old copy; the app itself
        # treats SIGTERM as a clean quit.
        # Before 1.1.1 the app was LocalDesktopHost.app: replace either.
        pkill -f "MacOS/LocalDesktop(Host)? --supervisor" || true
        pkill -x LocalDesktop || true
        pkill -x LocalDesktopHost || true
        sleep 1
        rm -rf /Applications/LocalDesktopHost.app /Applications/LocalDesktop.app
        cp -R "$HOST_APP" /Applications/
        open /Applications/LocalDesktop.app
        echo "==> LocalDesktop installed and launched."
    fi
fi

if [[ "$BUILD_CLIENT" -eq 1 ]]; then
    echo "==> Finding connected iOS device..."
    # DEVICE=<UDID> picks the device. Otherwise take a physical device connected by cable,
    # then any physical one (a paired iPhone on Wi-Fi only if nothing is plugged in).
    DEVICE_ID="${DEVICE:-}"
    if [[ -z "$DEVICE_ID" ]]; then
        DEVICES_JSON=$(mktemp)
        xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
        DEVICE_ID=$(python3 -I - "$DEVICES_JSON" <<'PY' || true
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
physical = [d for d in devices if d.get("hardwareProperties", {}).get("reality") == "physical"]
physical.sort(key=lambda d: d.get("connectionProperties", {}).get("transportType") != "wired")
if physical:
    print(physical[0]["hardwareProperties"]["udid"])
PY
)
        rm -f "$DEVICES_JSON"
    fi

    DESTINATION="generic/platform=iOS"
    PROVISIONING_ARGS=(-allowProvisioningUpdates)
    if [[ -n "$DEVICE_ID" ]]; then
        DESTINATION="id=$DEVICE_ID"
        # Lets Xcode add a not-yet-registered iPhone to the team's development profile.
        PROVISIONING_ARGS+=(-allowProvisioningDeviceRegistration)
        echo "==> Target physical device: $DEVICE_ID"
    else
        echo "==> No physical device found, targeting generic iOS..."
    fi

    echo "==> Building LocalDesktopClient ($CONFIG)..."
    xcodebuild -project LocalDesktop.xcodeproj \
        -scheme LocalDesktopClient \
        -configuration "$CONFIG" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        "${PROVISIONING_ARGS[@]}" \
        ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"} \
        build -quiet

    CLIENT_APP="$DERIVED_DATA/Build/Products/$CONFIG-iphoneos/LocalDesktopClient.app"
    echo "==> Built Client: $CLIENT_APP"

    if [[ "$INSTALL" -eq 1 && -n "$DEVICE_ID" ]]; then
        echo "==> Installing LocalDesktopClient to device $DEVICE_ID..."
        xcrun devicectl device install app --device "$DEVICE_ID" "$CLIENT_APP"
        xcrun devicectl device process launch --device "$DEVICE_ID" localdesktop.client || true
        echo "==> LocalDesktopClient installed on the device."
    fi
fi

echo "==> Done!"
