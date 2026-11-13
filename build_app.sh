#!/usr/bin/env bash
# Builds a standalone native macOS .app bundle for Traffic Monitor (Menu Bar + Dashboard)
# Uses Swift / AppKit / SwiftUI / Charts / SQLite3 with zero external dependencies.

set -e

APP_NAME="Traffic Monitor"
BUNDLE_DIR="${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building ${BUNDLE_DIR} (Native Swift Universal Binary)..."

rm -rf "${PROJECT_DIR}/${BUNDLE_DIR}"
mkdir -p "${PROJECT_DIR}/${MACOS_DIR}"
mkdir -p "${PROJECT_DIR}/${RESOURCES_DIR}"

SWIFT_SOURCES=(
    "${PROJECT_DIR}/macos/Models.swift"
    "${PROJECT_DIR}/macos/Database.swift"
    "${PROJECT_DIR}/macos/TrafficMonitor.swift"
    "${PROJECT_DIR}/macos/DashboardView.swift"
    "${PROJECT_DIR}/macos/main.swift"
)

if swiftc -O -target arm64-apple-macos13.0 "${SWIFT_SOURCES[@]}" -lsqlite3 -o "${PROJECT_DIR}/${MACOS_DIR}/TrafficMonitor_arm64" 2>/dev/null && \
   swiftc -O -target x86_64-apple-macos13.0 "${SWIFT_SOURCES[@]}" -lsqlite3 -o "${PROJECT_DIR}/${MACOS_DIR}/TrafficMonitor_x86_64" 2>/dev/null; then
    lipo -create -output "${PROJECT_DIR}/${MACOS_DIR}/${APP_NAME}" \
        "${PROJECT_DIR}/${MACOS_DIR}/TrafficMonitor_arm64" \
        "${PROJECT_DIR}/${MACOS_DIR}/TrafficMonitor_x86_64"
    rm -f "${PROJECT_DIR}/${MACOS_DIR}/TrafficMonitor_arm64" "${PROJECT_DIR}/${MACOS_DIR}/TrafficMonitor_x86_64"
    echo "✅ Compiled Universal Binary (arm64 + x86_64)"
else
    swiftc -O "${SWIFT_SOURCES[@]}" -lsqlite3 -o "${PROJECT_DIR}/${MACOS_DIR}/${APP_NAME}"
    echo "✅ Compiled Native Host Binary"
fi

chmod +x "${PROJECT_DIR}/${MACOS_DIR}/${APP_NAME}"

if [ -f "${PROJECT_DIR}/macos/AppIcon.icns" ]; then
    cp "${PROJECT_DIR}/macos/AppIcon.icns" "${PROJECT_DIR}/${RESOURCES_DIR}/AppIcon.icns"
fi

cat <<EOF > "${PROJECT_DIR}/${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.trafficmonitor</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "${PROJECT_DIR}/${BUNDLE_DIR}" 2>/dev/null || true
touch "${PROJECT_DIR}/${BUNDLE_DIR}"

echo "✅ Successfully built: ${PROJECT_DIR}/${BUNDLE_DIR}"
echo "You can now double-click '${APP_NAME}.app' in Finder or drag it to /Applications!"
