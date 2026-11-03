#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="dist/CallScribe.app"

swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/CallScribe" "$APP/Contents/MacOS/CallScribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Ad-hoc signature with a stable designated requirement.
# Without an explicit requirement macOS ties TCC permissions to the binary hash,
# so every rebuild would force the user to grant screen recording again.
codesign --force --sign - --timestamp=none \
    --requirements '=designated => identifier "com.mistxs.callscribe"' \
    "$APP"

echo "Готово: $APP"
echo "Запуск: open $APP"
