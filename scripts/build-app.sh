#!/bin/sh
set -eu

swift build -c release --disable-sandbox

APP="dist/TapKey.app"
BIN="$(swift build -c release --disable-sandbox --show-bin-path)/TapKey"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TapKey"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
codesign --force --sign - "$APP"

echo "Built $APP"
