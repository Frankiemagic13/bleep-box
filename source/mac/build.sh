#!/bin/bash
# Builds "Bleep Box.app" into source/mac/build/
# Needs Xcode or the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

echo "== Building Bleep Box for Mac =="
swift build -c release

APP="build/Bleep Box.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/BleepBox" "$APP/Contents/MacOS/BleepBox"
cp Info.plist "$APP/Contents/Info.plist"

# App icon (from the Stream Deck plugin image)
ICON_SRC="../streamdeck/com.frankievalletech.bleepbox.sdPlugin/imgs/plugin@2x.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2)); [ $d -gt 512 ] && d=512
    sips -z $d $d "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Hidden helper app that plays only the bleep to your headphones.
# Own bundle ID, so Wave Link sees it as a different app.
HELPER="$APP/Contents/Resources/Bleep Box Monitor.app"
mkdir -p "$HELPER/Contents/MacOS"
cp "$APP/Contents/MacOS/BleepBox" "$HELPER/Contents/MacOS/BleepBoxMonitor"
cat > "$HELPER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Bleep Box Monitor</string>
    <key>CFBundleIdentifier</key><string>com.frankievalletech.bleepbox.monitor</string>
    <key>CFBundleExecutable</key><string>BleepBoxMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signatures (helper first), so macOS lets the app ask for the microphone
codesign --force --sign - "$HELPER"
codesign --force --sign - "$APP"

echo "Done: $(pwd)/$APP"
