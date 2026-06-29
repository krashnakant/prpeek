#!/bin/bash
# Package PRPeek.app into a distributable PRPeek.dmg (drag-to-Applications layout).
# The .app is ad-hoc signed by make-app.sh (not notarized) — first launch needs
# right-click ▸ Open. Notarization is a tracked follow-up (needs a Developer ID).
set -euo pipefail
cd "$(dirname "$0")/.."

bash Scripts/make-app.sh        # builds release PRPeek.app
APP="PRPeek.app"
DMG="PRPeek.dmg"
rm -f "$DMG"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install affordance
hdiutil create -volname "PRPeek" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Built $(pwd)/$DMG"
