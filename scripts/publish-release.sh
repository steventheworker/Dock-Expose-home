#!/bin/sh
# Canonical *-home release publisher.
#
# Product-specific values come from ./release.config.sh at the repo root; the
# website edits (HTML/README/version files) are delegated to
# ./scripts/update-site.sh so this file stays identical in every repo.
#
# Usage: scripts/publish-release.sh VERSION ZIP [options]  (see usage()).
set -eu

usage() {
    cat <<'EOF'
Usage: scripts/publish-release.sh VERSION ZIP [options]

Options:
  --create-release       Create/update the GitHub release and upload the ZIP.
  --dry-run              Print the appcast update without changing files.
  --sign-update PATH     Sparkle sign_update executable.
  --notes-url URL        Sparkle release-notes URL.
  --min-os VERSION       Appcast minimum system version (config default).
  --build-version VALUE  Override the archive's CFBundleVersion / sparkle:version.
  --repository OWNER/REPO GitHub repository for release assets/tags.
  --source-root PATH     Source repository used for tags and logs.
  --generate-notes       Generate release notes from source history.
  --tag                  Commit site metadata and create a source vVERSION tag.
  --push-site            Commit release metadata and push the website branch.
  --push-tag             Push the source vVERSION tag (implies --tag).

Values are read from ./release.config.sh (PRODUCT_NAME, APPCAST, MIN_OS,
RELEASE_ZIP_NAME, SITE_FILES, ...). `scripts/update-site.sh`, if present, is
called to edit the website after the appcast is updated.
EOF
    exit 2
}

[ "$#" -ge 2 ] || usage
VERSION=$1
ZIP=$2
shift 2

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$ROOT/release.config.sh" ] || { echo "error: missing $ROOT/release.config.sh" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/release.config.sh"

: "${PRODUCT_NAME:?release.config.sh must set PRODUCT_NAME}"
: "${APPCAST:?release.config.sh must set APPCAST}"
: "${RELEASE_ZIP_NAME:?release.config.sh must set RELEASE_ZIP_NAME}"
: "${RELEASE_NOTES_CONTEXT:?release.config.sh must set RELEASE_NOTES_CONTEXT}"
REPOSITORY=${GITHUB_REPOSITORY:-${RELEASE_REPOSITORY:-steventheworker/$PRODUCT_NAME}}
SOURCE_ROOT=${SOURCE_ROOT:-"$HOME/proj/obj-c/$PRODUCT_NAME"}
MIN_OS=${MIN_OS:-12.0}
NOTES_URL_BASE=${NOTES_URL_BASE:-""}
SITE_FILES=${SITE_FILES:-}
CURRENT_VERSION_CMD=${CURRENT_VERSION_CMD:-}
SIGN_UPDATE_CANDIDATES=${SIGN_UPDATE_CANDIDATES:-}
RELEASE_NOTES_EXCLUDE=${RELEASE_NOTES_EXCLUDE:-}

CREATE_RELEASE=0
DRY_RUN=0
BUILD_VERSION=
NOTES_URL=""
NOTES_URL_EXPLICIT=0
SIGN_UPDATE=${SPARKLE_SIGN_UPDATE:-}
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

APPCAST_PATH="$ROOT/$APPCAST"
EXPECTED_ZIP=$(printf '%s' "$RELEASE_ZIP_NAME" | sed "s/{VERSION}/$VERSION/g")
TAG="v$VERSION"
NOTES_FILE="$ROOT/changelog-sparkle/releases/$TAG/index.html"
NOTES_MD="$ROOT/changelog-sparkle/releases/$TAG/notes.md"
if [ -z "$NOTES_URL" ] && [ -n "$NOTES_URL_BASE" ]; then
    NOTES_URL="$NOTES_URL_BASE/changelog-sparkle/releases/$TAG/"
fi

[ -d "$SOURCE_ROOT/.git" ] || { echo "error: source repository not found: $SOURCE_ROOT" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "error: ZIP does not exist: $ZIP" >&2; exit 1; }
[ "$(basename -- "$ZIP")" = "$EXPECTED_ZIP" ] || { echo "error: ZIP must be named $EXPECTED_ZIP" >&2; exit 1; }

