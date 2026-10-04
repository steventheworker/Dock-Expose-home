#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Usage: scripts/publish-release.sh VERSION ZIP [options]

Options:
  --create-release       Create/update the GitHub release and upload the ZIP.
  --dry-run              Print the appcast update without changing files.
  --sign-update PATH     Sparkle sign_update executable.
  --notes-url URL        Sparkle release-notes URL.
  --min-os VERSION       Appcast minimum system version (default: 26.0).
  --build-version VALUE  Override the archive's CFBundleVersion / sparkle:version.
  --repository OWNER/REPO GitHub repository for release assets.
  --generate-notes       Generate release notes from git log since the last v* tag.
  --tag                  Commit release metadata and create annotated vVERSION tag.
  --push-site             Commit release metadata and push the current branch.
                          With --tag, also push the release tag.
  --push-tag              Push vVERSION after creating it (implies --tag).

--push-site updates appcast.xml, currentversion.txt, the current release links,
the release history, and generated release notes when --generate-notes is used.
The Sparkle EdDSA private key is read by sign_update from its normal secure
storage. It must not be placed in this repository.
EOF
    exit 2
}

[ "$#" -ge 2 ] || usage
VERSION=$1
ZIP=$2
shift 2
CREATE_RELEASE=0
DRY_RUN=0
MIN_OS=26.0
BUILD_VERSION=
NOTES_URL="https://dockexpose.netlify.app/changelog-sparkle"
NOTES_URL_EXPLICIT=0
SIGN_UPDATE=${SPARKLE_SIGN_UPDATE:-}
REPOSITORY=${GITHUB_REPOSITORY:-steventheworker/Dock-Expose-home}
GENERATE_NOTES=0
TAG_RELEASE=0
PUSH_SITE=0
PUSH_TAG=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --create-release) CREATE_RELEASE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --sign-update) shift; [ "$#" -gt 0 ] || usage; SIGN_UPDATE=$1 ;;
        --notes-url) shift; [ "$#" -gt 0 ] || usage; NOTES_URL=$1; NOTES_URL_EXPLICIT=1 ;;
        --min-os) shift; [ "$#" -gt 0 ] || usage; MIN_OS=$1 ;;
        --build-version) shift; [ "$#" -gt 0 ] || usage; BUILD_VERSION=$1 ;;
        --repository) shift; [ "$#" -gt 0 ] || usage; REPOSITORY=$1 ;;
        --generate-notes) GENERATE_NOTES=1 ;;
        --tag) TAG_RELEASE=1 ;;
        --push-site) PUSH_SITE=1 ;;
        --push-tag) PUSH_TAG=1; TAG_RELEASE=1 ;;
        *) usage ;;
    esac
    shift
done

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APPCAST="$ROOT/appcast.xml"
CURRENT_VERSION="$ROOT/currentversion.txt"
CHANGELOG="$ROOT/changelog-sparkle/index.html"
EXPECTED_ZIP="Dock-Expose-$VERSION.zip"
TAG="v$VERSION"

[ -f "$ZIP" ] || { echo "error: ZIP does not exist: $ZIP" >&2; exit 1; }
case "$(basename -- "$ZIP")" in
    "$EXPECTED_ZIP") ;;
    *) echo "error: ZIP must be named $EXPECTED_ZIP" >&2; exit 1 ;;
esac

# Prevent an appcast/build-number mismatch: the archive's embedded metadata
# must agree with the values being published.
EXTRACT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dock-expose-release.XXXXXX")
trap 'rm -rf "$EXTRACT_DIR"' EXIT
ditto -x -k "$ZIP" "$EXTRACT_DIR"
INFO_PATH=$(find "$EXTRACT_DIR" -path '*/Contents/Info.plist' -not -path '*/Frameworks/*' -print -quit)
[ -n "$INFO_PATH" ] || { echo "error: ZIP contains no application Info.plist" >&2; exit 1; }
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PATH")
APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PATH")
if [ -z "$BUILD_VERSION" ]; then
    BUILD_VERSION=$APP_BUILD
fi
[ "$APP_VERSION" = "$VERSION" ] || {
    echo "error: archive version is $APP_VERSION, expected $VERSION" >&2
    exit 1
}
[ "$APP_BUILD" = "$BUILD_VERSION" ] || {
    echo "error: archive build is $APP_BUILD, expected $BUILD_VERSION" >&2
    exit 1
}

if [ -z "$SIGN_UPDATE" ]; then
    OLD_SIGN_UPDATE="$HOME/proj/obj-c/Dock-Expose-pre-macos27/Pods/Sparkle/bin/sign_update"
    if [ -x "$OLD_SIGN_UPDATE" ]; then
        SIGN_UPDATE=$OLD_SIGN_UPDATE
    fi
fi
[ -n "$SIGN_UPDATE" ] && [ -x "$SIGN_UPDATE" ] || {
    echo "error: set SPARKLE_SIGN_UPDATE or pass --sign-update PATH" >&2
    exit 1
}

