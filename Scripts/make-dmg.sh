#!/bin/bash
#
# Builds DrivePurge.app from the SPM target and wraps it in a distributable
# disk image.  Usage:  ./Scripts/make-dmg.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="DrivePurge"
VERSION="1.0.0"
BUNDLE_ID="com.drivepurge.DrivePurge"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP_NAME.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

echo "==> Rendering app icon"
ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/Scripts/make-icon.swift" "$DIST/icon-1024.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z $size $size        "$DIST/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png"    >/dev/null
    sips -z $((size*2)) $((size*2)) "$DIST/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>DrivePurge measures the size of your Desktop so it can appear in the treemap.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>DrivePurge measures the size of your Documents folder so it can appear in the treemap.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>DrivePurge measures the size of your Downloads folder so it can appear in the treemap.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>DrivePurge measures the size of connected volumes so they can appear in the treemap.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature OK"

echo "==> Building disk image"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE" "$DIST/icon-1024.png"

echo ""
echo "Done:"
echo "  App: $APP"
echo "  DMG: $DMG  ($(du -h "$DMG" | cut -f1))"
