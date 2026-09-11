#!/bin/bash
# Builds Headroom and wraps it in a minimal .app bundle. No Xcode required.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Headroom.app"
pkill -x Headroom 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Headroom "$APP/Contents/MacOS/Headroom"
cp Icons/claude.png Icons/openai.png Icons/kimi.png "$APP/Contents/Resources/"
cp Icons/Headroom.icns "$APP/Contents/Resources/"
cp Prices.json "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sid.headroom</string>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>Headroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# The desktop widgets. The extension runs the app's own binary; `Main` tells the two
# apart by the bundle it was launched from.
WIDGETS="$APP/Contents/PlugIns/HeadroomWidgets.appex"
mkdir -p "$WIDGETS/Contents/MacOS" "$WIDGETS/Contents/Resources"
cp .build/release/Headroom "$WIDGETS/Contents/MacOS/HeadroomWidgets"
cp Icons/claude.png Icons/openai.png Icons/kimi.png "$WIDGETS/Contents/Resources/"

cat > "$WIDGETS/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sid.headroom.widgets</string>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleExecutable</key><string>HeadroomWidgets</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict></plist>
PLIST

# App extensions on macOS must be sandboxed. The one opening is read access to the
# folder the app saves the panel's figures in.
cat > .build/HeadroomWidgets.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
  <array><string>/.cache/headroom/</string></array>
</dict></plist>
PLIST

# Inside out: the app's signature seals the extension's.
codesign --force --sign - --entitlements .build/HeadroomWidgets.entitlements "$WIDGETS"
codesign --force --sign - "$APP"

# Spotlight only indexes /Applications, so keep that copy in step with this build.
rsync -a --delete "$APP/" /Applications/Headroom.app/

echo "Built $APP and installed to /Applications"
