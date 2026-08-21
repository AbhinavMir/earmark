#!/bin/bash
# Builds Earmarky.app from the SwiftPM executable.
#
# SwiftPM produces a plain binary. macOS needs a bundle for the Dock, the menu
# bar, and the Now Playing panel, so this wraps the binary in one.
set -euo pipefail

CONFIGURATION="${1:-release}"
APP_NAME="Earmarky"
BUNDLE_ID="com.earmarky.app"
# The one place the version is written. A bundle whose version disagrees with
# the release it came from asks to update itself forever.
VERSION="${EARMARK_VERSION:-1.0.0}"

swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP_DIR="build/${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# The icon, which the Dock and the Finder show.
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# Sign with a real identity when the machine has one.
#
# An ad-hoc signature changes with every build, so macOS treats each build as a
# different application and asks for Keychain permission again. A stable
# identity keeps that permission across rebuilds.
IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" \
    | head -1 \
    | sed -E 's/.*"(.*)"/\1/')"

if [ -n "$IDENTITY" ]; then
    codesign --force --deep --options runtime --sign "$IDENTITY" "$APP_DIR" >/dev/null 2>&1 \
        && echo "Signed as: $IDENTITY" \
        || echo "Warning: signing failed. The application still runs." >&2
else
    echo "No signing identity found. Using an ad-hoc signature, which asks for" >&2
    echo "Keychain permission again after every build." >&2
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built ${APP_DIR} (version ${VERSION})"
echo "Run it with: open ${APP_DIR}"
