#!/bin/sh
# Dock Exposé website edits (index.html, README, docs, changelogs, currentversion).
# Called by scripts/publish-release.sh with VERSION, OLD_VERSION, DOWNLOAD_URL,
# PUB_DATE_HUMAN, BULLETS_FILE, NOTES_URL, PRODUCT_NAME, RELEASE_ZIP_NAME.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

printf '%s\n' "$VERSION" > "$ROOT/currentversion.txt"

python3 - "$ROOT" "$VERSION" "$OLD_VERSION" "$DOWNLOAD_URL" "$PUB_DATE_HUMAN" "${BULLETS_FILE:-}" "$NOTES_URL" <<'PY'
import html, pathlib, re, sys

root, version, old, url, date, bullets_file, notes_url = sys.argv[1:8]
root = pathlib.Path(root)

for rel in ("index.html", "README.md", "docs/index.html", "docs/permissions/index.html"):
    path = root / rel
    if not path.exists():
        continue
    text = path.read_text()
    if old and old != version:
        text = text.replace(f"Dock Exposé {old}", f"Dock Exposé {version}")
    text = re.sub(
        r"https://github\.com/[^/\s\"]+/[^/\s\"]+/releases/download/v[0-9.]+\S+",
        url,
        text,
    )
    path.write_text(text)

bullets = []
if bullets_file and pathlib.Path(bullets_file).stat().st_size:
    bullets = [l.strip() for l in pathlib.Path(bullets_file).read_text().splitlines() if l.strip()]

def block(indent):
    child = "\t" if indent == "\t" else "  "
    lines = [
        f"{indent}<li>",
        f"{indent}{child}<ul>",
        f"{indent}{child}{child}<span>{version} release</span>",
        f'{indent}{child}{child}<h7><a href="{html.escape(notes_url)}">v{html.escape(version)}</a></h7>',
    ]
    lines.extend(f"{indent}{child}{child}<li>{html.escape(b, quote=False)}</li>" for b in bullets)
    lines.extend([f"{indent}{child}</ul>", f"{indent}</li>"])
    return "\n".join(lines)

def update(rel, heading, indent):
    path = root / rel
    if not path.exists() or not bullets:
        return
    text = path.read_text()
    if f"<span>{version} release</span>" in text:
        pattern = re.compile(
            r"(?ms)^[ \t]*<li>\s*<ul>\s*<span>"
            + re.escape(f"{version} release")
            + r"</span>.*?^[ \t]*</ul>\s*</li>"
        )
        text, count = pattern.subn(block(indent), text, count=1)
        if count != 1:
            raise SystemExit(f"could not replace existing {version} entry in {path}")
    else:
        if heading not in text:
            raise SystemExit(f"changelog heading not found in {path}")
        text = text.replace(heading, heading + "\n" + block(indent), 1)
    path.write_text(text)

update("changelog-sparkle/index.html", "\t<h4>Version Control / Changelog:</h4>", "\t")
update("index.html", "        <h4>Version Control / Changelog:</h4>", "          ")
PY
