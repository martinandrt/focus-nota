#!/bin/bash
# Build "Focus Nota.app" (menu bar focus player) and install to ~/Applications; Spotlight finds "focus" and "nota". build.noindex keeps the copy out of Spotlight.
set -euo pipefail
cd "$(dirname "$0")"
APP="build.noindex/Focus Nota.app"
rm -rf build.noindex && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target "$(uname -m)-apple-macos13.0" ${SWIFT_CACHE:+-module-cache-path "$SWIFT_CACHE"} -o "$APP/Contents/MacOS/Nota" Focus.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Focus Nota</string>
  <key>CFBundleDisplayName</key><string>Focus Nota</string>
  <key>CFBundleIdentifier</key><string>cz.martinandrt.focusnota</string>
  <key>CFBundleExecutable</key><string>Nota</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Focus Nota plays music from a folder on your Desktop.</string>
</dict></plist>
PLIST
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
# Stable signing identity keeps the Desktop-folder permission across rebuilds; ad-hoc (-) asks again each build.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}' || true)
codesign --force --sign "${SIGN_ID:--}" "$APP"
[ -n "$SIGN_ID" ] || echo "note: no Apple Development certificate found, signed ad hoc; macOS will ask for folder access again" >&2
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  ditto "$APP" "$HOME/Applications/Focus Nota.app"
  echo "installed: ~/Applications/Focus Nota.app"
fi
