#!/bin/bash
# macOS release: .app bundle, Developer ID signed, hardened runtime,
# notarized + stapled when a notary profile is available, zipped.
#   SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE=ProfileName ./build-macos.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP=AsteroidZ
SIGN_ID="${SIGN_ID:-Developer ID Application: Todd Bruss (469UCUB275)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

./build.sh

BUNDLE="release/out/$APP.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp asteroidz-direct "$BUNDLE/Contents/MacOS/$APP"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>$APP</string>
    <key>CFBundleIdentifier</key><string>com.superbox64.asteroidz</string>
    <key>CFBundleName</key><string>$APP</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "APPL????" > "$BUNDLE/Contents/PkgInfo"

codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$BUNDLE"
codesign --verify --strict "$BUNDLE"
echo "✓ signed: $SIGN_ID"

ZIP="release/out/$APP-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$BUNDLE" "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$BUNDLE"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$BUNDLE" "$ZIP"
  echo "✓ notarized + stapled"
else
  echo "→ notarization skipped (set NOTARY_PROFILE after: xcrun notarytool store-credentials)"
fi
echo "✓ $ZIP"
