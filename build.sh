#!/bin/bash
# Builds and installs LocalDesktopHost (macOS) and LocalDesktopClient (iOS).
#
# Usage:
#   ./build.sh            Builds both macOS Host and iOS Client
#   ./build.sh --host     Builds macOS Host only
#   ./build.sh --client   Builds iOS Client only
#   ./build.sh --install  Builds and installs both (Host -> /Applications, Client -> connected iPhone)

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="Release"
BUILD_HOST=1
BUILD_CLIENT=1
INSTALL=0

for arg in "$@"; do
    case "$arg" in
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
        *)
            echo "Unknown argument: $arg"
            echo "Usage: ./build.sh [--host | --client | --all] [--install]"
            exit 1
            ;;
    esac
done

echo "==> Regenerating Xcode project with xcodegen..."
xcodegen generate

if [[ "$BUILD_HOST" -eq 1 ]]; then
    echo "==> Building LocalDesktopHost ($CONFIG)..."
    xcodebuild -project LocalDesktop.xcodeproj \
        -scheme LocalDesktopHost \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        build -quiet

    HOST_APP="/Users/serkan/Library/Developer/Xcode/DerivedData/LocalDesktop-cynfmgjrererwafylyqmyeiaonbm/Build/Products/$CONFIG/LocalDesktopHost.app"
    echo "==> Built Host: $HOST_APP"

    if [[ "$INSTALL" -eq 1 ]]; then
        echo "==> Installing LocalDesktopHost to /Applications..."
        pkill -f "LocalDesktopHost --supervisor" || true
        pkill -x LocalDesktopHost || true
        sleep 1
        rm -rf /Applications/LocalDesktopHost.app
        cp -R "$HOST_APP" /Applications/
        open /Applications/LocalDesktopHost.app
        echo "==> LocalDesktopHost installed and launched."
    fi
fi

if [[ "$BUILD_CLIENT" -eq 1 ]]; then
    echo "==> Finding connected iOS device..."
    DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | grep "physical" | awk '{print $3}' | head -n 1 || true)
    
    DESTINATION="generic/platform=iOS"
    if [[ -n "$DEVICE_ID" ]]; then
        DESTINATION="id=$DEVICE_ID"
        echo "==> Target physical device: $DEVICE_ID"
    else
        echo "==> No physical device found, targeting generic iOS..."
    fi

    echo "==> Building LocalDesktopClient ($CONFIG)..."
    xcodebuild -project LocalDesktop.xcodeproj \
        -scheme LocalDesktopClient \
        -configuration "$CONFIG" \
        -destination "$DESTINATION" \
        -allowProvisioningUpdates \
        build -quiet

    CLIENT_APP="/Users/serkan/Library/Developer/Xcode/DerivedData/LocalDesktop-cynfmgjrererwafylyqmyeiaonbm/Build/Products/$CONFIG-iphoneos/LocalDesktopClient.app"
    echo "==> Built Client: $CLIENT_APP"

    if [[ "$INSTALL" -eq 1 && -n "$DEVICE_ID" ]]; then
        echo "==> Installing LocalDesktopClient to device $DEVICE_ID..."
        xcrun devicectl device install app --device "$DEVICE_ID" "$CLIENT_APP"
        xcrun devicectl device process launch --device "$DEVICE_ID" localdesktop.client || true
        echo "==> LocalDesktopClient installed and launched on iPhone."
    fi
fi

echo "==> Done!"
