#!/bin/sh
# Canonical *-home release wrapper: build the app, then publish it.
#
# Product-specific values live in ./release.config.sh. Everything else is the
# same in every repo, so the pipeline can be updated everywhere at once.
set -eu
set -o pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WEBSITE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
[ -f "$WEBSITE_ROOT/release.config.sh" ] || { echo "error: missing $WEBSITE_ROOT/release.config.sh" >&2; exit 1; }
# shellcheck source=/dev/null
. "$WEBSITE_ROOT/release.config.sh"

: "${PRODUCT_NAME:?release.config.sh must set PRODUCT_NAME}"
SOURCE_ROOT=${SOURCE_ROOT:-"$HOME/proj/obj-c/$PRODUCT_NAME"}
MAKE_RELEASE=${SOURCE_RELEASE_SCRIPT:-"$SOURCE_ROOT/scripts/make-release.sh"}
PUBLISH_RELEASE="$WEBSITE_ROOT/scripts/publish-release.sh"
MODE=${1:-patch}
[ "$#" -gt 0 ] && shift

[ -x "$MAKE_RELEASE" ] || { echo "error: make-release.sh is not executable: $MAKE_RELEASE" >&2; exit 1; }
[ -x "$PUBLISH_RELEASE" ] || { echo "error: publish-release.sh is not executable: $PUBLISH_RELEASE" >&2; exit 1; }
[ -n "${RELEASE_ZIP_NAME:-}" ] || { echo "error: release.config.sh must set RELEASE_ZIP_NAME" >&2; exit 1; }

# Build the versioned ZIP (bumps MARKETING_VERSION/CURRENT_PROJECT_VERSION).
"$MAKE_RELEASE" "$MODE"

if [ "${XCODE_KIND:-project}" = "workspace" ]; then
    XCODE_ARGS="-workspace $SOURCE_ROOT/${XCODE_WORKSPACE:?set XCODE_WORKSPACE}"
else
    XCODE_ARGS="-project $SOURCE_ROOT/${XCODE_PROJECT:?set XCODE_PROJECT}"
fi
BUILD_SETTINGS=$(xcodebuild $XCODE_ARGS \
    -scheme "${XCODE_SCHEME:?set XCODE_SCHEME}" \
    -configuration "${XCODE_CONFIGURATION:-Release}" \
    -showBuildSettings 2>/dev/null)
VERSION=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]+MARKETING_VERSION = / { print $2; exit }')
BUILD_VERSION=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]+CURRENT_PROJECT_VERSION = / { print $2; exit }')
ZIP="$HOME/Downloads/$(printf '%s' "$RELEASE_ZIP_NAME" | sed "s/{VERSION}/$VERSION/g")"

[ -n "$VERSION" ] || { echo "error: could not read MARKETING_VERSION from Xcode" >&2; exit 1; }

# Commit the release metadata the build just bumped, leaving other changes be.
if [ -n "${SOURCE_METADATA_FILE:-}" ] && ! git -C "$SOURCE_ROOT" diff --quiet -- "$SOURCE_METADATA_FILE"; then
    git -C "$SOURCE_ROOT" add -- "$SOURCE_METADATA_FILE"
    META_MSG=${SOURCE_METADATA_COMMIT_MSG:-}
    [ -n "$META_MSG" ] || META_MSG="chore(release): prepare $PRODUCT_NAME v{VERSION}"
    git -C "$SOURCE_ROOT" commit -m "$(printf '%s' "$META_MSG" | sed "s/{VERSION}/$VERSION/g")"
fi

[ -f "$ZIP" ] || { echo "error: expected release ZIP was not created: $ZIP" >&2; exit 1; }

printf '\nDeploying %s %s (build %s)\nZIP: %s\n\n' "$PRODUCT_NAME" "$VERSION" "$BUILD_VERSION" "$ZIP"

cd "$WEBSITE_ROOT"
exec "$PUBLISH_RELEASE" "$VERSION" "$ZIP" \
    --build-version "$BUILD_VERSION" \
    --generate-notes \
    --tag \
    --push-site \
    --create-release \
    "$@"
