#!/bin/sh
# Product-specific configuration for the Dock Exposé *-home release pipeline.
# Consumed by scripts/deploy.sh and scripts/publish-release.sh (canonical).

# --- product identity ---------------------------------------------------------
PRODUCT_NAME="Dock Exposé"
# Closed source: releases/tags live on this -home repo.
IS_OPEN_SOURCE="0"
SOURCE_REPOSITORY=""
RELEASE_REPOSITORY="steventheworker/Dock-Expose-home"
SITE_URL="https://dockexpose.netlify.app"

# --- source app ---------------------------------------------------------------
SOURCE_ROOT="${DOCK_EXPOSE_SOURCE_ROOT:-$HOME/proj/obj-c/Dock-Expose}"
XCODE_KIND="project"
XCODE_PROJECT="Dock Expose.xcodeproj"
XCODE_WORKSPACE=""
XCODE_SCHEME="Dock Expose"
XCODE_CONFIGURATION="Release"
RELEASE_ZIP_NAME="Dock-Expose-{VERSION}.zip"
SOURCE_METADATA_FILE="Dock Expose.xcodeproj/project.pbxproj"
SOURCE_METADATA_COMMIT_MSG="prepare Dock Exposé v{VERSION}"

# --- Sparkle appcast ----------------------------------------------------------
APPCAST="appcast.xml"
MIN_OS="26.0"
NOTES_URL_BASE="$SITE_URL"
CURRENT_VERSION_CMD="tr -d '[:space:]' < currentversion.txt"
SIGN_UPDATE_CANDIDATES="$HOME/proj/obj-c/Dock-Expose-pre-macos27/Pods/Sparkle/bin/sign_update $HOME/proj/obj-c/_archives/Dock-Expose-pre-macos27/Pods/Sparkle/bin/sign_update"
RELEASE_NOTES_CONTEXT="Dock Exposé is a closed-source macOS menu-bar utility that provides Dock/App Exposé window previews and window-management controls. It includes close/minimize controls, window-title labels, a custom bottom bar and Recents Editor, fn+R access, permission onboarding, and Sparkle updates. It is officially for Apple-silicon Macs running macOS 26 and 27."
RELEASE_NOTES_EXCLUDE="\\bdeploy\\b|prepare dock expos|\\bversion bump\\b|\\blinux\\b|\\bpicohook\\b|\\bax notification\\b|\\btabs?\\b"
RELEASE_TITLE="Dock Exposé {VERSION}"
SITE_COMMIT_MSG="publish Dock Exposé v{VERSION}"

# Files the canonical publisher stages (the appcast is added automatically).
SITE_FILES="index.html README.md docs/index.html docs/permissions/index.html changelog-sparkle/index.html"
