#!/bin/bash
# Builds Earmark.app from the SwiftPM executable.
#
# SwiftPM produces a plain binary. macOS needs a bundle for the Dock, the menu
# bar, and the Now Playing panel, so this wraps the binary in one.
set -euo pipefail

CONFIGURATION="${1:-release}"
APP_NAME="Earmark"
BUNDLE_ID="com.earmark.app"
VERSION="0.1.0"

swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP_DIR="build/${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# An ad-hoc signature is enough for a locally built application, and the
# Keychain item stays tied to this identity across rebuilds.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || {
    echo "Warning: codesign failed. The application still runs." >&2
}

echo "Built ${APP_DIR}"
echo "Run it with: open ${APP_DIR}"
