#!/bin/bash
# Installs a released SlopDrop build without Gatekeeper's first-launch block.
#
#   ./Scripts/install.sh                    latest release, into /Applications
#   ./Scripts/install.sh --version v0.1.0   a specific tag
#   ./Scripts/install.sh --prefix ~/Applications
#
# A browser download carries com.apple.quarantine and macOS runs Gatekeeper on
# first launch; files fetched by curl or gh never get the attribute, so the app
# opens without the "Open Anyway" detour. The checksum is verified regardless.
set -euo pipefail

REPO="goldsky-io/slopdrop"
VERSION=""
PREFIX="/Applications"

# Printed rather than read from $0: this script is usually piped into bash.
usage() {
    cat <<'USAGE'
Installs a released SlopDrop build without Gatekeeper's first-launch block.

  install.sh                     latest release, into /Applications
  install.sh --version v0.1.0    a specific tag
  install.sh --prefix DIR        install somewhere other than /Applications
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a tag}"; shift 2 ;;
        --prefix)  PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "SlopDrop: unknown option $1" >&2; exit 1 ;;
    esac
done
[ -n "$VERSION" ] && VERSION="v${VERSION#v}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

have_gh() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }

if have_gh; then
    # gh also reaches private releases; it needs no JSON parsing of its own.
    if [ -z "$VERSION" ]; then
        VERSION="$(gh api "repos/$REPO/releases/latest" --jq .tag_name)"
    fi
    gh release download "$VERSION" --repo "$REPO" \
        --pattern 'SlopDrop-*.zip' --pattern 'SHA256SUMS' --dir "$tmp" --clobber
else
    # Public releases: resolve the tag from the redirect and fetch the assets
    # directly, so a stock Mac needs nothing beyond curl.
    if [ -z "$VERSION" ]; then
        VERSION="$(curl -sIL -o /dev/null -w '%{url_effective}' \
            "https://github.com/$REPO/releases/latest" | sed -E 's#.*/tag/##')"
    fi
    case "$VERSION" in
        v[0-9]*) ;;
        *) echo "SlopDrop: could not resolve a release; authenticate gh or pass --version" >&2; exit 1 ;;
    esac
    url="https://github.com/$REPO/releases/download/$VERSION"
    curl -fsSL "$url/SlopDrop-${VERSION#v}.zip" -o "$tmp/SlopDrop-${VERSION#v}.zip" || {
        echo "SlopDrop: could not download $VERSION from $REPO" >&2
        echo "SlopDrop: if the repo is private, authenticate gh first" >&2
        exit 1
    }
    curl -fsSL "$url/SHA256SUMS" -o "$tmp/SHA256SUMS"
fi

cd "$tmp"
# SHA256SUMS lists the .dmg too, so verify only what was actually downloaded.
shasum -a 256 -c --ignore-missing SHA256SUMS >/dev/null || {
    echo "SlopDrop: checksum mismatch, nothing installed" >&2
    exit 1
}
ditto -x -k SlopDrop-*.zip "$tmp/extracted"

APP="$PREFIX/SlopDrop.app"
mkdir -p "$PREFIX" 2>/dev/null || {
    echo "SlopDrop: cannot write to $PREFIX — try --prefix ~/Applications" >&2
    exit 1
}
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
