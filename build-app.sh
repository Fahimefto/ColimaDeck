#!/bin/sh
# Builds a universal (Apple Silicon + Intel) ColimaDeck.app into ./build.
#   --install  also copy it into /Applications
#   --dmg      also package it as build/ColimaDeck-<version>.dmg
set -e
cd "$(dirname "$0")"

VERSION=0.2.0
APP=build/ColimaDeck.app

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --dmg) DMG=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# Build each architecture separately and merge them, which works without a full Xcode install.
BINARIES=""
for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx14.0"
    swift build -c release --triple "$TRIPLE"
    BINARIES="$BINARIES $(swift build -c release --triple "$TRIPLE" --show-bin-path)/ColimaDeck"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# shellcheck disable=SC2086
lipo -create $BINARIES -output "$APP/Contents/MacOS/ColimaDeck"
# The icon is drawn by scripts/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ColimaDeck</string>
    <key>CFBundleDisplayName</key><string>ColimaDeck</string>
    <key>CFBundleIdentifier</key><string>com.fahimefto.ColimaDeck</string>
    <key>CFBundleExecutable</key><string>ColimaDeck</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>ColimaDeck opens Terminal to give you a shell inside machines and containers.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ColimaDeck"))"

if [ -n "$INSTALL" ]; then
    rm -rf /Applications/ColimaDeck.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/ColimaDeck.app"
fi

if [ -n "$DMG" ]; then
    STAGING=build/dmg
    OUT="build/ColimaDeck-$VERSION.dmg"
    rm -rf "$STAGING" "$OUT"
    mkdir -p "$STAGING"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "ColimaDeck" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
    rm -rf "$STAGING"
    echo "Packaged $OUT"
fi
