#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-QuickRes}"
BUNDLE_ID="${BUNDLE_ID:-com.quickres.app}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-12.0}"
VERSION="${VERSION:-${GITHUB_REF_NAME:-dev}}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

swift build -c release --product "$APP_NAME"
BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_SYSTEM_VERSION</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

ZIP_SUFFIX=""
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP_DIR"
    echo "Signed with Developer ID identity: $SIGNING_IDENTITY"
else
    codesign --force --deep --sign - "$APP_DIR"
    ZIP_SUFFIX="-unsigned"
    echo "Using ad-hoc signature (free mode, not notarized)."
fi

ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-macOS${ZIP_SUFFIX}.zip"
rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

echo "Created:"
echo "  $ZIP_PATH"
echo "  $ZIP_PATH.sha256"
