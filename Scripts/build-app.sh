#!/bin/bash
# Builds SlopDrop.app from the SwiftPM package and installs it in ~/Applications.
#
#   ./Scripts/build-app.sh                              release build
#   ./Scripts/build-app.sh debug                        debug build
#   INSTALL_DIR=/Applications ./Scripts/build-app.sh    install somewhere else
#   INSTALL_DIR= ./Scripts/build-app.sh                 build dist/SlopDrop.app only
#   VERSION=1.2.0 BUNDLE_VERSION=42 ./Scripts/build-app.sh   stamp an explicit version
#   UNIVERSAL=1 ./Scripts/build-app.sh                  arm64 + x86_64, as releases ship
set -euo pipefail

CONFIG="${1:-release}"
INSTALL_DIR="${INSTALL_DIR-$HOME/Applications}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# CFBundleShortVersionString: explicit VERSION, else the newest tag (v0.2.0 -> 0.2.0).
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed -E 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
# CFBundleVersion: any integer that only ever grows; releases pass the workflow run number.
BUNDLE_VERSION="${BUNDLE_VERSION:-1}"

ARCH_ARGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product SlopDrop

BIN="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"
APP="$ROOT/dist/SlopDrop.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/SlopDrop" "$APP/Contents/MacOS/SlopDrop"
cp -R "$BIN/SlopDrop_SlopDrop.bundle" "$APP/Contents/Resources/"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SlopDrop</string>
    <key>CFBundleIdentifier</key><string>com.slopdrop.app</string>
    <key>CFBundleName</key><string>SlopDrop</string>
    <key>CFBundleDisplayName</key><string>SlopDrop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP ($VERSION build $BUNDLE_VERSION)"

if [ -z "$INSTALL_DIR" ]; then
    exit 0
fi

INSTALLED="$INSTALL_DIR/SlopDrop.app"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
codesign --force --sign - "$INSTALLED" >/dev/null 2>&1 || true
touch "$INSTALLED"

echo "installed $INSTALLED"

if pgrep -f "SlopDrop.app/Contents/MacOS/SlopDrop" >/dev/null; then
    echo "SlopDrop is running — relaunch it to pick up this build"
fi
