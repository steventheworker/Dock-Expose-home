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
  --source-root PATH     Closed-source app repository used for tags and logs.
  --generate-notes       Generate release notes from source git history.
  --tag                  Commit site metadata and create an annotated source vVERSION tag.
  --push-site             Commit release metadata and push the website branch.
                          With --tag, also push the source release tag.
  --push-tag              Push the source vVERSION tag (implies --tag).

The source repository is ~/proj/obj-c/Dock-Expose by default. Website release
notes never expose a source-repository comparison link. If a local llama-server
is healthy, pi is asked to turn the source commit list into user-facing bullets;
otherwise the raw source commit list is used.
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
SOURCE_ROOT=${DOCK_EXPOSE_SOURCE_ROOT:-"$HOME/proj/obj-c/Dock-Expose"}
LLAMA_HEALTH_URL=${LLAMA_HEALTH_URL:-http://127.0.0.1:8001/health}
RELEASE_NOTES_MODEL=${RELEASE_NOTES_MODEL:-llamacpp_m4/Ling-3.0-tiny}
RELEASE_NOTES_TIMEOUT=${RELEASE_NOTES_TIMEOUT:-120}
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
        --source-root) shift; [ "$#" -gt 0 ] || usage; SOURCE_ROOT=$1 ;;
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
LANDING="$ROOT/index.html"
EXPECTED_ZIP="Dock-Expose-$VERSION.zip"
TAG="v$VERSION"

[ -d "$SOURCE_ROOT/.git" ] || {
    echo "error: source repository not found: $SOURCE_ROOT" >&2
    exit 1
}
[ -f "$ZIP" ] || { echo "error: ZIP does not exist: $ZIP" >&2; exit 1; }
case "$(basename -- "$ZIP")" in
    "$EXPECTED_ZIP") ;;
    *) echo "error: ZIP must be named $EXPECTED_ZIP" >&2; exit 1 ;;
esac

SOURCE_TAG=$(git -C "$SOURCE_ROOT" tag -l 'v*' --sort=-version:refname | head -1 || true)
if [ -n "$SOURCE_TAG" ]; then
    LOG_RANGE="$SOURCE_TAG..HEAD"
else
    LOG_RANGE="HEAD"
fi
SOURCE_COMMIT=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
if [ "$TAG_RELEASE" -eq 1 ] && git -C "$SOURCE_ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: source tag already exists: $SOURCE_ROOT $TAG" >&2
    exit 1
fi

# Prevent an appcast/build-number mismatch: the archive's embedded metadata
# must agree with the values being published.
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dock-expose-release.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
EXTRACT_DIR="$TMP_DIR/archive"
mkdir -p "$EXTRACT_DIR"
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
    # Prefer the old checkout when it is available, but also support the
    # current SPM integration. Xcode places Sparkle's signing tool inside the
    # project's DerivedData SourcePackages artifacts directory.
    for OLD_SIGN_UPDATE in \
        "$HOME/proj/obj-c/Dock-Expose-pre-macos27/Pods/Sparkle/bin/sign_update" \
        "$HOME/proj/obj-c/_archives/Dock-Expose-pre-macos27/Pods/Sparkle/bin/sign_update"; do
        if [ -x "$OLD_SIGN_UPDATE" ]; then
            SIGN_UPDATE=$OLD_SIGN_UPDATE
            break
        fi
    done
fi
if [ -z "$SIGN_UPDATE" ]; then
    SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -type f \
        -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' \
        -print -quit 2>/dev/null || true)
