#!/bin/bash
# Package the built binary into a proper .app bundle so UNUserNotifications +
# Keychain work (they need a bundle id). Ad-hoc signed for local use.
# Real distribution = Developer ID notarize (deferred, see plan NOT-in-scope).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="PRPeek.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PRPeek "$APP/Contents/MacOS/PRPeek"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PRPeek</string>
  <key>CFBundleDisplayName</key><string>PRPeek</string>
  <key>CFBundleIdentifier</key><string>com.prpeek.app</string>
  <key>CFBundleExecutable</key><string>PRPeek</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
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
