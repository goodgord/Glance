#!/bin/zsh
# Build Glance.app. Usage: ./build.sh [--install]   (--install copies to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

# A stable signing identity keeps Camera/Accessibility grants across rebuilds.
IDENTITY="${GLANCE_SIGN_IDENTITY:-Apple Development}"

swift build -c release
APP=build/Glance.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Glance "$APP/Contents/MacOS/Glance"
cp Info.plist "$APP/Contents/Info.plist"

if ! codesign --force --options runtime --entitlements Glance.entitlements --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signing with '$IDENTITY' failed; falling back to ad-hoc (permissions will reset on each rebuild)"
  codesign --force --entitlements Glance.entitlements --sign - "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Glance 2>/dev/null || true
  rm -rf /Applications/Glance.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Glance.app"
else
  echo "Built $APP"
fi
