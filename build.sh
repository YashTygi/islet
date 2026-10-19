#!/bin/bash
# Builds Islet.app (release) next to this script. Usage: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release

# Stable identity so macOS privacy grants (Accessibility, Calendar, Camera) survive rebuilds.
# Falls back to ad-hoc ("-") if the "MyNotch Dev" self-signed certificate isn't in the keychain.
SIGN=$(security find-certificate -c "MyNotch Dev" -Z 2>/dev/null | awk '/SHA-1/{print $3}')
SIGN=${SIGN:--}

# mediaremote-adapter (BSD-3, vendored): framework is loaded by /usr/bin/perl, not linked.
A=Vendor/mediaremote-adapter
FW=build/fw/MediaRemoteAdapter.framework
if [[ ! -f "$FW/MediaRemoteAdapter" || -n "$(find $A/src $A/include -newer "$FW/MediaRemoteAdapter")" ]]; then
  mkdir -p "$FW"
  clang -arch arm64 -dynamiclib -fobjc-arc -fvisibility=default -O2 -mmacosx-version-min=14.0 \
    -I$A/include -I$A/src $A/src/adapter/*.m $A/src/private/*.m $A/src/utility/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter -o "$FW/MediaRemoteAdapter"
fi

APP=build/Islet.app
# Never replace the bundle under a running copy (AppKit reads Info.plist lazily and crashes).
if pgrep -f "$PWD/$APP/" >/dev/null; then pkill -f "$PWD/$APP/" || true; while pgrep -f "$PWD/$APP/" >/dev/null; do sleep 0.2; done; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Islet "$APP/Contents/MacOS/Islet"
mkdir -p "$APP/Contents/Helpers"
cp .build/release/IsletCLI "$APP/Contents/Helpers/islet"     # CLI: islet run / agent / hook / usage
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # regenerate: swift tools/make-icon.swift
codesign --force --sign "$SIGN" "$APP/Contents/Helpers/islet"
cp -R "$FW" "$APP/Contents/Resources/"
cp $A/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"
codesign --force --sign "$SIGN" "$APP/Contents/Resources/MediaRemoteAdapter.framework/MediaRemoteAdapter"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.yashtyagi.Islet</string>
  <key>CFBundleName</key><string>Islet</string>
  <key>CFBundleExecutable</key><string>Islet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAppleEventsUsageDescription</key><string>Reads the current browser tab so the notch can offer actions for it.</string>
  <key>NSCameraUsageDescription</key><string>Shows your camera in the notch (Camera tab).</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your next event in the notch.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Shows when Bluetooth devices connect or disconnect.</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGN" "$APP"
echo "Built $APP"
if [[ "${1:-}" == "run" ]]; then pkill -x Islet || true; open "$APP"; fi