SIGN_OUTPUT=$($SIGN_UPDATE "$ZIP")
SIGNATURE=$(printf '%s\n' "$SIGN_OUTPUT" | sed -nE "s/.*sparkle:edSignature=['\"]([^'\"]+)['\"].*/\1/p" | head -1)
LENGTH=$(stat -f '%z' "$ZIP")

[ -n "$SIGNATURE" ] || {
    echo "error: could not read the EdDSA signature from sign_update output:" >&2
    printf '%s\n' "$SIGN_OUTPUT" >&2
    exit 1
}

DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$TAG/$EXPECTED_ZIP"
PUB_DATE=$(date -R)

OLD_VERSION=$(tr -d '[:space:]' < "$CURRENT_VERSION" 2>/dev/null || true)
LAST_TAG=$(git -C "$ROOT" tag -l 'v*' --sort=-version:refname | head -1 || true)
if [ -n "$LAST_TAG" ]; then
    LOG_RANGE="$LAST_TAG..HEAD"
else
    LOG_RANGE="HEAD"
fi

NOTES_FILE=
if [ "$TAG_RELEASE" -eq 1 ]; then
    GENERATE_NOTES=1
fi

if [ "$GENERATE_NOTES" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    NOTES_FILE="$ROOT/changelog-sparkle/releases/$TAG/index.html"
    mkdir -p "$(dirname -- "$NOTES_FILE")"
    git -C "$ROOT" log --format='%h%x09%s' "$LOG_RANGE" > "$ROOT/.release-log.tmp"
    python3 - "$ROOT/.release-log.tmp" "$NOTES_FILE" "$VERSION" "$LAST_TAG" <<'PY'
import html
import pathlib
import sys

log_path, output_path, version, last_tag = sys.argv[1:]
entries = []
for line in pathlib.Path(log_path).read_text().splitlines():
    if not line.strip():
        continue
    commit, subject = line.split("\t", 1)
    entries.append(f"<li>{html.escape(subject)} <code>{html.escape(commit)}</code></li>")

if not entries:
    entries.append("<li>No commits were found after the previous release tag.</li>")

base = f" since <code>{html.escape(last_tag)}</code>" if last_tag else ""
content = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Dock Exposé VERSION release notes</title>
  <link rel="stylesheet" href="/docs/style.css">
</head>
<body>
  <main>
    <p class="back"><a href="/changelog-sparkle">← Changelog</a></p>
    <h1>Dock Exposé VERSION release notes</h1>
    <p>ChangesBASE:</p>
    <ul>
ENTRIES
    </ul>
  </main>
</body>
</html>
""".replace("VERSION", html.escape(version)).replace("BASE", base).replace(
    "ENTRIES", "\n".join("      " + entry for entry in entries)
)
pathlib.Path(output_path).write_text(content)
PY
    rm -f "$ROOT/.release-log.tmp"
    if [ "$NOTES_URL_EXPLICIT" -eq 0 ]; then
        NOTES_URL="https://dockexpose.netlify.app/changelog-sparkle/releases/$TAG/"
    fi
fi

ITEM=$(cat <<EOF
      <item>
         <title>Version $VERSION</title>
         <pubDate>$PUB_DATE</pubDate>
         <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
         <sparkle:releaseNotesLink>$NOTES_URL</sparkle:releaseNotesLink>
         <enclosure
            url="$DOWNLOAD_URL"
            sparkle:version="$BUILD_VERSION"
            sparkle:shortVersionString="$VERSION"
            sparkle:edSignature="$SIGNATURE" length="$LENGTH"
            type="application/octet-stream"/>
      </item>
EOF
)

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$ITEM"
    if [ "$TAG_RELEASE" -eq 1 ]; then
        echo "Would commit release metadata and create annotated tag $TAG."
    fi
    exit 0
fi

# Bump the website's current-release information when changing versions. The
# old release remains in the changelog; only the landing/current-release views
# are updated.
if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$VERSION" ]; then
    python3 - "$ROOT" "$OLD_VERSION" "$VERSION" "$REPOSITORY" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
old, new, repository = sys.argv[2:5]
for relative in ("index.html", "README.md", "docs/index.html", "docs/permissions/index.html"):
    path = root / relative
    text = path.read_text()
    text = text.replace(f"Dock Exposé {old}", f"Dock Exposé {new}")
    if relative == "index.html":
        old_url = f"https://github.com/{repository}/releases/download/v{old}/Dock-Expose-{old}.zip"
        new_url = f"https://github.com/{repository}/releases/download/v{new}/Dock-Expose-{new}.zip"
        text = text.replace(old_url, new_url, 2)
    path.write_text(text)
PY
fi

python3 - "$APPCAST" "$CURRENT_VERSION" "$VERSION" "$ITEM" <<'PY'
import pathlib
import sys

appcast_path, current_path, version, item = sys.argv[1:]
path = pathlib.Path(appcast_path)
text = path.read_text()
marker = "      <language>en</language>\n"
if marker not in text:
    raise SystemExit("error: appcast.xml has no channel language marker")

# Make rerunning the script idempotent for this release.
lines = text.splitlines(True)
filtered = []
in_item = False
item_lines = []
remove = False
for line in lines:
    if "<item>" in line:
        in_item = True
        item_lines = [line]
        remove = False
        continue
    if in_item:
        item_lines.append(line)
        if f'sparkle:shortVersionString="{version}"' in line:
            remove = True
        if "</item>" in line:
            if not remove:
                filtered.extend(item_lines)
            in_item = False
            item_lines = []
        continue
    filtered.append(line)

text = "".join(filtered)
text = text.replace(marker, marker + item + "\n", 1)
path.write_text(text)
pathlib.Path(current_path).write_text(version + "\n")
PY

# Add a generated release-history entry once. This keeps the landing page and
# the standalone changelog in sync without rewriting older release entries.
if [ "$GENERATE_NOTES" -eq 1 ] && [ -n "$NOTES_FILE" ]; then
    python3 - "$CHANGELOG" "$VERSION" "$TAG" "$NOTES_URL" "$LOG_RANGE" <<'PY'
import html
import pathlib
import subprocess
import sys

path, version, tag, notes_url, log_range = sys.argv[1:]
text = pathlib.Path(path).read_text()
marker = f"<span>{version} release</span>"
if marker not in text:
    entries = []
    for line in subprocess.check_output(
        ["git", "-C", str(pathlib.Path(path).parent.parent), "log", "--format=%h%x09%s", log_range],
        text=True,
    ).splitlines():
        if "\t" in line:
            commit, subject = line.split("\t", 1)
            entries.append(f"\t\t\t<li>{html.escape(subject)} <code>{html.escape(commit)}</code></li>")
    if not entries:
        entries = ["\t\t\t<li>See the release notes for details.</li>"]
    block = "\t<li>\n\t\t<ul>\n"
    block += f"\t\t\t<span>{html.escape(version)} release</span>\n"
    block += f'\t\t\t<h7><a href="{html.escape(notes_url)}">v{html.escape(version)}</a></h7>\n'
    block += "\n".join(entries) + "\n\t\t</ul>\n\t</li>\n"
    anchor = "\t<h4>Version Control / Changelog:</h4>\n"
    if anchor not in text:
        raise SystemExit("error: changelog has no version heading")
    text = text.replace(anchor, anchor + block, 1)
    pathlib.Path(path).write_text(text)
PY
fi

SITE_FILES="appcast.xml currentversion.txt index.html README.md changelog-sparkle/index.html docs/index.html docs/permissions/index.html"
if [ -n "$NOTES_FILE" ]; then
    SITE_FILES="$SITE_FILES ${NOTES_FILE#"$ROOT/"}"
fi

if [ "$TAG_RELEASE" -eq 1 ] || [ "$PUSH_SITE" -eq 1 ]; then
    # Only stage files generated by this release command; unrelated working
    # tree changes remain untouched.
    git -C "$ROOT" add $SITE_FILES
    if git -C "$ROOT" diff --cached --quiet; then
        RELEASE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
    else
        git -C "$ROOT" commit -m "publish Dock Exposé v$VERSION"
        RELEASE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
    fi
else
    RELEASE_COMMIT=
fi

if [ "$TAG_RELEASE" -eq 1 ]; then
    if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
        echo "error: tag already exists: $TAG" >&2
        exit 1
    fi
    git -C "$ROOT" tag -a "$TAG" "$RELEASE_COMMIT" -m "Dock Exposé $VERSION"
fi

if [ "$PUSH_SITE" -eq 1 ]; then
    git -C "$ROOT" push origin HEAD
    if [ "$TAG_RELEASE" -eq 1 ]; then
        git -C "$ROOT" push origin "$TAG"
    fi
fi
if [ "$PUSH_TAG" -eq 1 ] && [ "$PUSH_SITE" -eq 0 ]; then
    git -C "$ROOT" push origin "$TAG"
fi

if [ "$CREATE_RELEASE" -eq 1 ]; then
    command -v gh >/dev/null 2>&1 || { echo "error: gh is required for --create-release" >&2; exit 1; }
    if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
        gh release upload "$TAG" "$ZIP" --clobber --repo "$REPOSITORY"
    elif [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
        gh release create "$TAG" "$ZIP" --title "Dock Exposé $VERSION" --notes-file "$NOTES_FILE" --repo "$REPOSITORY"
    else
        gh release create "$TAG" "$ZIP" --title "Dock Exposé $VERSION" --generate-notes --repo "$REPOSITORY"
    fi
fi

echo "Updated $APPCAST for v$VERSION ($LENGTH bytes)."
if [ "$CREATE_RELEASE" -eq 0 ]; then
    echo "The GitHub asset was not uploaded; use --create-release before publishing the appcast."
fi
if [ "$TAG_RELEASE" -eq 1 ]; then
    echo "Created annotated tag $TAG at $RELEASE_COMMIT."
fi
