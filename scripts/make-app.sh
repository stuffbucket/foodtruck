#!/usr/bin/env bash
set -euo pipefail

# Assembles dist/FoodTruck.app around the SwiftPM binary.
#
# Used by developers and, once the release producer is switched over, by the
# signing Mac too -- so the bundle proven on a laptop is the one that gets
# notarized. It builds the .app and stops: no signing, no dmg, no notarizing.
# That tail belongs to stuffbucket/macos-builder and this script must never
# grow into it.

TAG="${TAG:-v0.0.0-local}"
CONFIG="${CONFIG:-release}"
VERSION="${TAG#v}"
NUMERIC="${VERSION%%-*}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="dist/FoodTruck.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build -c "$CONFIG" --product foodtruck
cp "$(swift build -c "$CONFIG" --show-bin-path)/foodtruck" "$APP/Contents/MacOS/FoodTruck"

# Localisations, flattened to the layout a real bundle uses. L10n tries the
# SwiftPM layout, this one, and Foundation's own lookup, so one code path serves
# `swift run`, the .app, and the tests.
for lproj in Sources/FoodTruckKit/Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

# The shipped recipes and the pin manifest. Read-only here on purpose: this copy
# is inside the signed bundle, so a forked recipe in the user's pantry can never
# repoint a download.
mkdir -p "$APP/Contents/Resources/Cookbook"
cp -R Cookbook/recipes "$APP/Contents/Resources/Cookbook/"
cp Cookbook/pins.json "$APP/Contents/Resources/Cookbook/"

LOCALES=$(for d in Sources/FoodTruckKit/Resources/*.lproj; do
  printf '<string>%s</string>' "$(basename "$d" .lproj)"; done)

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>FoodTruck</string>
  <key>CFBundleIdentifier</key><string>co.stuffbucket.foodtruck</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>FoodTruck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${NUMERIC}</string>
  <key>CFBundleVersion</key><string>${NUMERIC}</string>
  <!-- Declared explicitly: Bundle.main's localizations gate resolution for
       every other bundle in the process, so omitting this makes -AppleLanguages
       silently ignored. -->
  <key>CFBundleLocalizations</key><array>${LOCALES}</array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"
test -x "$APP/Contents/MacOS/FoodTruck"
echo "Built $APP ($NUMERIC)"
