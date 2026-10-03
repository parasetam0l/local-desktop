#!/bin/zsh
#
# Signs the helpers inside the embedded Sparkle.framework with the app's
# identity. Sparkle ships them ad-hoc signed; notarization needs every
# executable signed with Developer ID, the hardened runtime and a secure
# timestamp (OTHER_CODE_SIGN_FLAGS in Release). Runs as a build phase after
# the framework is embedded and before Xcode signs the app. Inner code
# first, the framework last.

set -euo pipefail

[[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]] || exit 0

framework="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
if [[ ! -d "$framework" ]]; then
    echo "error: Sparkle.framework is not embedded in $FRAMEWORKS_FOLDER_PATH" >&2
    exit 1
fi

sign() {
    codesign --force --options runtime ${=OTHER_CODE_SIGN_FLAGS:-} --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$@"
}

helpers="$framework/Versions/B"
sign "$helpers/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$helpers/XPCServices/Downloader.xpc"
sign "$helpers/Autoupdate"
sign "$helpers/Updater.app"
sign "$framework"