SOURCE_TAG=$(git -C "$SOURCE_ROOT" tag -l 'v*' --sort=-version:refname | head -1 || true)
LOG_RANGE="HEAD"
[ -n "$SOURCE_TAG" ] && LOG_RANGE="$SOURCE_TAG..HEAD"
SOURCE_COMMIT=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
if [ "$TAG_RELEASE" -eq 1 ] && git -C "$SOURCE_ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: source tag already exists: $SOURCE_ROOT $TAG" >&2
    exit 1
fi

# The archive's embedded metadata must agree with what is being published.
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/home-release.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
EXTRACT_DIR="$TMP_DIR/archive"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ZIP" "$EXTRACT_DIR"
INFO_PATH=$(find "$EXTRACT_DIR" -path '*/Contents/Info.plist' -not -path '*/Frameworks/*' -print -quit)
[ -n "$INFO_PATH" ] || { echo "error: ZIP contains no application Info.plist" >&2; exit 1; }
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PATH")
APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PATH")
[ -n "$BUILD_VERSION" ] || BUILD_VERSION=$APP_BUILD
[ "$APP_VERSION" = "$VERSION" ] || { echo "error: archive version is $APP_VERSION, expected $VERSION" >&2; exit 1; }
[ "$APP_BUILD" = "$BUILD_VERSION" ] || { echo "error: archive build is $APP_BUILD, expected $BUILD_VERSION" >&2; exit 1; }

# Locate Sparkle's sign_update: explicit env/flag, then config candidates,
# then DerivedData SPM artifacts, then a Pods checkout.
if [ -z "$SIGN_UPDATE" ]; then
    for candidate in $SIGN_UPDATE_CANDIDATES "$SOURCE_ROOT/Pods/Sparkle/bin/sign_update"; do
        [ -x "$candidate" ] && { SIGN_UPDATE=$candidate; break; }
    done
fi
if [ -z "$SIGN_UPDATE" ]; then
    SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -type f -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' \
        -print -quit 2>/dev/null || true)
fi
[ -n "$SIGN_UPDATE" ] && [ -x "$SIGN_UPDATE" ] || {
    echo "error: Sparkle sign_update not found. Set SPARKLE_SIGN_UPDATE or pass --sign-update PATH." >&2
    exit 1
}

SPARKLE_KEY_ARG=
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    [ -f "$SPARKLE_PRIVATE_KEY_FILE" ] || { echo "error: SPARKLE_PRIVATE_KEY_FILE not found: $SPARKLE_PRIVATE_KEY_FILE" >&2; exit 1; }
    KEY_CONTENTS=$(sed -n '/-----BEGIN PRIVATE KEY-----/,/-----END PRIVATE KEY-----/p' "$SPARKLE_PRIVATE_KEY_FILE" | sed '/-----BEGIN PRIVATE KEY-----/d; /-----END PRIVATE KEY-----/d' | tr -d '\n')
    [ -n "$KEY_CONTENTS" ] || { echo "error: could not read a Sparkle private key" >&2; exit 1; }
    SPARKLE_KEY_ARG="-s $KEY_CONTENTS"
fi

# shellcheck disable=SC2086
SIGN_OUTPUT=$($SIGN_UPDATE $SPARKLE_KEY_ARG "$ZIP")
SIGNATURE=$(printf '%s\n' "$SIGN_OUTPUT" | sed -nE "s/.*sparkle:edSignature=['\"]([^'\"]+)['\"].*/\1/p" | head -1)
LENGTH=$(stat -f '%z' "$ZIP")
[ -n "$SIGNATURE" ] || { echo "error: could not read EdDSA signature:" >&2; printf '%s\n' "$SIGN_OUTPUT" >&2; exit 1; }

DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$TAG/$EXPECTED_ZIP"
PUB_DATE=$(date -R)
PUB_DATE_HUMAN=$(date +'%B %-d, %Y')
OLD_VERSION=""
if [ -n "$CURRENT_VERSION_CMD" ]; then
    OLD_VERSION=$(cd "$ROOT" && sh -c "$CURRENT_VERSION_CMD" || true)
fi

