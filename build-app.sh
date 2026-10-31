#!/bin/sh
# Builds ColimaDeck.app into ./build. Pass --install to copy it into /Applications.
set -e
cd "$(dirname "$0")"

swift build -c release
APP=build/ColimaDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ColimaDeck" "$APP/Contents/MacOS/ColimaDeck"

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
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>ColimaDeck opens Terminal to give you a shell inside machines and containers.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "$1" = "--install" ]; then
    rm -rf /Applications/ColimaDeck.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/ColimaDeck.app"
fi
