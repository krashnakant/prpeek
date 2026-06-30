#!/bin/bash
# Package the built binary into a proper .app bundle so UNUserNotifications +
# Keychain work (they need a bundle id). Ad-hoc signed for local use.
# Real distribution = Developer ID notarize (deferred, see plan NOT-in-scope).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="PRPeek.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PRPeek "$APP/Contents/MacOS/PRPeek"

# App icon: build AppIcon.icns from the 1024 source PNG (see Scripts/make-icon.swift).
ICON_SRC="Assets/AppIcon-1024.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s*2))" "$((s*2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
else
  echo "WARNING: $ICON_SRC missing — app will have no icon. Run: swift Scripts/make-icon.swift"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PRPeek</string>
  <key>CFBundleDisplayName</key><string>PRPeek</string>
  <key>CFBundleIdentifier</key><string>com.prpeek.app</string>
  <key>CFBundleExecutable</key><string>PRPeek</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Bake the OAuth App client id (public) for device-flow sign-in. Set
# PRPEEK_CLIENT_ID before running, or paste a PAT in the app instead.
CLIENT_ID="${PRPEEK_CLIENT_ID:-}"
/usr/libexec/PlistBuddy -c "Add :PRPeekClientID string $CLIENT_ID" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :PRPeekClientID $CLIENT_ID" "$APP/Contents/Info.plist"

# Sign LAST — signing seals the bundle; any later plist edit breaks the signature.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP  (client id: ${CLIENT_ID:-<none, paste a PAT>})"
echo "Run: open $(pwd)/$APP"