NOTES_PAGE_EXISTS=0
[ -s "$NOTES_FILE" ] && NOTES_PAGE_EXISTS=1
BULLETS_FILE=
if [ "$TAG_RELEASE" -eq 1 ]; then
    GENERATE_NOTES=1
fi

if [ "$NOTES_PAGE_EXISTS" -eq 1 ]; then
    # Hand-written page: reuse it and derive changelog bullets from it.
    BULLETS_FILE="$TMP_DIR/bullets.txt"
    python3 - "$NOTES_FILE" "$BULLETS_FILE" <<'PY'
import html, pathlib, re, sys
source, destination = map(pathlib.Path, sys.argv[1:])
bullets = []
for raw in re.findall(r"<li>(.*?)</li>", source.read_text(), re.S):
    line = html.unescape(re.sub(r"<[^>]+>", "", raw))
    line = " ".join(line.split())
    if line:
        bullets.append(line)
destination.write_text("\n".join(bullets) + ("\n" if bullets else ""))
PY
    echo "Keeping the existing release-notes page for $TAG."
elif [ "$GENERATE_NOTES" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    BULLETS_FILE="$TMP_DIR/bullets.txt"
    RAW_LOG="$TMP_DIR/source-log.tsv"
    PROMPT_FILE="$TMP_DIR/release-notes-prompt.txt"
    MODEL_OUTPUT="$TMP_DIR/model-output.txt"
    git -C "$SOURCE_ROOT" log --format='%h%x09%s' "$LOG_RANGE" > "$RAW_LOG"

    python3 - "$RAW_LOG" "$PROMPT_FILE" "$VERSION" "$SOURCE_TAG" "$PRODUCT_NAME" "$RELEASE_NOTES_CONTEXT" <<'PY'
import pathlib, sys
raw_path, prompt_path, version, last_tag, product, context = sys.argv[1:]
raw = pathlib.Path(raw_path).read_text().strip()
extra = f" since {last_tag}" if last_tag else ""
prompt = f"""Write concise, user-facing release notes for {product} {version}.

Project context: {context}

Use the source commit subjects below as evidence. Do not browse the project or invent details. Group related changes when useful. Prefer 4-12 concrete bullets, each a short sentence beginning with an action or user benefit. Ignore changes clearly unrelated to the macOS app or release tooling. Do not mention commits, hashes, GitHub, source code, a full changelog, or internal implementation details. Return only one plain-text bullet per line with no heading, preamble, code fence, or numbering. These bullets will be shown directly on the public website.

The changes are{extra}:
{raw}
"""
pathlib.Path(prompt_path).write_text(prompt)
PY

    if curl --fail --silent --show-error --max-time 3 "$LLAMA_HEALTH_URL" >/dev/null 2>&1 && command -v pi >/dev/null 2>&1; then
        if python3 - "$PROMPT_FILE" "$MODEL_OUTPUT" "$RELEASE_NOTES_MODEL" "$RELEASE_NOTES_TIMEOUT" <<'PY'
import pathlib, subprocess, sys
prompt_path, output_path, model, timeout = sys.argv[1:]
try:
    result = subprocess.run(["pi", "-p", "--model", model, pathlib.Path(prompt_path).read_text()],
                            capture_output=True, text=True, timeout=int(timeout), check=True)
except Exception as exc:
    print(f"release-notes agent unavailable: {exc}", file=sys.stderr)
    raise SystemExit(1)
pathlib.Path(output_path).write_text(result.stdout)
PY
        then
            if python3 - "$MODEL_OUTPUT" "$BULLETS_FILE" "$RELEASE_NOTES_EXCLUDE" <<'PY'
import pathlib, re, sys
source, destination, extra = map(str, sys.argv[1:4])
extra_re = re.compile(extra) if extra else None
seen, bullets = set(), []
for raw in pathlib.Path(source).read_text().splitlines():
    line = re.sub(r"^(?:[-*•]|\d+[.)])\s+", "", raw.strip().strip('`')).strip()
    if not line or line.lower().rstrip(":") in {"release notes", "release notes:", "here are the release notes"}:
        continue
    lower = line.lower()
    if lower.startswith(("here are ", "changes since ", "changes:")) or lower.endswith("release notes") or len(line) > 300:
        continue
    if extra_re and extra_re.search(line):
        continue
    if line not in seen:
        seen.add(line); bullets.append(line)
if not 2 <= len(bullets) <= 20:
    raise SystemExit("model returned an unusable release-note list")
destination.write_text("\n".join(bullets) + "\n")
PY
            then
                echo "Using pi-generated release notes from source history."
            else
                rm -f "$BULLETS_FILE"
                echo "warning: pi returned an unusable release-note list; using source commits." >&2
            fi
        else
            echo "warning: pi release-note generation failed; using source commits." >&2
        fi
    else
        echo "Using source commits for release notes (llama-server or pi unavailable)."
    fi

    if [ ! -s "${BULLETS_FILE:-}" ]; then
        BULLETS_FILE="$TMP_DIR/bullets.txt"
        python3 - "$RAW_LOG" "$BULLETS_FILE" "$RELEASE_NOTES_EXCLUDE" <<'PY'
import pathlib, re, sys
source, destination, extra = map(str, sys.argv[1:4])
extra_re = re.compile(extra) if extra else None
groups = {"feat": [], "fix": [], "perf": [], "other": []}
for line in pathlib.Path(source).read_text().splitlines():
    if "\t" not in line:
        continue
    commit, subject = line.split("\t", 1)
    if extra_re and extra_re.search(subject):
        continue
    kind, _, rest = subject.partition(":")
    kind = kind.strip().lower()
    rest = rest.strip() or subject.strip()
    if kind in ("feat", "fix", "perf"):
        groups[kind].append(rest)
    elif kind not in ("docs", "chore", "ci", "test", "style", "refactor", "build", "revert"):
        groups["other"].append(rest)
bullets = groups["feat"] + groups["fix"] + groups["perf"] + groups["other"]
destination.write_text("\n".join(bullets) + ("\n" if bullets else ""))
PY
    fi

    mkdir -p "$(dirname -- "$NOTES_FILE")"
    python3 - "$BULLETS_FILE" "$NOTES_FILE" "$VERSION" "$SOURCE_TAG" "$PRODUCT_NAME" <<'PY'
import html, pathlib, sys
bullets_path, output_path, version, last_tag, product = sys.argv[1:]
bullets = [l.strip() for l in pathlib.Path(bullets_path).read_text().splitlines() if l.strip()]
items = "\n".join(f"        <li>{html.escape(l)}</li>" for l in bullets)
base = f" since <code>{html.escape(last_tag)}</code>" if last_tag else ""
pathlib.Path(output_path).write_text(f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>{html.escape(product)} {html.escape(version)} release notes</title>
  <link rel="stylesheet" href="/style.css" />
</head>
<body>
  <main>
    <p class="back"><a href="/changelog-sparkle">&larr; Changelog</a></p>
    <h1>{html.escape(product)} {html.escape(version)} release notes</h1>
    <p>Changes{base}:</p>
    <ul>
{items}
    </ul>
  </main>
</body>
</html>
""")
PY
fi

# GitHub release bodies are Markdown, not HTML.
GITHUB_NOTES_FILE=
if [ -s "$NOTES_MD" ]; then
    GITHUB_NOTES_FILE=$NOTES_MD
elif [ -s "${BULLETS_FILE:-}" ]; then
    GITHUB_NOTES_FILE="$TMP_DIR/github-release-notes.md"
    { echo "## What's new"; echo; sed 's/^/- /' "$BULLETS_FILE"; } > "$GITHUB_NOTES_FILE"
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
    [ "$TAG_RELEASE" -eq 1 ] && echo "Would commit release metadata and create source tag $TAG at $SOURCE_COMMIT."
    exit 0
fi

# Keep the appcast's newest entry first and drop any prior entry for VERSION.
python3 - "$APPCAST_PATH" "$VERSION" "$ITEM" <<'PY'
import pathlib, sys
path, version, item = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
marker = "      <language>en</language>\n"
if marker not in text:
    raise SystemExit(f"error: {path} has no channel language marker")
filtered, in_item, item_lines, remove = [], False, [], False
for line in text.splitlines(True):
    if "<item>" in line:
        in_item, item_lines, remove = True, [line], False
        continue
    if in_item:
        item_lines.append(line)
        if f'sparkle:shortVersionString="{version}"' in line:
            remove = True
        if "</item>" in line:
            if not remove:
                filtered.extend(item_lines)
            in_item = False
        continue
    filtered.append(line)
path.write_text("".join(filtered).replace(marker, marker + item + "\n", 1))
PY

# Website edits (README/version files/changelog HTML) are repo-specific.
if [ -x "$ROOT/scripts/update-site.sh" ]; then
    VERSION="$VERSION" OLD_VERSION="$OLD_VERSION" DOWNLOAD_URL="$DOWNLOAD_URL" \
    PUB_DATE_HUMAN="$PUB_DATE_HUMAN" BULLETS_FILE="${BULLETS_FILE:-}" \
    NOTES_URL="$NOTES_URL" PRODUCT_NAME="$PRODUCT_NAME" APPCAST="$APPCAST" \
    RELEASE_ZIP_NAME="$RELEASE_ZIP_NAME" \
        "$ROOT/scripts/update-site.sh"
fi

SITE_FILES="$SITE_FILES $APPCAST"
[ -s "$NOTES_FILE" ] && SITE_FILES="$SITE_FILES ${NOTES_FILE#"$ROOT/"}"
[ -s "$NOTES_MD" ] && SITE_FILES="$SITE_FILES ${NOTES_MD#"$ROOT/"}"
[ -x "$ROOT/scripts/update-site.sh" ] && SITE_FILES="$SITE_FILES scripts/update-site.sh"

if [ "$TAG_RELEASE" -eq 1 ] || [ "$PUSH_SITE" -eq 1 ]; then
    # shellcheck disable=SC2086
    git -C "$ROOT" add $SITE_FILES
    if ! git -C "$ROOT" diff --cached --quiet; then
        git -C "$ROOT" commit -m "$(printf '%s' "${SITE_COMMIT_MSG:-publish $PRODUCT_NAME v{VERSION}}" | sed "s/{VERSION}/$VERSION/g")"
    fi
fi

if [ "$TAG_RELEASE" -eq 1 ]; then
    git -C "$SOURCE_ROOT" tag -a "$TAG" "$SOURCE_COMMIT" -m "$PRODUCT_NAME $VERSION"
fi
if [ "$PUSH_SITE" -eq 1 ]; then
    git -C "$ROOT" push origin HEAD
    git -C "$SOURCE_ROOT" push origin HEAD
    [ "$TAG_RELEASE" -eq 1 ] && git -C "$SOURCE_ROOT" push origin "$TAG"
fi
if [ "$PUSH_TAG" -eq 1 ] && [ "$PUSH_SITE" -eq 0 ]; then
    git -C "$SOURCE_ROOT" push origin "$TAG"
fi

if [ "$CREATE_RELEASE" -eq 1 ]; then
    command -v gh >/dev/null 2>&1 || { echo "error: gh is required for --create-release" >&2; exit 1; }
    TITLE=$(printf '%s' "${RELEASE_TITLE:-$PRODUCT_NAME {VERSION}}" | sed "s/{VERSION}/$VERSION/g")
    if [ -n "${GITHUB_NOTES_FILE:-}" ] && [ -s "$GITHUB_NOTES_FILE" ]; then
        NOTES_ARG="--notes-file $GITHUB_NOTES_FILE"
    else
        NOTES_ARG="--generate-notes"
    fi
    if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
        gh release upload "$TAG" "$ZIP" --clobber --repo "$REPOSITORY"
        # shellcheck disable=SC2086
        gh release edit "$TAG" --title "$TITLE" $NOTES_ARG --repo "$REPOSITORY"
    else
        # shellcheck disable=SC2086
        gh release create "$TAG" "$ZIP" --title "$TITLE" $NOTES_ARG --repo "$REPOSITORY"
    fi
fi

echo "Updated $APPCAST for v$VERSION ($LENGTH bytes)."
[ "$TAG_RELEASE" -eq 1 ] && echo "Created source tag $TAG at $SOURCE_ROOT@$SOURCE_COMMIT."
