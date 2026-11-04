#!/bin/bash
# Installs a released SlopDrop build without Gatekeeper's first-launch block.
#
#   ./Scripts/install.sh                    latest release, into /Applications
#   ./Scripts/install.sh --version v0.1.0   a specific tag
#   ./Scripts/install.sh --prefix ~/Applications
#
# Files fetched by curl or gh carry no com.apple.quarantine attribute, so macOS
# never runs Gatekeeper's launch check — no "Open Anyway" step, unlike a browser
# download. The checksum is still verified before anything is replaced.
set -euo pipefail

# Printed rather than read from $0: this script is usually piped into bash.
usage() {
    cat <<'USAGE'
Installs a released SlopDrop build without Gatekeeper's first-launch block.

  install.sh                     latest release, into /Applications
  install.sh --version v0.1.0    a specific tag
  install.sh --prefix DIR        install somewhere other than /Applications
USAGE
}

REPO="goldsky-io/slopdrop"
VERSION=""
PREFIX="/Applications"

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a tag}"; shift 2 ;;
        --prefix)  PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "SlopDrop: unknown option $1" >&2; exit 1 ;;
    esac
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

api="https://api.github.com/repos/$REPO"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

have_gh() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }

# Read the release metadata with whichever client can authenticate; without one
# this still works for a public repo, and fails cleanly for a private one.
api_get() {
    if have_gh; then
        gh api "$api$1"
    elif [ -n "$token" ]; then
        curl -fsSL -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' "$api$1"
    else
        curl -fsSL -H 'Accept: application/vnd.github+json' "$api$1"
    fi
}

if [ -z "$VERSION" ]; then
    VERSION="$(api_get /releases/latest | python3 -c '
import json, sys
print(json.load(sys.stdin)["tag_name"])
')" || { echo "SlopDrop: could not reach $REPO" >&2; exit 1; }
fi

release="$(api_get "/releases/tags/$VERSION")" || {
    echo "SlopDrop: no release tagged $VERSION in $REPO" >&2
    if ! have_gh && [ -z "$token" ]; then
        echo "SlopDrop: $REPO is private, so authenticate gh or set GH_TOKEN" >&2
    fi
    exit 1
}
printf '%s' "$release" | python3 -c '
import json, sys
for asset in json.load(sys.stdin)["assets"]:
    if asset["name"].endswith(".zip") or asset["name"] == "SHA256SUMS":
        print(asset["id"], asset["name"])
' > "$tmp/assets.txt"

if [ ! -s "$tmp/assets.txt" ]; then
    echo "SlopDrop: release $VERSION has no .zip or SHA256SUMS" >&2
    exit 1
fi

if have_gh; then
    gh release download "$VERSION" --repo "$REPO" \
        --pattern 'SlopDrop-*.zip' --pattern 'SHA256SUMS' --dir "$tmp" --clobber
else
    while read -r id name; do
        if [ -n "$token" ]; then
            curl -fsSL -H "Authorization: Bearer $token" -H 'Accept: application/octet-stream' \
                "$api/releases/assets/$id" -o "$tmp/$name"
        else
            curl -fsSL -H 'Accept: application/octet-stream' \
                "$api/releases/assets/$id" -o "$tmp/$name"
        fi
    done < "$tmp/assets.txt"
fi

cd "$tmp"
# SHA256SUMS lists the .dmg too, so verify only what was actually downloaded.
shasum -a 256 -c --ignore-missing SHA256SUMS >/dev/null || {
    echo "SlopDrop: checksum mismatch, nothing installed" >&2
    exit 1
}
ditto -x -k SlopDrop-*.zip "$tmp/extracted"

APP="$PREFIX/SlopDrop.app"
mkdir -p "$PREFIX"
rm -rf "$APP"
ditto "$tmp/extracted/SlopDrop.app" "$APP"
# Belt and braces, in case this script itself arrived through a browser.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "installed $APP ($VERSION)"
if pgrep -f "$APP/Contents/MacOS/SlopDrop" >/dev/null; then
    echo "SlopDrop is running — quit and reopen it to use this build"
else
    echo "open \"$APP\""
fi
