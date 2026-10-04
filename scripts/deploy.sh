#!/bin/sh
set -eu
set -o pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WEBSITE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE_ROOT=${DOCK_EXPOSE_SOURCE_ROOT:-"$HOME/proj/obj-c/Dock-Expose"}
MAKE_RELEASE="$SOURCE_ROOT/scripts/make-release.sh"
PUBLISH_RELEASE="$WEBSITE_ROOT/scripts/publish-release.sh"
MODE=${1:-patch}

if [ "$#" -gt 0 ]; then
    shift
fi

[ -x "$MAKE_RELEASE" ] || {
    echo "error: make-release.sh is not executable: $MAKE_RELEASE" >&2
    exit 1
}
[ -x "$PUBLISH_RELEASE" ] || {
    echo "error: publish-release.sh is not executable: $PUBLISH_RELEASE" >&2
    exit 1
}

# This updates the Xcode project, archives the Release app, runs the archive
# post-action that renames it to Dock Exposé, and writes the ZIP to Downloads.
"$MAKE_RELEASE" "$MODE"

BUILD_SETTINGS=$(xcodebuild \
    -project "$SOURCE_ROOT/Dock Expose.xcodeproj" \
    -scheme "Dock Expose" \
    -configuration Release \
    -showBuildSettings 2>/dev/null)
VERSION=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]+MARKETING_VERSION = / { print $2; exit }')
BUILD_VERSION=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]+CURRENT_PROJECT_VERSION = / { print $2; exit }')
ZIP="$HOME/Downloads/Dock-Expose-$VERSION.zip"

# make-release.sh updates the Xcode version/build settings. Commit that
# release metadata before publish-release tags the source repository, while
# leaving unrelated source changes untouched.
SOURCE_PROJECT_FILE="$SOURCE_ROOT/Dock Expose.xcodeproj/project.pbxproj"
if ! git -C "$SOURCE_ROOT" diff --quiet -- "$SOURCE_PROJECT_FILE"; then
    git -C "$SOURCE_ROOT" add -- "$SOURCE_PROJECT_FILE"
    git -C "$SOURCE_ROOT" commit -m "prepare Dock Exposé v$VERSION"
fi

[ -f "$ZIP" ] || {
    echo "error: expected release ZIP was not created: $ZIP" >&2
    exit 1
}

printf '\nDeploying Dock Exposé %s (build %s)\n' "$VERSION" "$BUILD_VERSION"
printf 'ZIP: %s\n\n' "$ZIP"

# publish-release validates the embedded archive metadata itself. Passing the
# values here keeps the command explicit while avoiding release-specific
# filenames and build numbers in this wrapper.
cd "$WEBSITE_ROOT"
exec "$PUBLISH_RELEASE" \
    "$VERSION" \
    "$ZIP" \
    --build-version "$BUILD_VERSION" \
    --generate-notes \
    --tag \
    --push-site \
    --create-release \
    "$@"