fi
[ -n "$SIGN_UPDATE" ] && [ -x "$SIGN_UPDATE" ] || {
    echo "error: Sparkle sign_update was not found." >&2
    echo "       Set SPARKLE_SIGN_UPDATE or pass --sign-update PATH." >&2
    echo "       Expected an SPM artifact under ~/Library/Developer/Xcode/DerivedData." >&2
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

NOTES_FILE=
BULLETS_FILE=
if [ "$TAG_RELEASE" -eq 1 ]; then
    GENERATE_NOTES=1
fi

if [ "$GENERATE_NOTES" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    NOTES_FILE="$ROOT/changelog-sparkle/releases/$TAG/index.html"
    BULLETS_FILE="$TMP_DIR/release-bullets.txt"
    RAW_LOG="$TMP_DIR/source-log.tsv"
    PROMPT_FILE="$TMP_DIR/release-notes-prompt.txt"
    MODEL_OUTPUT="$TMP_DIR/model-output.txt"

    git -C "$SOURCE_ROOT" log --format='%h%x09%s' "$LOG_RANGE" > "$RAW_LOG"

    python3 - "$RAW_LOG" "$PROMPT_FILE" "$VERSION" "$SOURCE_TAG" <<'PY'
import pathlib
import sys

raw_path, prompt_path, version, last_tag = sys.argv[1:]
raw = pathlib.Path(raw_path).read_text().strip()
project = """Dock Exposé is a closed-source macOS menu-bar utility that provides Dock/App Exposé window previews and window-management controls. It includes close/minimize controls, window-title labels, a custom bottom bar and Recents Editor, fn+R access, permission onboarding, and Sparkle updates. It is officially for Apple-silicon Macs running macOS 26 and 27."""
context = f" since {last_tag}" if last_tag else ""
prompt = f"""/skill:writing-great-skills

Write concise, user-facing release notes for Dock Exposé {version}.

Project context: {project}

Use the source commit subjects below as evidence. Do not browse the project or invent details. Group related changes when useful. Prefer 4-12 concrete bullets, each a short sentence beginning with an action or user benefit. Ignore changes clearly unrelated to the macOS app or release tooling, including deployment and version-bump commits. Do not mention commits, hashes, GitHub, source code, a full changelog, internal implementation details, Linux, or tabs. Return only one plain-text bullet per line with no heading, preamble, code fence, or numbering. These bullets will be shown directly on the public website.

The changes are{context}:
{raw}
"""
pathlib.Path(prompt_path).write_text(prompt)
PY

    if curl --fail --silent --show-error --max-time 3 "$LLAMA_HEALTH_URL" >/dev/null 2>&1 && command -v pi >/dev/null 2>&1; then
        if python3 - "$PROMPT_FILE" "$MODEL_OUTPUT" "$RELEASE_NOTES_MODEL" "$RELEASE_NOTES_TIMEOUT" <<'PY'
import pathlib
import subprocess
import sys

prompt_path, output_path, model, timeout = sys.argv[1:]
try:
    result = subprocess.run(
        ["pi", "-p", "--model", model, pathlib.Path(prompt_path).read_text()],
        capture_output=True,
        text=True,
        timeout=int(timeout),
        check=True,
    )
except Exception as exc:
    print(f"release-notes agent unavailable: {exc}", file=sys.stderr)
    raise SystemExit(1)
pathlib.Path(output_path).write_text(result.stdout)
PY
        then
            if python3 - "$MODEL_OUTPUT" "$BULLETS_FILE" <<'PY'
import pathlib
import re
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
seen = set()
bullets = []
for raw in source.read_text().splitlines():
    line = raw.strip().strip('`')
    line = re.sub(r"^(?:[-*•]|\d+[.)])\s+", "", line).strip()
    if not line or line.lower().rstrip(":") in {"release notes", "release notes:", "here are the release notes"}:
        continue
    lower = line.lower()
    if lower.startswith(("here are ", "changes since ", "changes:")):
        continue
    if (lower.endswith("release notes") or lower == "deploy"
        or "prepare dock exposé v" in lower or "version bump" in lower
        or "linux" in lower or "picohook" in lower
        or "ax notification" in lower or re.search(r"\btabs?\b", lower)):
        continue
    if line not in seen and len(line) <= 300:
        seen.add(line)
        bullets.append(line)
if not 2 <= len(bullets) <= 20:
    raise SystemExit("model returned an unusable release-note list")
destination.write_text("\n".join(bullets) + "\n")
PY
            then
                echo "Using pi-generated release notes from source history."
            else
                rm -f "$BULLETS_FILE"
                echo "warning: pi returned an unusable release-note list; using raw source commits." >&2
            fi
        else
            echo "warning: pi release-note generation failed; using raw source commits." >&2
        fi
    else
        echo "Using raw source commits for release notes (llama-server or pi unavailable)."
    fi

    if [ ! -s "$BULLETS_FILE" ]; then
        python3 - "$RAW_LOG" "$BULLETS_FILE" <<'PY'
import pathlib
import re
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
bullets = []
for line in source.read_text().splitlines():
    if "\t" in line:
        commit, subject = line.split("\t", 1)
        lower = subject.lower()
        if (lower == "deploy" or "prepare dock exposé v" in lower
                or "version bump" in lower or "linux" in lower
                or "picohook" in lower or "ax notification" in lower
                or re.search(r"\btabs?\b", lower)):
            continue
        bullets.append(f"{subject} [{commit}]")
destination.write_text("\n".join(bullets) + ("\n" if bullets else ""))
PY
    fi

    mkdir -p "$(dirname -- "$NOTES_FILE")"
    python3 - "$BULLETS_FILE" "$NOTES_FILE" "$VERSION" "$SOURCE_TAG" <<'PY'
import html
import pathlib
import sys

bullets_path, output_path, version, last_tag = sys.argv[1:]
bullets = [line.strip() for line in pathlib.Path(bullets_path).read_text().splitlines() if line.strip()]
items = "\n".join(f"      <li>{html.escape(line)}</li>" for line in bullets)
base = f" since <code>{html.escape(last_tag)}</code>" if last_tag else ""
content = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Dock Exposé {html.escape(version)} release notes</title>
  <link rel="stylesheet" href="/docs/style.css">
</head>
<body>
  <main>
    <p class="back"><a href="/changelog-sparkle">← Changelog</a></p>
    <h1>Dock Exposé {html.escape(version)} release notes</h1>
    <p>Changes{base}:</p>
    <ul>
{items}
    </ul>
  </main>
</body>
</html>
"""
pathlib.Path(output_path).write_text(content)
PY
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
        echo "Would commit release metadata and create source tag $TAG at $SOURCE_COMMIT."
    fi
    exit 0
fi

# Bump the website's current-release information when changing versions.
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

# Use one bullet source for the standalone notes page, changelog, and landing
# page. Existing entries for this release are replaced, not duplicated.
if [ "$GENERATE_NOTES" -eq 1 ] && [ -n "$BULLETS_FILE" ]; then
    python3 - "$BULLETS_FILE" "$CHANGELOG" "$LANDING" "$VERSION" "$NOTES_URL" <<'PY'
import html
import pathlib
import re
import sys

bullets_path, changelog_path, landing_path, version, notes_url = sys.argv[1:]
bullets = [line.strip() for line in pathlib.Path(bullets_path).read_text().splitlines() if line.strip()]

def block(indent):
    child = "\t" if indent == "\t" else "  "
    lines = [
        f"{indent}<li>",
        f"{indent}{child}<ul>",
        f"{indent}{child}{child}<span>{html.escape(version)} release</span>",
        f'{indent}{child}{child}<h7><a href="{html.escape(notes_url)}">v{html.escape(version)}</a></h7>',
    ]
    lines.extend(f"{indent}{child}{child}<li>{html.escape(bullet, quote=False)}</li>" for bullet in bullets)
    lines.extend([f"{indent}{child}</ul>", f"{indent}</li>"])
    return "\n".join(lines)

def update(path, heading, indent):
    text = pathlib.Path(path).read_text()
    marker = f"<span>{version} release</span>"
    replacement = block(indent)
    if marker in text:
        pattern = re.compile(
            r"(?ms)^[ \t]*<li>\s*<ul>\s*<span>"
            + re.escape(f"{version} release")
            + r"</span>.*?^[ \t]*</ul>\s*</li>"
        )
        text, count = pattern.subn(replacement, text, count=1)
        if count != 1:
            raise SystemExit(f"could not replace existing {version} entry in {path}")
    else:
        anchor = heading
        if anchor not in text:
            raise SystemExit(f"changelog heading not found in {path}")
        text = text.replace(anchor, anchor + "\n" + replacement, 1)
    pathlib.Path(path).write_text(text)

update(changelog_path, "\t<h4>Version Control / Changelog:</h4>", "\t")
update(landing_path, "        <h4>Version Control / Changelog:</h4>", "          ")
PY
fi

SITE_FILES="appcast.xml currentversion.txt index.html README.md changelog-sparkle/index.html docs/index.html docs/permissions/index.html scripts/publish-release.sh scripts/deploy.sh"
if [ -n "$NOTES_FILE" ]; then
    SITE_FILES="$SITE_FILES ${NOTES_FILE#"$ROOT/"}"
fi

RELEASE_COMMIT=
if [ "$TAG_RELEASE" -eq 1 ] || [ "$PUSH_SITE" -eq 1 ]; then
    git -C "$ROOT" add $SITE_FILES
    if git -C "$ROOT" diff --cached --quiet; then
        RELEASE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
    else
        git -C "$ROOT" commit -m "publish Dock Exposé v$VERSION"
        RELEASE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
    fi
fi

if [ "$TAG_RELEASE" -eq 1 ]; then
    git -C "$SOURCE_ROOT" tag -a "$TAG" "$SOURCE_COMMIT" -m "Dock Exposé $VERSION"
fi

if [ "$PUSH_SITE" -eq 1 ]; then
    git -C "$ROOT" push origin HEAD
    if [ "$TAG_RELEASE" -eq 1 ]; then
        git -C "$SOURCE_ROOT" push origin "$TAG"
    fi
fi
if [ "$PUSH_TAG" -eq 1 ] && [ "$PUSH_SITE" -eq 0 ]; then
    git -C "$SOURCE_ROOT" push origin "$TAG"
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
    echo "Created source tag $TAG at $SOURCE_ROOT@$SOURCE_COMMIT."
fi
