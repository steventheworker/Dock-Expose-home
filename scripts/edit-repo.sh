#!/bin/sh
# Apply this -home repo's GitHub "About" panel: description, homepage (SITE_URL),
# and topics, from release.config.sh. Idempotent; run it after the repo exists.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$ROOT/release.config.sh" ] || { echo "error: missing $ROOT/release.config.sh" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/release.config.sh"

command -v gh >/dev/null 2>&1 || { echo "error: gh is required for repo metadata" >&2; exit 1; }
REPO=${HOME_REPOSITORY:-}
if [ -z "$REPO" ]; then
    REPO=$(cd "$ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
fi
[ -n "$REPO" ] || { echo "error: set HOME_REPOSITORY in release.config.sh" >&2; exit 1; }

set -- "$REPO"
[ -n "${REPO_DESCRIPTION:-}" ] && set -- "$@" --description "$REPO_DESCRIPTION"
[ -n "${SITE_URL:-}" ] && set -- "$@" --homepage "$SITE_URL"
# Topics are additive: --add-topic only adds, so topics set on the repo by hand
# (or by a previous run) are never removed.
for topic in ${REPO_TOPICS:-}; do
    set -- "$@" --add-topic "$topic"
done
gh repo edit "$@" >/dev/null
echo "Updated $REPO About (homepage: ${SITE_URL:-none}, topics: ${REPO_TOPICS:-none})."
